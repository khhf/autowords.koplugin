--[[--
Offline unit tests for AutoWords.

Runs under any plain Lua interpreter (lupa's Lua, Lua 5.1..5.5) with KOReader
modules replaced by stubs, so the counting, the delay computation and the
scheduling logic can be checked without a device.

Usage:  python tests/run_tests.py      (from the repository root)
]]

package.path = "./?.lua;" .. package.path

-- ---------------------------------------------------------------------------
-- KOReader stubs
-- ---------------------------------------------------------------------------

local function return_first(a) return a end

package.preload["gettext"] = function()
    return function(s) return s end
end

package.preload["logger"] = function()
    return { dbg = function() end, warn = function() end, err = function() end }
end

package.preload["ffi/util"] = function()
    return {
        template = function(str, ...)
            local args = { ... }
            return (str:gsub("%%(%d)", function(i)
                return tostring(args[tonumber(i)])
            end))
        end,
    }
end

package.preload["pluginshare"] = function() return {} end

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_BLACK = 0 }
end

package.preload["ui/geometry"] = function()
    return {
        new = function(_, o)
            o = o or {}
            return o
        end,
    }
end

package.preload["ui/font"] = function()
    return { getFace = function() return { face = "stub" } end }
end

package.preload["ui/widget/textwidget"] = function()
    return {
        new = function(_, o)
            o = o or {}
            return {
                text = o.text,
                getSize = function() return { w = 8, h = 10 } end,
                paintTo = function() end,
                free = function() end,
            }
        end,
    }
end

local WidgetContainer = {}
WidgetContainer.__index = WidgetContainer
function WidgetContainer:extend(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end
package.preload["ui/widget/container/widgetcontainer"] = function()
    return WidgetContainer
end

package.preload["dispatcher"] = function()
    return { registerAction = function() end, _actions = {} }
end

package.preload["ui/event"] = function()
    return {
        new = function(_, name, ...)
            return { name = name, args = { ... } }
        end,
    }
end

local shown_widgets = {}
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, o) o = o or {}; o._kind = "InfoMessage"; return o end }
end
package.preload["ui/widget/spinwidget"] = function()
    return { new = function(_, o) o = o or {}; o._kind = "SpinWidget"; return o end }
end
package.preload["ui/widget/buttondialog"] = function()
    return {
        new = function(_, o)
            o = o or {}
            o._kind = "ButtonDialog"
            o.setTitle = function() end
            o.reinit = function() end
            return o
        end,
    }
end

local scheduled = {}   -- list of {delay=..., fn=...}
local unscheduled = 0
local ticks = {}       -- pending nextTick callbacks
local top_widget = { name = "ReaderUI" }
local input_hooks = {} -- widgets registered on UIManager.event_hook
local dirty_calls = {} -- UIManager:setDirty() calls
local broadcast_events = {} -- UIManager:broadcastEvent() calls

package.preload["ui/uimanager"] = function()
    return {
        event_hook = {
            registerWidget = function(_, name, widget)
                table.insert(input_hooks, { name = name, widget = widget })
            end,
        },
        scheduleIn = function(_, delay, fn)
            table.insert(scheduled, { delay = delay, fn = fn })
        end,
        unschedule = function(_, fn)
            unscheduled = unscheduled + 1
            for i = #scheduled, 1, -1 do
                if scheduled[i].fn == fn then table.remove(scheduled, i) end
            end
        end,
        nextTick = function(_, fn)
            table.insert(ticks, fn)
        end,
        show = function(_, w) table.insert(shown_widgets, w) end,
        close = function() end,
        setDirty = function(_, widget, refresh_type, region)
            table.insert(dirty_calls, { widget = widget, refresh_type = refresh_type, region = region })
        end,
        broadcastEvent = function(_, event)
            table.insert(broadcast_events, event)
        end,
        getTopmostVisibleWidget = function() return top_widget end,
        getElapsedTimeSinceBoot = function() return 0 end,
    }
end

local PAGE_TEXT = "你好世界这是一页中文文本"
local doc_has_pages = false
local current_page = 1
local touch_device = true
package.preload["device"] = function()
    return {
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            scaleBySize = function(_, v) return v end,
        },
        isTouchDevice = function() return touch_device end,
    }
end

-- fake global settings store
local store = {}
G_reader_settings = {
    readSetting = function(_, key, default)
        local v = store[key]
        if v == nil then return default end
        return v
    end,
    saveSetting = function(_, key, value) store[key] = value end,
    isTrue = function(_, key) return store[key] == true end,
    nilOrTrue = function(_, key) return store[key] == nil or store[key] == true end,
    makeTrue = function(_, key) store[key] = true end,
    makeFalse = function(_, key) store[key] = false end,
}

-- ---------------------------------------------------------------------------
-- test helpers
-- ---------------------------------------------------------------------------

local failures, checks = 0, 0
local function check(name, got, want)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL  %-52s got=%s want=%s", name, tostring(got), tostring(want)))
    else
        print(string.format("ok    %-52s %s", name, tostring(got)))
    end
end

local function check_true(name, got)
    check(name, got and true or false, true)
end

-- ---------------------------------------------------------------------------
-- 1. counting module
-- ---------------------------------------------------------------------------

local Count = require("autowords_count")

check("chars: chinese only", Count.count("你好世界", "chars"), 4)
check("chars: ascii sentence", Count.count("hello world", "chars"), 10)
check("chars: spaces are not counted", Count.count("a b\tc\nd", "chars"), 4)
check("chars: fullwidth space skipped", Count.count("你好\227\128\128世界", "chars"), 4)
check("chars: nbsp skipped", Count.count("a\194\160b", "chars"), 2)
check("chars: mixed cjk+latin", Count.count("中文abc", "chars"), 5)
check("chars: empty string", Count.count("", "chars"), 0)
check("chars: nil input", Count.count(nil, "chars"), 0)
check("chars: punctuation counts", Count.count("你好，世界。", "chars"), 6)
check("words: ascii", Count.count("hello world foo", "words"), 3)
check("words: punctuation splits", Count.count("hello, world!", "words"), 2)
check("words: cjk one per char", Count.count("你好世界", "words"), 4)
check("words: cjk + latin run", Count.count("中文abc def中文", "words"), 4 + 2)
check("words: numbers are words", Count.count("page 42 done", "words"), 3)
check("words: accented latin not split", Count.count("café crème", "words"), 2)
check("words: default mode is chars", Count.count("hello world"), 10)

-- ---------------------------------------------------------------------------
-- 1b. localization module
-- ---------------------------------------------------------------------------

do
    store["language"] = "zh_CN"
    package.loaded["autowords_i18n"] = nil
    local _zh = require("autowords_i18n")
    check("zh: menu string", _zh("Reading speed"), "阅读速度")
    check("zh: placeholders survive", _zh("This page holds %1 %2.\nHow many seconds do you need to read it?"),
        "本页共 %1 %2。\n你读完这一页需要多少秒？")
    check("zh: unknown msgid falls back", _zh("Not translated at all"), "Not translated at all")

    store["language"] = "en_US"
    package.loaded["autowords_i18n"] = nil
    local _en = require("autowords_i18n")
    check("en: english is kept", _en("Reading speed"), "Reading speed")
end

-- ---------------------------------------------------------------------------
-- 2. plugin logic
-- ---------------------------------------------------------------------------

local AutoWords = dofile("main.lua")

local function new_instance(overrides)
    local inst = setmetatable({}, { __index = AutoWords })
    inst.ui = {
        document = {
            is_open = true,
            info = { has_pages = doc_has_pages },
            getTextFromPositions = function(_, p0, p1, no_sel)
                check("measure: top-left coordinate", p0.x, 0)
                check("measure: bottom-right width", p1.x, 600)
                check("measure: no selection drawn", no_sel, true)
                return { text = PAGE_TEXT }
            end,
            getCurrentPage = function() return current_page end,
        },
        view = { state = { page = current_page, pos = 0 } },
        rolling = { current_page = current_page },
        events = {},
        handleEvent = function(self, ev) table.insert(self.events, ev) end,
    }
    inst.speed = 300
    inst.count_mode = "chars"
    inst.min_delay = 2
    inst.max_delay = 0
    inst.distance = 1
    inst.enabled = true
    inst.scheduled = false
    inst.self_turning = false
    inst.no_move_count = 0
    inst.retry_delay = 2
    inst.task = function() end
    for k, v in pairs(overrides or {}) do inst[k] = v end
    return inst
end

do
    local inst = new_instance()
    check("supported document", inst:isSupportedDocument(), true)
    check("page count (chars)", inst:measurePage(), 12)
    check("delay for 600 chars @300/min", inst:delayForCount(600), 120)
    check("delay for 0 -> min_delay", inst:delayForCount(0), 2)
    check("delay for nil -> min_delay", inst:delayForCount(nil), 2)
    check("delay below min is clamped", inst:delayForCount(1), 2)
    check("delay with max_delay", new_instance({ max_delay = 10 }):delayForCount(600), 10)
    check("delay with speed 120 -> 10s for 20 chars", new_instance({ speed = 120 }):delayForCount(20), 10)
end

do
    -- words mode
    local inst = new_instance({ count_mode = "words" })
    check("page count (words, cjk)", inst:measurePage(), 12)
    check("unit name words", inst:unitName(), "words")
end

do
    -- unsupported (fixed layout) document
    doc_has_pages = true
    local inst = new_instance()
    inst.ui.paging = {}
    check("pdf is refused", inst:isSupportedDocument(), false)
    check("measure returns nil when unsupported", inst:measurePage(), nil)
    inst.enabled = true
    inst:setEnabled(true)
    check("enable on pdf turns itself off", inst.enabled, false)
    doc_has_pages = false
end

do
    -- image-only page (empty text)
    local inst = new_instance()
    inst.ui.document.getTextFromPositions = function() return { text = "" } end
    check("empty text counts as 0", inst:measurePage(), 0)
    inst.ui.document.getTextFromPositions = function() return nil end
    check("nil result counts as 0", inst:measurePage(), 0)
    inst.ui.document.getTextFromPositions = function() error("crengine exploded") end
    local n, status = inst:measurePage()
    check("pcall protects against engine errors", n, nil)
    check("pcall status is error", status, "error")
end

do
    -- scheduling
    scheduled = {}
    local inst = new_instance()
    inst:scheduleForCurrentPage()
    check("one turn scheduled", #scheduled, 1)
    check("delay equals 12 chars @300/min", scheduled[1].delay, 12 * 60 / 300)
    check("scheduled flag set", inst.scheduled, true)

    -- a second call must not stack timers
    inst:scheduleForCurrentPage()
    check("only one timer pending", #scheduled, 1)
    check("unschedule was called", unscheduled > 0, true)
end

do
    -- tick(): turns the page, then reschedules for the new page
    scheduled = {}
    ticks = {}
    current_page = 5
    local inst = new_instance()
    inst.ui.view.state.page = 5
    inst.task = function() end
    inst:tick()
    check("GotoViewRel event emitted", inst.ui.events[1] and inst.ui.events[1].name, "GotoViewRel")
    check("GotoViewRel distance", inst.ui.events[1].args[1], 1)
    check("nextTick used for measuring", #ticks, 1)
    check("nothing scheduled before nextTick runs", #scheduled, 0)

    current_page = 6
    inst.ui.view.state.page = 6
    ticks[1]()
    check("next turn scheduled after page change", #scheduled, 1)
end

do
    -- tick() at the end of the document stops and disables
    scheduled = {}
    ticks = {}
    shown_widgets = {}
    current_page = 99
    local inst = new_instance()
    inst.ui.view.state.page = 99
    inst:tick()
    current_page = 99        -- page did not move
    inst.ui.view.state.page = 99
    ticks[1]()
    check("first failed move stays active", inst.enabled, true)
    check("a confirmation retry is scheduled", #scheduled, 1)
    check("retry uses retry_delay", scheduled[1].delay, 2)

    scheduled = {}
    ticks = {}
    inst:tick()
    ticks[1]()
    check("second failed move disables", inst.enabled, false)
    check("no turn scheduled at the end", #scheduled, 0)
    check("the reader is told why", #shown_widgets > 0, true)
end

do
    -- EndOfBook event (sent by crengine when a forward move changes nothing)
    scheduled = {}
    shown_widgets = {}
    current_page = 12
    local inst = new_instance()
    inst:scheduleForCurrentPage()
    check("handler does not swallow the event", inst:onEndOfBook(), false)
    check("end of book disables", inst.enabled, false)
    check("timer cleared at end of book", #scheduled, 0)
    check("nothing happens when already stopped", inst:onEndOfBook(), false)
end

do
    -- tick() while a dialog is on top: no page turn, retry later
    scheduled = {}
    ticks = {}
    top_widget = { name = "ButtonDialog" }
    local inst = new_instance()
    inst:tick()
    check("no page turn behind a dialog", #inst.ui.events, 0)
    check("retry scheduled", #scheduled, 1)
    check("retry delay", scheduled[1].delay, 2)
    top_widget = { name = "ReaderUI" }
end

do
    -- disabling stops the timer
    scheduled = {}
    local inst = new_instance()
    inst:scheduleForCurrentPage()
    check("timer pending before stop", #scheduled, 1)
    inst:setEnabled(false)
    check("timer cancelled on stop", #scheduled, 0)
    check("setting persisted as false", store["autowords_enabled"], false)
end

do
    -- enabling shows the calibration info
    scheduled = {}
    shown_widgets = {}
    current_page = 1
    local inst = new_instance()
    inst:setEnabled(true)
    check("setting persisted as true", store["autowords_enabled"], true)
    check("info message shown", #shown_widgets, 1)
    check_true("info mentions the page count", shown_widgets[1].text:find("12", 1, true) ~= nil)
end

do
    -- onInputEvent restarts the countdown with the same delay
    scheduled = {}
    local inst = new_instance()
    inst.restart_on_input = true
    inst.cur_delay = 42
    inst:onInputEvent()
    check("restart schedules with stored delay", scheduled[1].delay, 42)
    scheduled = {}
    inst.restart_on_input = false
    inst:onInputEvent()
    check("restart disabled -> nothing scheduled", #scheduled, 0)
end

-- ---------------------------------------------------------------------------
-- 3. UI smoke tests (menu entry + every dialog, including their callbacks)
-- ---------------------------------------------------------------------------

do
    shown_widgets = {}
    scheduled = {}
    local inst = new_instance({ enabled = false })

    local menu_items = {}
    inst:addToMainMenu(menu_items)
    check("menu item registered", type(menu_items.autowords), "table")
    check("menu text while stopped", menu_items.autowords.text_func(), "AutoWords")
    check("checked_func false while stopped", menu_items.autowords.checked_func(), false)

    inst.enabled = true
    check_true("menu text while running shows the speed",
        menu_items.autowords.text_func():find("300", 1, true) ~= nil)
    check("checked_func reflects state", menu_items.autowords.checked_func(), true)
    inst.enabled = false

    inst:showSettingsDialog()
    check("settings dialog shown", #shown_widgets, 1)
    local dlg = shown_widgets[1]
    check("settings dialog kind", dlg._kind, "ButtonDialog")
    check("settings dialog rows", #dlg.buttons, 4)
    check_true("dialog title shows the page count",
        dlg.title:find("12", 1, true) ~= nil)

    -- Every settings button must be callable without blowing up.
    local fake_menu = { updates = 0 }
    function fake_menu:updateItems() self.updates = self.updates + 1 end
    menu_items.autowords.callback(fake_menu)
    check("menu callback remembers the menu", inst._menu, fake_menu)
    check_true("menu callback opens the dialog", #shown_widgets > 1)

    for _, row in ipairs(dlg.buttons) do
        for _, btn in ipairs(row) do
            if btn.callback then btn.callback() end
        end
    end
    check_true("settings buttons opened further dialogs", #shown_widgets > 1)
    check_true("menu got refreshed after state changes", fake_menu.updates > 0)
end

do
    shown_widgets = {}
    local inst = new_instance()
    inst:showSpeedDialog()
    local spin = shown_widgets[1]
    check("speed dialog kind", spin._kind, "SpinWidget")
    check("speed dialog unit", spin.unit, "characters/min")
    spin.value = 480
    spin.callback(spin)
    check("speed saved", store["autowords_speed"], 480)
    check("speed applied", inst.speed, 480)
end

do
    shown_widgets = {}
    local inst = new_instance()
    inst:showCalibrateDialog()
    local cal = shown_widgets[1]
    check("calibrate dialog kind", cal._kind, "SpinWidget")
    check_true("calibrate mentions this page", cal.info_text:find("12", 1, true) ~= nil)
    cal.value = 60            -- 12 characters in 60 s  ->  12 units/min
    cal.callback(cal)
    check("calibration derives the speed", inst.speed, 12)
    check("calibration saved", store["autowords_speed"], 12)
end

do
    shown_widgets = {}
    local inst = new_instance()
    inst:showMoreDialog()
    local dlg = shown_widgets[1]
    check("more-settings dialog kind", dlg._kind, "ButtonDialog")
    for _, row in ipairs(dlg.buttons) do
        for _, btn in ipairs(row) do
            if btn.callback then btn.callback() end
        end
    end
    check_true("more-settings buttons are all callable", #shown_widgets > 1)
end

do
    shown_widgets = {}
    local inst = new_instance()
    inst:showMinDelayDialog()
    local w = shown_widgets[1]
    w.value = 5
    w.callback(w)
    check("min delay saved", store["autowords_min_delay"], 5)
    check("min delay applied", inst.min_delay, 5)

    shown_widgets = {}
    inst:showMaxDelayDialog()
    w = shown_widgets[1]
    w.value = 90
    w.callback(w)
    check("max delay saved", store["autowords_max_delay"], 90)
    check("max delay applied", inst.max_delay, 90)

    shown_widgets = {}
    inst:showDistanceDialog()
    w = shown_widgets[1]
    w.value = 0.5
    w.callback(w)
    check("distance saved", store["autowords_distance"], 0.5)
    check("distance applied", inst.distance, 0.5)
end

do
    -- unsupported document must not crash the dialogs either
    doc_has_pages = true
    shown_widgets = {}
    local inst = new_instance()
    inst.ui.paging = {}
    inst:showSettingsDialog()
    check("unsupported: dialog still built", #shown_widgets, 1)
    check_true("unsupported: title explains the limitation",
        shown_widgets[1].title:find("not supported", 1, true) ~= nil)
    inst:showCalibrateDialog()
    doc_has_pages = false
end

-- ---------------------------------------------------------------------------
-- 4. status bar icon
-- ---------------------------------------------------------------------------

do
    -- registering the icon with the bottom status bar
    local added, removed = 0, 0
    local footer = {
        height = 40,
        mode = 3,
        getHeight = function(self) return self.height end,
        addAdditionalFooterContent = function(self, func)
            added = added + 1
            self._content = func
            self.mode = 1 -- what updateFooterTextGenerator() does to footer.mode
        end,
        removeAdditionalFooterContent = function()
            removed = removed + 1
        end,
        applyFooterMode = function(self, mode)
            self.mode = mode
            self.reapplied = (self.reapplied or 0) + 1
        end,
        footer_text = { text = "12/240 · 5% · Ⓐ", dimen = { x = 100, y = 760, w = 200, h = 20 } },
        getTextWidth = function(self, text) return #text * 10 end,
    }
    local inst = new_instance()
    inst.icon_position = "bottom"
    inst.ui.view = { footer_visible = true, footer = footer }

    inst:setupFooterIcon()
    check("content registered with the bottom bar", added, 1)
    check("footer remembered", inst.footer, footer)
    check("registered generator returns the icon", footer._content(), "Ⓐ")
    check("content text while running", inst:footerContentText(), "Ⓐ")
    check("the footer mode is restored after registering", footer.mode, 3)
    check("the footer mode was re-applied", footer.reapplied, 1)

    inst.enabled = false
    check("content text while stopped is empty", inst:footerContentText(), "")
    inst.enabled = true
    inst.icon_position = "none"
    check("content text with the icon switched off", inst:footerContentText(), "")
    inst.icon_position = "top"
    check("bottom bar content empty when only the top bar is wanted",
        inst:footerContentText(), "")
    check("top bar content set when only the top bar is wanted",
        inst:headerContentText(), "Ⓐ")
    inst.icon_position = "bottom"

    inst:setupFooterIcon()
    check("registration is idempotent", added, 1)

    -- repainting touches only the bar the icon lives in
    inst.ui.events = {}
    broadcast_events = {}
    inst:refreshStatusBars()
    check("bottom bar repaint requested", inst.ui.events[1] and inst.ui.events[1].name, "UpdateFooter")
    check("no top bar refresh when the icon is not there", #broadcast_events, 0)

    -- teardown
    inst:teardownFooterIcon()
    check("content removed from the bottom bar", removed, 1)
    check("footer reference dropped", inst.footer, nil)
end

do
    -- the top status bar (alt status bar) is fed through ReaderCoptListener
    local header_added, header_removed = 0, 0
    local listener = {
        addAdditionalHeaderContent = function(self, func)
            header_added = header_added + 1
            self._content = func
        end,
        removeAdditionalHeaderContent = function()
            header_removed = header_removed + 1
        end,
    }
    local inst = new_instance() -- default position is the top bar
    inst.ui.crelistener = listener
    inst.ui.view = { footer_visible = true, footer = nil }

    check("default icon position is the top bar", inst:iconPosition(), "top")

    inst:setupHeaderIcon()
    check("content registered with the top bar", header_added, 1)
    check("top bar generator returns the icon", listener._content(), "Ⓐ")
    inst:setupHeaderIcon()
    check("top bar registration is idempotent", header_added, 1)

    inst.enabled = false
    check("top bar content empty while stopped", listener._content(), "")
    inst.enabled = true
    inst.icon_position = "bottom"
    check("top bar content empty when only the bottom bar is wanted", listener._content(), "")
    inst.icon_position = "top"

    broadcast_events = {}
    inst.ui.events = {}
    inst:refreshStatusBars()
    check("top bar refresh broadcast", broadcast_events[1] and broadcast_events[1].name, "UpdateHeader")
    check("no bottom bar refresh when the icon is not there", #inst.ui.events, 0)

    inst:teardownHeaderIcon()
    check("top bar content removed", header_removed, 1)
    check("top bar listener dropped", inst.header_listener, nil)
end

do
    -- applyIconPosition() registers with exactly the wanted bar, nowhere else
    local footer_added, header_added = 0, 0
    local footer = {
        height = 40,
        mode = 3,
        getHeight = function(self) return self.height end,
        addAdditionalFooterContent = function() footer_added = footer_added + 1 end,
        removeAdditionalFooterContent = function() end,
        applyFooterMode = function() end,
    }
    local listener = {
        addAdditionalHeaderContent = function() header_added = header_added + 1 end,
        removeAdditionalHeaderContent = function() end,
    }
    local inst = new_instance()
    inst.ui.view = { footer_visible = true, footer = footer }
    inst.ui.crelistener = listener

    inst.icon_position = "top"
    inst:applyIconPosition()
    check("top only: header registered", header_added, 1)
    check("top only: bottom bar left alone", footer_added, 0)

    inst.icon_position = "both"
    inst:applyIconPosition()
    check("both: bottom bar registered now", footer_added, 1)

    inst.icon_position = "none"
    inst:applyIconPosition()
    check("none: bottom bar not registered again", footer_added, 1)
    check("none: header not registered again", header_added, 1)
end

do
    -- a missing footer / listener must not break anything
    local inst = new_instance()
    inst.ui.view = { footer_visible = true, footer = nil }
    inst:applyIconPosition()
    check("no status bar at all is handled", inst.footer, nil)

    -- plugin init must not touch the status bars at all
    local touched = false
    local footer = {
        height = 40,
        getHeight = function() return 40 end,
        addAdditionalFooterContent = function() touched = true end,
        removeAdditionalFooterContent = function() touched = true end,
    }
    local inst2 = setmetatable({}, { __index = AutoWords })
    inst2.ui = {
        menu = { registerToMainMenu = function() end },
        view = { footer_visible = true, footer = footer },
    }
    inst2.onDispatcherRegisterActions = function() end
    inst2:init()
    check("init() does not register with the status bars", touched, false)
end

do
    -- icon picker, icon position picker and diagnostics dialogs
    shown_widgets = {}
    local inst = new_instance()
    inst.ui.view = { footer_visible = true, footer = nil }
    inst:showIconDialog()
    check("icon picker shown", #shown_widgets, 1)
    check_true("icon picker offers several choices", #shown_widgets[1].buttons >= 2)
    for _, row in ipairs(shown_widgets[1].buttons) do
        for _, btn in ipairs(row) do
            if btn.callback then btn.callback() end
        end
    end
    check_true("picking an icon stores it", store["autowords_icon_text"] ~= nil)
    check("picked icon is used", inst:iconText(), store["autowords_icon_text"])

    shown_widgets = {}
    inst:showIconPositionDialog()
    check("icon position picker shown", #shown_widgets, 1)
    check("icon position picker offers every position", #shown_widgets[1].buttons, 5)
    shown_widgets[1].buttons[1][1].callback() -- pick "top"
    check("picked position stored", store["autowords_icon_position"], "top")
    check("picked position applied", inst.icon_position, "top")

    shown_widgets = {}
    inst:showDiagnosticDialog()
    check("diagnostics shown", #shown_widgets, 1)
    check_true("diagnostics report the plugin state",
        shown_widgets[1].title:find("Plugin loaded", 1, true) ~= nil)
    for _, row in ipairs(shown_widgets[1].buttons) do
        for _, btn in ipairs(row) do
            if btn.callback then btn.callback() end
        end
    end
end

do
    -- init() smoke test: settings are read, menu and input hook registered
    store["autowords_speed"] = nil
    store["autowords_enabled"] = nil
    store["autowords_count_mode"] = nil
    store["autowords_min_delay"] = nil
    store["autowords_max_delay"] = nil
    store["autowords_distance"] = nil
    store["autowords_restart_on_input"] = nil
    store["autowords_footer_icon"] = nil
    store["autowords_icon_text"] = nil
    store["autowords_icon_position"] = nil
    input_hooks = {}

    local inst = setmetatable({}, { __index = AutoWords })
    local menu_registered
    local dispatcher_registered = 0
    inst.ui = {
        menu = {
            registerToMainMenu = function(_, widget) menu_registered = widget end,
        },
    }
    inst.onDispatcherRegisterActions = function() dispatcher_registered = dispatcher_registered + 1 end
    inst:init()

    check("init registers the menu", menu_registered, inst)
    check("init registers dispatcher actions", dispatcher_registered, 1)
    check("init registers the InputEvent hook", #input_hooks, 1)
    check("input hook name", input_hooks[1].name, "InputEvent")
    check("input hook widget", input_hooks[1].widget, inst)
    check("init creates the timer task", type(inst.task), "function")
    check("init default speed", inst.speed, 300)
    check("init default count mode", inst.count_mode, "chars")
    check("init default min delay", inst.min_delay, 2)
    check("init default max delay", inst.max_delay, 0)
    check("init default distance", inst.distance, 1)
    check("init default restart on input", inst.restart_on_input, true)
    check("init default icon position", inst.icon_position, "top")
    check("init default icon character", inst:iconText(), "Ⓐ")
    check("init default disabled", inst.enabled, false)
end

do
    -- lifecycle hooks must not blow up, and must manage the timer
    scheduled = {}
    local inst = new_instance()
    inst:onReaderReady()
    check("reader ready schedules a turn", #scheduled, 1)

    inst:onSuspend()
    check("suspend cancels the timer", #scheduled, 0)

    inst:onResume()
    check("resume schedules again", #scheduled, 1)

    inst:onCloseDocument()
    check("closing the document cancels the timer", #scheduled, 0)

    inst:onCloseWidget()
    check("closing the widget drops the task ref", inst.task, nil)
end

-- ---------------------------------------------------------------------------
-- The screen boxes the guide asked the view to draw.
local function view_boxes(plugin)
    local temp = plugin.ui.view.highlight.temp
    return temp[1] or temp[next(temp)] or {}
end

-- 5. sentence guide
-- ---------------------------------------------------------------------------

local Guide = require("autowords_guide")

-- A page of text as KOReader reports it: two screen lines, three sentences.
--   行 1: "你好。世界！"
--   行 2: "第三句。"
--
-- Note that the guide reads this page with TWO kinds of call: one for the whole
-- screen (which yields the line boxes) and then one per line (because the page
-- text KOReader returns breaks at paragraphs, not at screen lines).  This stub
-- answers both, exactly like the real document does.
local PAGE_LINES = { "你好。世界！", "第三句。" }
local PAGE_BOXES = {
    { x = 0, y = 20, w = 200, h = 16 },
    { x = 0, y = 40, w = 200, h = 16 },
}
local PAGE_TEXT = table.concat(PAGE_LINES, "\n")

-- the vertical region each box answers to, using the same half-way boundaries
-- the guide uses so that no two regions overlap
local function box_region(i)
    local box = PAGE_BOXES[i]
    local top = box.y
    local bottom = box.y + box.h
    if i > 1 then
        local prev = PAGE_BOXES[i - 1]
        top = (prev.y + prev.h + box.y) / 2
    end
    if i < #PAGE_BOXES then
        local nxt = PAGE_BOXES[i + 1]
        bottom = (box.y + box.h + nxt.y) / 2
    end
    return math.floor(top), math.ceil(bottom)
end

local function guide_doc(overrides)
    local doc = {
        is_open = true,
        getCurrentPage = function() return 5 end,
        getTextFromPositions = function(_, p0, p1)
            -- a whole-screen call: text plus every line box
            if p1.y - p0.y > 100 then
                return {
                    text = PAGE_TEXT,
                    pos0 = "c0",
                    pos1 = "c1",
                    sboxes = PAGE_BOXES,
                }
            end
            -- a per-line call: the text of the line covering that region
            for i = 1, #PAGE_BOXES do
                local top, bottom = box_region(i)
                if p0.y >= top and (p0.y < bottom or i == #PAGE_BOXES) then
                    return { text = PAGE_LINES[i], pos0 = "L" .. i, pos1 = "L" .. i .. "e" }
                end
            end
            return { text = "", pos0 = "", pos1 = "" }
        end,
    }
    for k, v in pairs(overrides or {}) do doc[k] = v end
    return doc
end

local function guide_instance(overrides)
    local plugin = new_instance()
    plugin.ui.document = guide_doc(overrides and overrides.doc)
    plugin.ui.view = {
        highlight = { temp = {}, temp_drawer = "lighten" },
        dialog = {},
        footer_visible = false,
        view_mode = "page",
    }
    plugin.reading_mode = "sentence"
    plugin.enabled = true
    plugin.speed = 300
    plugin.count_mode = "chars"
    plugin.guide_task = function() end
    local guide = Guide:new(plugin)
    for k, v in pairs(overrides or {}) do
        if k ~= "doc" then guide[k] = v end
    end
    return guide, plugin
end

--- The boxes the guide asked the view to draw.
local function view_boxes(plugin)
    local temp = plugin.ui.view.highlight.temp
    return temp[next(temp)] or {}
end

do
    -- splitting the page text into lines
    local lines = Guide.splitLines("ab\ncd\n")
    check("three lines, the last one empty", #lines, 3)
    check("first line range", lines[1].from .. "-" .. lines[1].to, "1-2")
    check("second line range", lines[2].from .. "-" .. lines[2].to, "4-5")
    check("trailing empty line", lines[3].from .. "-" .. lines[3].to, "7-6")

    check("a single line has no separator", #Guide.splitLines("abc"), 1)
end

do
    -- splitting into sentences
    local sentences = Guide.splitSentences("你好。世界！")
    check("two sentences", #sentences, 2)
    check("first sentence text", sentences[1].text, "你好。")
    check("second sentence text", sentences[2].text, "世界！")
    check("byte ranges are consecutive", sentences[1].to, sentences[2].from)

    -- a full stop inside quotes belongs to the closing quote
    sentences = Guide.splitSentences('他说“好。”然后走了。')
    check("quoted full stop does not split", #sentences, 2)
    check("the quote is taken along", sentences[1].text, '他说“好。”')

    -- ascii punctuation
    sentences = Guide.splitSentences("One. Two! Three?")
    check("ascii sentence ends", #sentences, 3)
    check("trailing text", sentences[3].text, "Three?")

    -- text without any sentence end is one piece
    sentences = Guide.splitSentences("没有标点的一段话")
    check("no punctuation means one piece", #sentences, 1)

    -- whitespace only produces nothing
    check("blank text has no sentences", #Guide.splitSentences("   \n  "), 0)
end

do
    -- mapping sentences onto the line boxes
    local text = PAGE_TEXT
    local lines = Guide.splitLines(text)
    local sentences = Guide.attachBoxes(Guide.splitSentences(text), lines,
        PAGE_BOXES, text)

    check("three sentences mapped", #sentences, 3)
    check("the first sentence is on line 1", sentences[1].lines[1], 1)
    check("and it gets one box", #sentences[1].boxes, 1)
    check("the last sentence is on line 2", sentences[3].lines[1], 2)
    check("with that line's box",
        sentences[3].boxes[1] and sentences[3].boxes[1].y, 40)

    -- line 1 holds two sentences, so each box covers only part of the line
    check_true("a sentence ending mid-line gets a trimmed box",
        sentences[1].boxes[1].w < PAGE_BOXES[1].w)
    check("the first sentence starts at the left edge", sentences[1].boxes[1].x, 0)
    check_true("and the second one starts to its right",
        sentences[2].boxes[1].x > sentences[1].boxes[1].x)
    check_true("the two boxes do not overlap",
        sentences[1].boxes[1].x + sentences[1].boxes[1].w
            <= sentences[2].boxes[1].x + 0.001)

    -- a sentence that fills its whole line keeps the untouched box
    check("a sentence filling the line is not trimmed",
        sentences[3].boxes[1].w, PAGE_BOXES[2].w)
    check("and it keeps the full line height",
        sentences[3].boxes[1].h, PAGE_BOXES[2].h)

    -- a sentence covering two lines gets both boxes
    local two_line = "一二三四五六七八九十。\n下一句。"
    local boxes = {
        { x = 0, y = 10, w = 100, h = 16 },
        { x = 0, y = 30, w = 100, h = 16 },
    }
    local mapped = Guide.attachBoxes(Guide.splitSentences(two_line),
        Guide.splitLines(two_line), boxes, two_line)
    check_true("a sentence can cover more than one line", mapped[1].lines[2] ~= nil)

    -- characters are counted per code point, not per byte
    check("countChars: three hanzi", Guide.countChars("你好。", 1, 9), 3)
    check("countChars: empty range", Guide.countChars("你好。", 2, 1), 0)

    -- without the text to measure, the full line is kept (the old behaviour)
    check("no trimming without the text",
        Guide.trimBox(PAGE_BOXES[1], lines[1], { from = 1, to = 10 }), nil)
end

do
    do
    -- a blank line between paragraphs has no box of its own, so it must not
    -- take part in the mapping -- otherwise every later line is shifted by one
    -- and the underline lands on the wrong line
    local text = "第一句。\n\n第二句。"
    local lines = Guide.splitLines(text)
    check("the blank line is still a line", #lines, 3)
    local visual = Guide.visualLines(text, lines)
    check("but it is dropped for the mapping", #visual, 2)
    check("the lines that remain keep their order",
        text:sub(visual[2].from, visual[2].to), "第二句。")
end
-- the fallback when lines and boxes do not line up: one step per line
    local steps = Guide.sentencesPerLine(PAGE_TEXT, Guide.splitLines(PAGE_TEXT), PAGE_BOXES)
    check("one step per text line", #steps, 2)
    check("the first step is line one", steps[1].boxes[1].y, 20)
end

do
    -- pacing, unchanged by the rewrite
    local plugin = new_instance()
    plugin.speed = 300
    plugin.count_mode = "chars"
    local guide = Guide:new(plugin)

    local plain = string.rep("一二三四五六七八九十", 3) -- 30 characters
    check("plain sentence delay", guide:delayForSentence(plain), 6)

    check("sentence end pause added",
        guide:delayForSentence(plain .. "。"), 31 * 60 / 300 + Guide.defaults.end_pause)

    local commas = string.rep("好，", 4) -- 8 chars, 4 commas
    local expected = 8 * 60 / 300 + 4 * Guide.defaults.comma_pause
    check_true("comma pauses added",
        math.abs(guide:delayForSentence(commas) - expected) < 0.001)

    check("very short sentence falls back to the minimum",
        guide:delayForSentence("嗯。"), Guide.defaults.min_sentence_delay)

    plugin.guide_punct_scale = 0
    check("punct scale 0 removes punctuation pauses",
        guide:delayForSentence(plain .. "。"), 31 * 60 / 300)
end

do
    -- reading a page: one sentence at a time, then the page is turned
    local guide, plugin = guide_instance()
    scheduled = {}
    ticks = {}
    guide:step()

    check("first sentence shown", guide.segment.text, "你好。")
    check("the underline uses that sentence's boxes", guide.last_boxes, 1)
    check("the underline was handed to the view", #view_boxes(plugin), 1)
    check("temporary highlight switched to underline",
        plugin.ui.view.highlight.temp_drawer, "underscore")
    check("the sentence has its own countdown", #scheduled, 1)
    check("the page was read once", guide.page, 5)
    check("and it knows how many steps it has", #guide.page_sentences, 3)

    -- the next two sentences follow
    guide:step()
    check("second sentence", guide.segment.text, "世界！")
    guide:step()
    check("third sentence", guide.segment.text, "第三句。")
    check("progress reached the end", guide.index, 4)

    -- nothing left on this page: turn it
    guide:step()
    check("a page turn is queued", #ticks, 1)
    check("and the page content is dropped until the turn happens",
        guide.page_sentences, nil)

    -- running the tick actually turns the page
    local fn = table.remove(ticks, 1)
    plugin.ui.handleEvent = function(_, ev)
        plugin.events = plugin.events or {}
        table.insert(plugin.events, ev.name)
    end
    plugin.ui.document = guide_doc({ getCurrentPage = function() return 6 end })
    scheduled = {}
    fn()
    check("the page was turned", #(plugin.events or {}), 1)
    check("with GotoViewRel", plugin.events[1], "GotoViewRel")
    -- The new page is read after a short delay on purpose: reading it back
    -- immediately can return the page that was just left, which made the guide
    -- turn page after page without ever showing a sentence.
    check("the new page is not read instantly", guide.page, 5)
    check("a delay was scheduled instead", #scheduled, 1)

    local pending = table.remove(scheduled, 1)
    pending.fn()
    check("and then the new page is read", guide.page, 6)
    ticks = {}
end

do
    -- a page change caused by the reader starts the guide over on that page
    local guide, plugin = guide_instance()
    scheduled = {}
    guide:step()
    check("reading page 5", guide.page, 5)

    plugin.ui.document = guide_doc({ getCurrentPage = function() return 9 end })
    guide:step()
    check("the guide followed the reader to page 9", guide.page, 9)
    check("and started from its first sentence", guide.segment.text, "你好。")
end

do
    -- pausing holds the sentence, resuming restarts its countdown
    local guide, plugin = guide_instance()
    scheduled = {}
    guide:step()
    local sentence_before = guide.segment.text

    check("pause toggles on", guide:togglePause(), true)
    check("a paused guide cancels its timer", #scheduled, 0)
    check("the underline stays while paused", #view_boxes(plugin), 1)

    guide:step()
    check("a paused guide does not advance", #scheduled, 0)
    check("still on the same sentence", guide.segment.text, sentence_before)

    check("pause toggles off", guide:togglePause(), false)
    check("resume restarts the countdown", #scheduled, 1)

    guide:pause()
    guide:stop()
    check("stop clears the paused flag", guide.paused, false)
    check("and the underline", #view_boxes(plugin), 0)
end

do
    -- refresh() must not repaint while the underline is still on screen: every
    -- repaint is a screen refresh, and several events fire per position change
    local guide, plugin = guide_instance()
    scheduled = {}
    guide:step()
    check_true("the underline is on screen", #view_boxes(plugin) > 0)

    dirty_calls = {}
    guide:refresh()
    check("no repaint while the underline is still there", #dirty_calls, 0)

    -- KOReader clears the highlight on a page/pos update: then it is redrawn
    plugin.ui.view.highlight.temp = {}
    guide:refresh()
    check("repainted once the view cleared it", #dirty_calls, 1)
end

do
    -- going back one sentence
    local guide, plugin = guide_instance()
    scheduled = {}
    guide:step()
    guide:step()
    check("on the second sentence", guide.segment.text, "世界！")
    guide:goBack()
    check("goBack returns to the first sentence", guide.segment.text, "你好。")
end

do
    -- a closed document must make the guide inert, and a scheduled task must
    -- still be cancellable even if the plugin dropped its own reference
    local guide, plugin = guide_instance({ doc = { is_open = false } })
    check("guide is inactive on a closed document", guide:isActive(), false)
    scheduled = {}
    guide:step()
    check("step does nothing on a closed document", #scheduled, 0)

    guide, plugin = guide_instance()
    scheduled = {}
    guide:step()
    check("guide scheduled its step", #scheduled, 1)
    plugin.guide_task = nil
    guide:unschedule()
    check("the scheduled step can still be cancelled", #scheduled, 0)
end

do
    -- the self-test file is written and flushed on every step
    local path = Guide.selftestPath()
    check("self-test path is set", type(path), "string")
    check_true("self-test lives in /tmp", path:find("^/tmp/") ~= nil)

    os.remove(path)
    local guide, plugin = guide_instance()
    scheduled = {}
    guide:step()
    local fh = io.open(path, "r")
    check_true("self-test file was created", fh ~= nil)
    local content = fh and fh:read("*a") or ""
    if fh then fh:close() end
    check_true("it announces each step", content:find(">>>", 1, true) ~= nil)
    check_true("it records reading the page",
        content:find("getTextFromPositions", 1, true) ~= nil)
    check_true("it records the underline", content:find("underline over", 1, true) ~= nil)
    os.remove(path)
end

-- ---------------------------------------------------------------------------

print(string.format("\n%d checks, %d failures", checks, failures))
if failures > 0 then
    error(string.format("%d test(s) failed", failures))
end
print("ALL TESTS PASSED")

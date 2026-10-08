--[[--
AutoWords: automatic page turning paced by how much text is on screen.

AutoTurn (the stock plugin) waits a fixed number of seconds before every page
turn.  AutoWords instead measures how much text is currently visible, and
waits

    visible_units / speed_units_per_minute * 60   seconds

before turning the page, so a dense page gets more time than a page holding a
single paragraph.  The speed can be calibrated on the very page the reader is
looking at, which is what makes the whole thing usable: the settings dialog
always shows the current page's text count together with the resulting delay.

Only reflowable documents (EPUB / FB2 / TXT / HTML ...) are supported: the text
count comes from crengine.  Fixed-layout documents (PDF / DJVU) are detected
and refused, as agreed.

Cost per page turn: one crengine getTextFromPositions() call over the visible
area plus one linear scan of the returned string.  Nothing runs on a fast
timer; each measurement happens once, when a page is scheduled.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local Count = require("autowords_count")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local PluginShare = require("pluginshare")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("autowords_i18n")
local T = require("ffi/util").template
local Screen = require("device").screen

local AutoWords = WidgetContainer:extend{
    name = "autowords",
    is_doc_only = true,

    -- user settings
    enabled = false,
    -- how many text units (chars or words, see count_mode) per minute
    speed = 300,
    count_mode = "chars", -- "chars" | "words"
    min_delay = 2,        -- never turn faster than this (seconds)
    max_delay = 0,        -- 0 = no upper limit (seconds)
    restart_on_input = true,
    distance = 1,         -- GotoViewRel distance (1 = one screen)

    -- runtime state
    retry_delay = 2,
    scheduled = false,
    self_turning = false,
    no_move_count = 0,
    task = nil,
    cur_delay = nil,
    cache_key = nil,
    cache_count = nil,
}

-- ---------------------------------------------------------------------------
-- Document capability & text measuring
-- ---------------------------------------------------------------------------

--- Whether the current document can be measured (reflowable text only).
-- @treturn boolean supported
function AutoWords:isSupportedDocument()
    local ui = self.ui
    if not ui or not ui.document or not ui.document.is_open then return false end
    if ui.paging or (ui.document.info and ui.document.info.has_pages) then
        -- fixed layout (PDF/DJVU/image): crengine text extraction is not available
        return false
    end
    return ui.document.getTextFromPositions ~= nil
end

--- Count the text units visible on screen right now.
-- @treturn number|nil count, @treturn string status
function AutoWords:measurePage()
    if not self:isSupportedDocument() then
        return nil, "unsupported"
    end
    local doc = self.ui.document
    -- NOTE: Document:getPageText() is NOT usable here: crengine documents have
    -- no openPage()/getPageText(), it is only meant for the MuPDF backend.
    -- The supported way to get text is getTextFromPositions() over the
    -- visible area (this is what ReaderView:getCurrentPageLineWordCounts does).
    local ok, res = pcall(doc.getTextFromPositions, doc,
        { x = 0, y = 0 },
        { x = Screen:getWidth(), y = Screen:getHeight() },
        true) -- do_not_draw_selection
    if not ok then
        logger.warn("AutoWords: getTextFromPositions failed:", res)
        return nil, "error"
    end
    local text = res and res.text
    if not text or text == "" then
        -- image-only page, or positions outside any text node
        return 0, "empty"
    end
    return Count.count(text, self.count_mode), "ok"
end

--- Cache key identifying the currently displayed text.
-- Both the page number and the scroll position matter: in scroll mode the
-- page number can stay the same while the reader moves.
function AutoWords:pageKey()
    local view = self.ui and self.ui.view
    if not view or not view.state then
        return "nokey"
    end
    return tostring(view.state.page or -1) .. ":" .. tostring(view.state.pos or -1)
end

--- Text count of the current view, using a one-entry cache.
-- @treturn number|nil count
function AutoWords:currentCount()
    local key = self:pageKey()
    if key and self.cache_key == key then
        return self.cache_count
    end
    local count = self:measurePage()
    if key then
        self.cache_key = key
        self.cache_count = count
    end
    return count
end

--- Delay to apply for a page holding `count` text units.
-- @treturn number seconds
function AutoWords:delayForCount(count)
    local speed = (tonumber(self.speed) or 0) > 0 and self.speed or 300
    local delay
    if not count or count <= 0 then
        delay = self.min_delay
    else
        delay = count * 60 / speed
    end
    if self.min_delay and self.min_delay > 0 and delay < self.min_delay then
        delay = self.min_delay
    end
    if self.max_delay and self.max_delay > 0 and delay > self.max_delay then
        delay = self.max_delay
    end
    return delay
end

function AutoWords:unitName()
    return self.count_mode == "words" and _("words") or _("characters")
end

-- ---------------------------------------------------------------------------
-- Scheduling
-- ---------------------------------------------------------------------------

function AutoWords:isActive()
    return self.enabled and self:isSupportedDocument()
end

--- Cancel any pending turn and let the device auto-suspend again.
function AutoWords:stopScheduling(message)
    if self.scheduled then
        UIManager:unschedule(self.task)
        self.scheduled = false
    end
    PluginShare.pause_auto_suspend = false
    if message then
        logger.dbg("AutoWords:", message)
    end
end

--- Schedule the next turn `delay` seconds from now.
function AutoWords:scheduleIn(delay)
    if delay < 0 then delay = 0 end
    PluginShare.pause_auto_suspend = true
    self.cur_delay = delay
    UIManager:scheduleIn(delay, self.task)
    self.scheduled = true
end

--- Measure the current page and schedule the next turn accordingly.
--- NOTE: this must not touch self.no_move_count, otherwise the
--- "we are stuck at the end of the document" detection can never fire.
function AutoWords:scheduleForCurrentPage()
    self:stopScheduling()
    if not self:isActive() then return end
    local count = self:currentCount()
    local delay = self:delayForCount(count)
    logger.dbg("AutoWords: page count", count, "-> next turn in", delay, "s")
    self:scheduleIn(delay)
end

--- Re-arm the timer with the delay already computed (used after user input).
function AutoWords:restartTimer()
    if not self:isActive() then return end
    self:stopScheduling()
    self:scheduleIn(self.cur_delay or self.min_delay)
end

--- Current page number, whatever the reading mode is.
function AutoWords:currentPage()
    local ui = self.ui
    if not ui then return nil end
    if ui.document and ui.document.getCurrentPage then
        local ok, page = pcall(ui.document.getCurrentPage, ui.document)
        if ok then return page end
    end
    if ui.rolling then return ui.rolling.current_page end
    if ui.paging then return ui.paging.current_page end
end

--- Timer callback: turn the page, then schedule the next turn.
function AutoWords:tick()
    self.scheduled = false
    if not self:isActive() then
        self:stopScheduling()
        return
    end

    -- Do not turn pages while a menu / dialog / dictionary popup is up.
    local top_widget = UIManager:getTopmostVisibleWidget() or {}
    if top_widget.name ~= "ReaderUI" then
        logger.dbg("AutoWords: reader not on top, retrying later")
        self:scheduleIn(self.retry_delay)
        return
    end

    local page_before = self:currentPage()
    self.self_turning = true
    self.ui:handleEvent(Event:new("GotoViewRel", self.distance))
    self.self_turning = false

    -- Measure the new page once the UI has settled, then continue.
    UIManager:nextTick(function()
        if not self:isActive() then return end
        local page_after = self:currentPage()
        if page_before and page_after and page_before == page_after then
            -- The view did not move: we are at the end of the document.
            -- Confirm once (the view may not have settled yet) before stopping.
            self.no_move_count = self.no_move_count + 1
            if self.no_move_count >= 2 then
                self.no_move_count = 0
                self:setEnabled(false)
                UIManager:show(InfoMessage:new{
                    text = _("AutoWords stopped: the end of the document has been reached."),
                    timeout = 3,
                })
                return
            end
            self:scheduleIn(self.retry_delay)
            return
        end
        self.no_move_count = 0
        self:scheduleForCurrentPage()
    end)
end

--- Enable/disable, persisting the setting.
function AutoWords:setEnabled(on)
    self.enabled = on and true or false
    if self.enabled then
        if not self:isSupportedDocument() then
            self.enabled = false
            G_reader_settings:makeFalse("autowords_enabled")
            UIManager:show(InfoMessage:new{
                text = _("AutoWords only works with reflowable documents (EPUB, FB2, TXT ...), not with PDF or DJVU."),
                timeout = 4,
            })
            return
        end
        G_reader_settings:makeTrue("autowords_enabled")
        self:scheduleForCurrentPage()
        local count = self:currentCount()
        local delay = self:delayForCount(count)
        UIManager:show(InfoMessage:new{
            text = T(_("AutoWords is on: %1 %2/min.\nThis page: %3 %2 → %4 s."),
                self.speed, self:unitName(), count or 0,
                string.format("%.1f", delay)),
            timeout = 4,
        })
    else
        G_reader_settings:makeFalse("autowords_enabled")
        self:stopScheduling()
    end
    self:refreshMenu()
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

function AutoWords:init()
    self.speed = tonumber(G_reader_settings:readSetting("autowords_speed")) or 300
    self.count_mode = G_reader_settings:readSetting("autowords_count_mode", "chars")
    self.min_delay = tonumber(G_reader_settings:readSetting("autowords_min_delay")) or 2
    self.max_delay = tonumber(G_reader_settings:readSetting("autowords_max_delay")) or 0
    self.restart_on_input = G_reader_settings:nilOrTrue("autowords_restart_on_input")
    self.distance = tonumber(G_reader_settings:readSetting("autowords_distance")) or 1
    self.enabled = G_reader_settings:isTrue("autowords_enabled")

    self.task = function() self:tick() end

    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    -- Only used to notice that the reader touched the screen.
    UIManager.event_hook:registerWidget("InputEvent", self)
end

function AutoWords:onDispatcherRegisterActions()
    Dispatcher:registerAction("autowords_toggle", {
        category = "none",
        event = "AutoWordsToggle",
        title = _("AutoWords: start/stop"),
        reader = true,
    })
    Dispatcher:registerAction("autowords_settings", {
        category = "none",
        event = "AutoWordsSettings",
        title = _("AutoWords: settings"),
        reader = true,
        separator = true,
    })
end

function AutoWords:onAutoWordsToggle()
    self:setEnabled(not self.enabled)
    return true
end

function AutoWords:onAutoWordsSettings()
    self:showSettingsDialog()
    return true
end

function AutoWords:onReaderReady()
    if self:isActive() then
        self:scheduleForCurrentPage()
    end
end

--- The user turned a page by hand (or the view moved): restart the timer so
--- the delay matches the page now on screen.
function AutoWords:onPageUpdate()
    if self.self_turning then return end
    if not self:isActive() then return end
    self.no_move_count = 0
    self:scheduleForCurrentPage()
end

function AutoWords:onPosUpdate()
    if self.self_turning then return end
    if not self:isActive() then return end
    self.no_move_count = 0
    self:scheduleForCurrentPage()
end

--- crengine tells us when a forward move did not change anything.
--- ReaderStatus already pops its "end of book" dialog on this event, so we
--- only stop ourselves here instead of adding a second message.
--- Do not swallow the event: other modules may want it too.
function AutoWords:onEndOfBook()
    if not self:isActive() then return false end
    self:setEnabled(false)
    self:refreshMenu()
    return false
end

--- Touching the screen restarts the countdown for the current page.
function AutoWords:onInputEvent()
    if self.self_turning then return end
    if not self.restart_on_input or not self:isActive() then return end
    self:restartTimer()
end

function AutoWords:onSuspend()
    self:stopScheduling("suspended")
end

function AutoWords:onResume()
    if self:isActive() then
        self:scheduleForCurrentPage()
    end
end

function AutoWords:onCloseDocument()
    self:stopScheduling("document closed")
end

function AutoWords:onCloseWidget()
    self:stopScheduling("widget closed")
    self.task = nil
end

-- ---------------------------------------------------------------------------
-- Menu & dialogs
-- ---------------------------------------------------------------------------

function AutoWords:addToMainMenu(menu_items)
    menu_items.autowords = {
        sorting_hint = "navi",
        text_func = function()
            if self:isActive() then
                return T(_("AutoWords: %1 %2/min"), self.speed, self:unitName())
            end
            return _("AutoWords")
        end,
        checked_func = function() return self:isActive() end,
        callback = function(menu)
            -- Keep the menu around so the checkmark can be refreshed when the
            -- setting is changed from inside our dialogs (the menu stays open
            -- behind them, since the item has a checked_func).
            self._menu = menu
            self:showSettingsDialog()
        end,
    }
end

--- Refresh the main menu entry (checkmark / speed in its text).
--- The menu may already be gone (settings opened from a gesture), hence pcall.
function AutoWords:refreshMenu()
    local menu = self._menu
    if not menu then return end
    local ok, err = pcall(function() menu:updateItems() end)
    if not ok then
        logger.dbg("AutoWords: could not refresh menu:", err)
        self._menu = nil
    end
end

--- Main dialog: shows the current page's text count, the delay it implies,
--- and gives access to speed setting / calibration.
function AutoWords:showSettingsDialog()
    local info
    if not self:isSupportedDocument() then
        info = _("This document type is not supported: AutoWords needs the text layout engine (EPUB, FB2, TXT ...), so PDF and DJVU cannot be measured.")
    else
        local count = self:currentCount()
        if count == nil then
            info = _("The text of this page could not be read.")
        else
            local delay = self:delayForCount(count)
            info = T(_("This page: %1 %2\nReading speed: %3 %2/min\n→ AutoWords waits %4 s on this page"),
                count, self:unitName(), self.speed, string.format("%.1f", delay))
        end
    end

    local dialog
    dialog = ButtonDialog:new{
        title = info,
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Reading speed"),
                    callback = function()
                        UIManager:close(dialog)
                        self:showSpeedDialog()
                    end,
                },
                {
                    text = _("Calibrate on this page"),
                    enabled = self:isSupportedDocument(),
                    callback = function()
                        UIManager:close(dialog)
                        self:showCalibrateDialog()
                    end,
                },
            },
            {
                {
                    text = self.enabled and _("Stop") or _("Start"),
                    callback = function()
                        UIManager:close(dialog)
                        self:setEnabled(not self.enabled)
                    end,
                },
                {
                    text = _("More settings"),
                    callback = function()
                        UIManager:close(dialog)
                        self:showMoreDialog()
                    end,
                },
            },
            {
                {
                    text = _("Close"),
                    callback = function() UIManager:close(dialog) end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function AutoWords:showSpeedDialog()
    local count = self:isSupportedDocument() and self:currentCount() or nil
    local info
    if count then
        info = T(_("This page holds %1 %2.\nAt %3 %2 per minute AutoWords waits %4 s here."),
            count, self:unitName(), self.speed,
            string.format("%.1f", self:delayForCount(count)))
    else
        info = _("Page text unavailable.")
    end

    UIManager:show(SpinWidget:new{
        title_text = _("Reading speed"),
        info_text = info,
        value = self.speed,
        value_min = 10,
        value_max = 3000,
        value_step = 10,
        value_hold_step = 100,
        default_value = 300,
        unit = self:unitName() .. "/min",
        ok_text = _("Set"),
        cancel_text = _("Cancel"),
        callback = function(spin)
            self.speed = math.floor(spin.value + 0.5)
            G_reader_settings:saveSetting("autowords_speed", self.speed)
            if self:isActive() then
                self:scheduleForCurrentPage()
            end
            self:refreshMenu()
        end,
    })
end

--- Calibrate: the reader tells how long this page takes, we derive the speed.
function AutoWords:showCalibrateDialog()
    local count = self:currentCount()
    if not count or count <= 0 then
        UIManager:show(InfoMessage:new{
            text = _("There is no countable text on this page, so it cannot be used for calibration."),
            timeout = 3,
        })
        return
    end
    UIManager:show(SpinWidget:new{
        title_text = _("Calibrate on this page"),
        info_text = T(_("This page holds %1 %2.\nHow many seconds do you need to read it?"),
            count, self:unitName()),
        value = math.max(1, math.floor(self:delayForCount(count) + 0.5)),
        value_min = 1,
        value_max = 3600,
        value_step = 1,
        value_hold_step = 10,
        default_value = 60,
        unit = _("s"),
        ok_text = _("Calibrate"),
        cancel_text = _("Cancel"),
        callback = function(spin)
            local secs = spin.value
            if secs and secs > 0 then
                self.speed = math.max(1, math.floor(count * 60 / secs + 0.5))
                G_reader_settings:saveSetting("autowords_speed", self.speed)
                if self:isActive() then
                    self:scheduleForCurrentPage()
                end
                self:refreshMenu()
                UIManager:show(InfoMessage:new{
                    text = T(_("Reading speed set to %1 %2/min."), self.speed, self:unitName()),
                    timeout = 3,
                })
            end
        end,
    })
end

function AutoWords:showMoreDialog()
    local dialog
    dialog = ButtonDialog:new{
        title = T(_("AutoWords settings\ncounting: %1 | wait after touch: %2"),
            self:unitName(), self.restart_on_input and _("yes") or _("no")),
        title_align = "center",
        buttons = {
            {
                {
                    text = T(_("Minimum delay: %1 s"), self.min_delay),
                    callback = function()
                        UIManager:close(dialog)
                        self:showMinDelayDialog()
                    end,
                },
                {
                    text = T(_("Maximum delay: %1"), self.max_delay > 0 and T(_("%1 s"), self.max_delay) or _("none")),
                    callback = function()
                        UIManager:close(dialog)
                        self:showMaxDelayDialog()
                    end,
                },
            },
            {
                {
                    text = self.count_mode == "words" and _("Count: words") or _("Count: characters"),
                    callback = function()
                        self.count_mode = self.count_mode == "words" and "chars" or "words"
                        G_reader_settings:saveSetting("autowords_count_mode", self.count_mode)
                        self.cache_key = nil
                        if self:isActive() then
                            self:scheduleForCurrentPage()
                        end
                        self:refreshMenu()
                        UIManager:close(dialog)
                        self:showMoreDialog()
                    end,
                },
                {
                    text = self.restart_on_input and _("Wait after touch: on") or _("Wait after touch: off"),
                    callback = function()
                        self.restart_on_input = not self.restart_on_input
                        G_reader_settings:saveSetting("autowords_restart_on_input", self.restart_on_input)
                        UIManager:close(dialog)
                        self:showMoreDialog()
                    end,
                },
            },
            {
                {
                    text = T(_("Page distance: %1"), self.distance),
                    callback = function()
                        UIManager:close(dialog)
                        self:showDistanceDialog()
                    end,
                },
                {
                    text = _("Close"),
                    callback = function() UIManager:close(dialog) end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function AutoWords:showMinDelayDialog()
    UIManager:show(SpinWidget:new{
        title_text = _("Minimum delay"),
        info_text = _("Shortest time AutoWords will ever wait on a page (useful for pages holding only an image)."),
        value = self.min_delay,
        value_min = 0,
        value_max = 300,
        value_step = 1,
        value_hold_step = 10,
        default_value = 2,
        unit = _("s"),
        ok_text = _("Set"),
        callback = function(spin)
            self.min_delay = math.floor(spin.value + 0.5)
            G_reader_settings:saveSetting("autowords_min_delay", self.min_delay)
            if self:isActive() then
                self:scheduleForCurrentPage()
            end
        end,
    })
end

function AutoWords:showMaxDelayDialog()
    UIManager:show(SpinWidget:new{
        title_text = _("Maximum delay"),
        info_text = _("Longest time AutoWords will wait on a page. Set to 0 for no limit."),
        value = self.max_delay,
        value_min = 0,
        value_max = 3600,
        value_step = 5,
        value_hold_step = 30,
        default_value = 0,
        unit = _("s"),
        ok_text = _("Set"),
        callback = function(spin)
            self.max_delay = math.floor(spin.value + 0.5)
            G_reader_settings:saveSetting("autowords_max_delay", self.max_delay)
            if self:isActive() then
                self:scheduleForCurrentPage()
            end
        end,
    })
end

function AutoWords:showDistanceDialog()
    UIManager:show(SpinWidget:new{
        title_text = _("Page distance"),
        info_text = _("How far the view moves on each turn. 1 = one screen. Values below 1 only apply in scroll mode; in paged mode the move is rounded to whole pages."),
        value = self.distance,
        value_min = 0.05,
        value_max = 2,
        value_step = 0.05,
        value_hold_step = 0.25,
        precision = "%.2f",
        default_value = 1,
        ok_text = _("Set"),
        callback = function(spin)
            self.distance = spin.value
            G_reader_settings:saveSetting("autowords_distance", self.distance)
            if self:isActive() then
                self:scheduleForCurrentPage()
            end
        end,
    })
end

return AutoWords

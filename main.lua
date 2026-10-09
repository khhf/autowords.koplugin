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

While AutoWords is running, a small icon (a circled "A" by default) is added to
the reader status bars -- the bottom one through
ReaderFooter:addAdditionalFooterContent(), the top "alt status bar" through
ReaderCoptListener:addAdditionalHeaderContent(); where it appears is
configurable.  Tapping the bottom icon opens these settings, detected by a
touch zone that compares the tap position with the position of the icon
characters inside the footer text; a tap anywhere else is passed through to
KOReader's own handler.  The top bar gets no tap target on purpose: that strip
belongs to KOReader's "tap to open the menu" zone.
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
    -- where the little icon is shown: "top", "bottom", "both" or "none".
    -- Default "top": the bottom status bar is left completely alone then.
    icon_position = "top",

    -- runtime state
    retry_delay = 2,
    scheduled = false,
    self_turning = false,
    no_move_count = 0,
    task = nil,
    cur_delay = nil,
    cache_key = nil,
    cache_count = nil,
    footer = nil,           -- ReaderFooter we registered our content with
    footer_content_func = nil,
    footer_content_added = false,
    header_listener = nil,  -- ReaderCoptListener (the alt status bar)
    header_content_func = nil,
    header_content_added = false,
    icon_text = nil,        -- status bar icon character (nil = default)
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
-- Status bar icon
--
-- ReaderFooter renders its whole line as a single TextWidget, so a plugin
-- cannot insert a widget into it.  The supported extension point is
-- addAdditionalFooterContent(func), which contributes *text* -- this is what
-- the stock SSH and ReadTimer plugins use, and it appears in the status bar
-- settings menu as the "External content" item.
--
-- So the icon is a short character sequence, shown only while AutoWords runs,
-- and the tap target covers the status bar and looks for a tap that lands on
-- those characters (they are the last item of the footer text).
-- ---------------------------------------------------------------------------

-- Offered in the icon picker.  The circled letters are the nice ones, but a
-- given font may not have them, hence the plain ASCII fallbacks.
local ICON_CHOICES = { "Ⓐ", "ⓐ", "(A)", "[A]", "A", "●" }

--- The character(s) used as the status bar icon.
function AutoWords:iconText()
    return self.icon_text or ICON_CHOICES[1]
end

--- Normalised icon position: "top", "bottom", "both" or "none".
--- Default is "top": the top status bar needs no side effects on the bottom one.
function AutoWords:iconPosition()
    local position = self.icon_position
    if position == "top" or position == "bottom" or position == "both" or position == "none" then
        return position
    end
    return "top"
end

--- Is the icon wanted in this status bar right now?
-- @tparam string place "top" (the crengine alt status bar) or "bottom"
function AutoWords:iconEnabledAt(place)
    if not self:isActive() then return false end
    local position = self:iconPosition()
    if position == "none" then return false end
    if position == "both" then return true end
    return position == place
end

--- What addAdditionalFooterContent() inserts into the bottom status bar.
--- An empty string means "nothing shown" (the footer skips empty items).
function AutoWords:footerContentText()
    if not self:iconEnabledAt("bottom") then return "" end
    return self:iconText()
end

--- What addAdditionalHeaderContent() prepends to the alt status bar text.
--- crengine draws that whole string right-aligned (crengine/src/lvdocview.cpp:
--- DrawTextString(drawbuf, info.right - piw, ...)), so our text -- which
--- KOReader prepends to the page info -- ends up at the *left end of the
--- right-hand block*, just before the page number.
function AutoWords:headerContentText()
    if not self:iconEnabledAt("top") then return "" end
    return self:iconText()
end

--- Register our content with the *bottom* status bar (idempotent).
---
--- Careful: ReaderFooter:addAdditionalFooterContent() has side effects.  The
--- first time it is called it sets footer.additional_content, rebuilds the mode
--- index and runs updateFooterTextGenerator(), which *rewrites footer.mode* to
--- the first enabled item (readerfooter.lua:999).  That silently changes what
--- the reader's bottom bar shows, so the mode is saved and restored around the
--- call -- and the bottom bar is only ever touched when the user explicitly
--- asks for the icon there.
function AutoWords:setupFooterIcon()
    local view = self.ui and self.ui.view
    local footer = view and view.footer
    if not footer then
        logger.dbg("AutoWords: no reader footer yet, bottom icon unavailable")
        return
    end
    self.footer = footer
    if not self.footer_content_func then
        self.footer_content_func = function() return self:footerContentText() end
    end
    if not self.footer_content_added then
        if not footer.addAdditionalFooterContent then
            logger.warn("AutoWords: this KOReader has no addAdditionalFooterContent()")
            return
        end
        local saved_mode = footer.mode
        footer:addAdditionalFooterContent(self.footer_content_func)
        self.footer_content_added = true
        -- undo the mode switch done by updateFooterTextGenerator()
        if saved_mode and footer.mode ~= saved_mode and footer.applyFooterMode then
            footer:applyFooterMode(saved_mode)
        end
        logger.dbg("AutoWords: bottom status bar content registered")
    end
end

function AutoWords:teardownFooterIcon()
    local footer = self.footer
    if footer and self.footer_content_added and footer.removeAdditionalFooterContent then
        footer:removeAdditionalFooterContent(self.footer_content_func)
    end
    self.footer_content_added = false
    self.footer_content_func = nil
    self.footer = nil
end

--- Register our content with the *top* status bar (the "alt status bar" that
--- crengine draws above the page text).  Purely additive: no side effects on
--- the bottom bar, and no tap target -- that top strip belongs to KOReader's
--- "tap to open the menu" zone (DTAP_ZONE_MENU in defaults.lua), and the text
--- there is painted by crengine, so a plugin cannot know where it landed.
function AutoWords:setupHeaderIcon()
    local listener = self.ui and self.ui.crelistener
    if not listener or not listener.addAdditionalHeaderContent then
        logger.dbg("AutoWords: no alt status bar support in this document")
        return
    end
    self.header_listener = listener
    if not self.header_content_func then
        self.header_content_func = function() return self:headerContentText() end
    end
    if not self.header_content_added then
        listener:addAdditionalHeaderContent(self.header_content_func)
        self.header_content_added = true
        logger.dbg("AutoWords: top status bar content registered")
    end
end

function AutoWords:teardownHeaderIcon()
    local listener = self.header_listener
    if listener and self.header_content_added and listener.removeAdditionalHeaderContent then
        listener:removeAdditionalHeaderContent(self.header_content_func)
    end
    self.header_content_added = false
    self.header_content_func = nil
    self.header_listener = nil
end

--- Register with exactly the status bars the user asked for, and nowhere else.
--- Only called once the document is ready: touching the footer earlier makes it
--- recompute its mode and layout before KOReader finished setting it up, which
--- is what can make the bottom bar come up wrong.
function AutoWords:applyIconPosition()
    local position = self:iconPosition()
    if position == "bottom" or position == "both" then
        self:setupFooterIcon()
    else
        self:teardownFooterIcon()
    end
    if position == "top" or position == "both" then
        self:setupHeaderIcon()
    else
        self:teardownHeaderIcon()
    end
end

function AutoWords:teardownStatusBarIcons()
    self:teardownFooterIcon()
    self:teardownHeaderIcon()
end

--- Repaint the status bars the icon may live in (and only those).
function AutoWords:refreshStatusBars()
    if not self.ui or not self.ui.view then return end
    local position = self:iconPosition()
    if position == "top" or position == "both" then
        -- the alt status bar (top) is redrawn by crengine on this event
        UIManager:broadcastEvent(Event:new("UpdateHeader"))
    end
    if position == "bottom" or position == "both" then
        self.ui:handleEvent(Event:new("UpdateFooter", true))
    end
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
    self:refreshStatusBars()
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
    self.icon_position = G_reader_settings:readSetting("autowords_icon_position")
    if not self.icon_position then
        -- migrate the older boolean setting, if it was ever switched off
        if G_reader_settings:has("autowords_footer_icon")
                and not G_reader_settings:isTrue("autowords_footer_icon") then
            self.icon_position = "none"
        else
            self.icon_position = "top"
        end
    end
    self.icon_text = G_reader_settings:readSetting("autowords_icon_text")
    self.enabled = G_reader_settings:isTrue("autowords_enabled")

    self.task = function() self:tick() end

    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    -- Only used to notice that the reader touched the screen.
    UIManager.event_hook:registerWidget("InputEvent", self)
    -- NOTE: the status bars are deliberately NOT touched here.  Registering our
    -- content makes ReaderFooter recompute its mode and layout, and doing that
    -- before the document is ready is what makes the bottom bar come up wrong.
    -- onReaderReady() does it instead.
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
    -- The document is fully set up now: this is the safe moment to register
    -- with the status bars (see the note in init()).
    self:applyIconPosition()
    if self:isActive() then
        self:scheduleForCurrentPage()
    end
end

--- Screen rotation / resize: the icon is text, so there is nothing to
--- reposition; just make sure the bars are drawn with the current state.
function AutoWords:onSetDimensions()
    self:refreshStatusBars()
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
    self:teardownStatusBarIcons()
end

function AutoWords:onCloseWidget()
    self:stopScheduling("widget closed")
    self:teardownStatusBarIcons()
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
                    text = T(_("Icon position: %1"), self:iconPositionName()),
                    callback = function()
                        UIManager:close(dialog)
                        self:showIconPositionDialog()
                    end,
                },
            },
            {
                {
                    text = T(_("Icon character: %1"), self:iconText()),
                    callback = function()
                        UIManager:close(dialog)
                        self:showIconDialog()
                    end,
                },
                {
                    text = _("Diagnostics"),
                    callback = function()
                        UIManager:close(dialog)
                        self:showDiagnosticDialog()
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

--- Pick the character drawn in the status bar: fonts differ in which of the
--- circled letters they carry, so this has to be user-selectable.
function AutoWords:showIconDialog()
    local rows = {}
    local row = {}
    for _, choice in ipairs(ICON_CHOICES) do
        table.insert(row, {
            text = choice,
            callback = function()
                self.icon_text = choice
                G_reader_settings:saveSetting("autowords_icon_text", choice)
                UIManager:close(self._icon_dialog)
                self:refreshStatusBars()
                self:showMoreDialog()
            end,
        })
        if #row == 3 then
            table.insert(rows, row)
            row = {}
        end
    end
    if #row > 0 then table.insert(rows, row) end
    table.insert(rows, {
        {
            text = _("Close"),
            callback = function() UIManager:close(self._icon_dialog) end,
        },
    })

    self._icon_dialog = ButtonDialog:new{
        title = _("Character shown in the status bar.\nIf it appears as an empty box, please pick another one."),
        title_align = "center",
        buttons = rows,
    }
    UIManager:show(self._icon_dialog)
end

--- Human readable name of the current icon position.
function AutoWords:iconPositionName()
    local names = {
        top = _("top bar"),
        bottom = _("bottom bar"),
        both = _("top + bottom"),
        none = _("hidden"),
    }
    return names[self.icon_position or "both"] or names.both
end

--- Where to show the icon: top bar, bottom bar, both, or nowhere.
function AutoWords:showIconPositionDialog()
    local choices = {
        { value = "top", text = _("Top status bar") },
        { value = "bottom", text = _("Bottom status bar") },
        { value = "both", text = _("Top + bottom") },
        { value = "none", text = _("Do not show") },
    }
    local rows = {}
    for _, choice in ipairs(choices) do
        local value = choice.value
        table.insert(rows, {
            {
                text = choice.text .. (self.icon_position == value and "  ✓" or ""),
                callback = function()
                    self.icon_position = value
                    G_reader_settings:saveSetting("autowords_icon_position", value)
                    UIManager:close(self._position_dialog)
                    -- register with / unregister from the bars that changed
                    self:applyIconPosition()
                    self:refreshStatusBars()
                    self:showMoreDialog()
                end,
            },
        })
    end
    table.insert(rows, {
        {
            text = _("Close"),
            callback = function() UIManager:close(self._position_dialog) end,
        },
    })

    self._position_dialog = ButtonDialog:new{
        title = _("Where to show the icon.\nThe top status bar needs KOReader's \"Alt status bar\" to be enabled first."),
        title_align = "center",
        buttons = rows,
    }
    UIManager:show(self._position_dialog)
end

--- Everything that could explain "the icon does not show up".
function AutoWords:showDiagnosticDialog()
    local view = self.ui and self.ui.view
    local footer = view and view.footer
    local configurable = self.ui and self.ui.document and self.ui.document.configurable
    local function yesno(value)
        return value and _("yes") or _("no")
    end
    local lines = {
        T(_("Plugin loaded: %1"), _("yes")),
        T(_("Running: %1"), yesno(self.enabled)),
        T(_("Countable document: %1"), yesno(self:isSupportedDocument())),
        T(_("Icon position: %1"), self:iconPositionName()),
        T(_("Status bar found: %1"), yesno(footer ~= nil)),
        T(_("Status bar visible: %1"), yesno(view and view.footer_visible)),
        T(_("Status bar height: %1 px"), (footer and footer:getHeight()) or 0),
        T(_("Status bar content registered: %1"), yesno(self.footer_content_added)),
        T(_("Alt status bar (top): %1"), yesno(configurable and configurable.status_line == 0)),
        T(_("Alt status bar content registered: %1"), yesno(self.header_content_added)),
        T(_("Icon characters: %1"), self:iconText()),
        T(_("Text on this page: %1 %2"), tostring(self:currentCount() or "-"), self:unitName()),
        T(_("Status bar text: %1"), (footer and footer.footer_text and footer.footer_text.text) or "-"),
    }

    local dialog
    dialog = ButtonDialog:new{
        title = table.concat(lines, "\n"),
        title_align = "left",
        buttons = {
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

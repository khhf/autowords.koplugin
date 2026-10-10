--[[--
Sentence-by-sentence reading guide for AutoWords.

Instead of turning pages, this mode walks the text one sentence at a time and
keeps a single underline under the sentence being read, moving it down as the
reader progresses.

It is deliberately non-invasive:

* The underline uses KOReader's *temporary* highlight -- view.highlight.temp
  with view.highlight.temp_drawer = "underscore".  Temporary highlights are
  painted on screen and never written to the document settings, so nothing this
  plugin draws can show up in the bookmark/annotation list.
* Sentence boundaries come from crengine itself,
  document:extendXPointersToSentenceSegment() -- the same call KOReader uses for
  its "extend selection to sentence" action.  No regex sentence splitting.
* The delay before moving on is the reading time of the sentence plus the
  pauses a reader naturally takes at punctuation and at paragraph ends,
  floored by a minimum so a page of short dialogue lines does not race past.

Only crengine documents (EPUB, FB2, TXT ...) are supported: PDF has no
sentence xpointers, and the guide is a no-op there.
]]

local Count = require("autowords_count")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Guide = {}
Guide.__index = Guide

--- Defaults for the pacing knobs (all in seconds unless noted).
Guide.defaults = {
    min_sentence_delay = 0.8,  -- never move on faster than this
    comma_pause = 0.15,
    semicolon_pause = 0.25,
    dash_pause = 0.15,
    end_pause = 0.4,           -- added once per sentence end (max twice)
    paragraph_pause = 0.6,     -- the sentence ends with a line/paragraph break
    punct_scale = 1.0,         -- scales all the punctuation pauses at once
    scroll_position = 0.33,    -- keep the current sentence at this fraction of the usable height
    scroll_trigger = 0.66,     -- scroll once it would fall below this fraction
}

function Guide:new(plugin)
    return setmetatable({
        plugin = plugin,
        scheduled = false,
        paused = false,
        history = nil,        -- xpointers of the sentences shown, for goBack()
        xp = nil,             -- xpointer the next sentence starts at
        segment = nil,        -- { text, pos0, pos1 } of the current sentence
        saved_temp_drawer = nil,
    }, self)
end

--- Read a pacing knob from the plugin instance (stored as guide_<name>),
--- falling back to the default.
function Guide:setting(name)
    local value = self.plugin and self.plugin["guide_" .. name]
    if value == nil or value == false then value = Guide.defaults[name] end
    return value
end

--- Remember a decision, both in the log and in a small in-memory buffer.
---
--- The buffer matters on Android: KOReader does not always write a crash.log
--- there, so the Diagnostics dialog shows these lines instead.
function Guide:trace(fmt, ...)
    local line = string.format(fmt, ...)
    logger.dbg("AutoWords guide: " .. line)
    self.trace_log = self.trace_log or {}
    table.insert(self.trace_log, line)
    while #self.trace_log > 24 do
        table.remove(self.trace_log, 1)
    end
end

-- ---------------------------------------------------------------------------
-- Document support
-- ---------------------------------------------------------------------------

function Guide:isSupported()
    local ui = self.plugin and self.plugin.ui
    if not ui or not ui.document or not ui.rolling then return false end
    local doc = ui.document
    return doc.getTextFromPositions ~= nil
        and doc.getNextVisibleChar ~= nil
        and doc.getTextFromXPointers ~= nil
        and doc.getScreenBoxesFromPositions ~= nil
end

function Guide:isActive()
    local ui = self.plugin and self.plugin.ui
    -- Never touch the document through the FFI once it has been closed: a
    -- stray timer callback running after onCloseDocument would be calling into
    -- a torn-down crengine object.
    if not ui or not ui.document or not ui.rolling then return false end
    if ui.document.is_open == false then return false end
    return self.plugin.enabled
        and self.plugin.reading_mode == "sentence"
        and self:isSupported()
end

-- ---------------------------------------------------------------------------
-- Pacing (pure logic, no KOReader state involved)
-- ---------------------------------------------------------------------------

--- How long to stay on this sentence.
-- @tparam string text the sentence text
-- @treturn number seconds
function Guide:delayForSentence(text)
    local speed = tonumber(self.plugin.speed) or 300
    if speed <= 0 then speed = 300 end

    local units = Count.count(text, self.plugin.count_mode or "chars")
    local delay = units * 60 / speed

    local punct = Count.punctuation(text)
    local scale = self:setting("punct_scale") or 1
    delay = delay + scale * (
          punct.comma * self:setting("comma_pause")
        + punct.semicolon * self:setting("semicolon_pause")
        + punct.dash * self:setting("dash_pause")
        + math.min(punct.sentence_end, 2) * self:setting("end_pause"))

    if text:find("\n%s*$") then
        delay = delay + self:setting("paragraph_pause")
    end

    local min_delay = self:setting("min_sentence_delay")
    if min_delay and delay < min_delay then delay = min_delay end
    return delay
end

-- ---------------------------------------------------------------------------
-- Sentence lookup
--
-- Deliberately NOT document:extendXPointersToSentenceSegment(): it only works
-- when the position sits right after punctuation or whitespace and returns
-- nothing otherwise, and walking back to such a position turned out to be
-- unreliable on real books (40 words back still found nothing on a Chinese
-- novel).  Instead the guide scans forward from the start of the visible text
-- and stops at the first sentence-ending punctuation.  That only uses
-- getTextFromPositions / getNextVisibleChar / getTextFromXPointers, all of
-- which KOReader itself uses.
-- ---------------------------------------------------------------------------

--- Where the visible text starts (xpointer of the first word on screen).
-- @treturn string|nil xpointer of the visible text start
function Guide:visibleStart()
    local doc = self.plugin.ui.document
    local ok, res = pcall(doc.getTextFromPositions, doc,
        { x = 0, y = 0 },
        { x = Screen:getWidth(), y = Screen:getHeight() },
        true)
    if not ok then
        self.last_reason = "call_failed"
        self:trace("getTextFromPositions failed: %s", tostring(res))
        return nil
    end
    if not res or not res.pos0 or res.pos0 == "" then
        self.last_reason = "no_visible_text"
        return nil
    end
    return res.pos0
end

--- Does this one-character chunk end a sentence?
function Guide.endsSentence(chunk)
    if not chunk or chunk == "" then return false end
    local cp = Count.decode(chunk, 1, #chunk)
    if not cp then return false end
    return Count.punctClassOf(cp) == "sentence_end"
end

--- Scan forward from xp until a sentence ends.
-- @tparam string xp start xpointer
-- @tparam[opt=400] number max_chars hard limit, so a paragraph without any
--        punctuation cannot turn into an endless scan
-- @treturn table|nil { text, pos0, pos1 }
function Guide:scanSentence(xp, max_chars)
    local doc = self.plugin.ui.document
    local limit = max_chars or 400
    local parts = {}
    local cur = xp
    local count = 0
    for _ = 1, limit do
        local ok, nxt = pcall(doc.getNextVisibleChar, doc, cur)
        if not ok or not nxt or nxt == cur or nxt == "" then break end
        local ok2, chunk = pcall(doc.getTextFromXPointers, doc, cur, nxt)
        if not ok2 or not chunk or chunk == "" then break end
        parts[#parts + 1] = chunk
        count = count + 1
        cur = nxt
        if Guide.endsSentence(chunk) then break end
    end
    if count == 0 then
        self.last_reason = "no_text_scanned"
        return nil
    end
    self.last_reason = nil
    self.scanned_chars = count
    return { pos0 = xp, pos1 = cur, text = table.concat(parts) }
end

--- The sentence starting at self.xp (at the visible text start the first time).
-- @treturn table|nil segment
function Guide:currentSegment()
    if not self.xp then
        local start = self:visibleStart()
        if not start then
            self.stop_reason = "no_position"
            return nil
        end
        self.xp = start
        self:trace("starting at the visible text start")
    end

    local seg = self:scanSentence(self.xp, 400)
    if not seg then
        self.stop_reason = "end_of_document"
        self:trace("nothing to read from %s", tostring(self.xp))
        return nil
    end
    return seg
end


--- The screen boxes of a segment, one per displayed line.
function Guide:sentenceBoxes(seg)
    local doc = self.plugin.ui.document
    local ok, boxes = pcall(doc.getScreenBoxesFromPositions, doc, seg.pos0, seg.pos1, true)
    if not ok then
        logger.warn("AutoWords guide: getScreenBoxesFromPositions failed:", boxes)
        return nil
    end
    if not boxes or #boxes == 0 then
        logger.dbg("AutoWords guide: the sentence has no screen boxes")
        return nil
    end
    return boxes
end

-- ---------------------------------------------------------------------------
-- Drawing the underline
-- ---------------------------------------------------------------------------

--- Paint the underline under the current sentence.
--- Uses the temporary highlight, which is never persisted.
function Guide:showUnderline(seg)
    local view = self.plugin.ui.view
    if not view or not view.highlight then return end
    local boxes = self:sentenceBoxes(seg)
    if not boxes then return end

    if self.saved_temp_drawer == nil then
        self.saved_temp_drawer = view.highlight.temp_drawer
    end
    view.highlight.temp_drawer = "underscore"

    local doc = self.plugin.ui.document
    local page_ok, page = pcall(doc.getCurrentPage, doc)
    if not page_ok or not page then page = 1 end
    view.highlight.temp = { [page] = boxes }
    self.last_boxes = #boxes
    self:trace("underline on page %s over %d line(s), first at y=%s",
        tostring(page), #boxes, tostring(boxes[1] and boxes[1].y))
    self:redraw()
end

--- Remove the underline and restore the previous temporary highlight style.
function Guide:clearUnderline()
    local view = self.plugin.ui.view
    if not view or not view.highlight then return end
    if self.saved_temp_drawer ~= nil then
        view.highlight.temp_drawer = self.saved_temp_drawer
        self.saved_temp_drawer = nil
    end
    view.highlight.temp = {}
    self:redraw()
end

function Guide:redraw()
    local view = self.plugin.ui.view
    if not view then return end
    UIManager:setDirty(view.dialog or view, "partial")
end

-- ---------------------------------------------------------------------------
-- Scrolling
-- ---------------------------------------------------------------------------

--- Keep the current sentence comfortably on screen: if it fell below the
--- trigger line (or above the top), scroll so that it sits at the configured
--- fraction of the usable height.
function Guide:ensureVisible(seg)
    if self.plugin.guide_scroll == false then return end
    local ui = self.plugin.ui
    local rolling = ui.rolling
    local doc = ui.document
    if not rolling or not doc.getPosFromXPointer or not rolling._gotoPos then return end

    local ok, pos = pcall(doc.getPosFromXPointer, doc, seg.pos0)
    if not ok or not pos or not pos.y then
        logger.dbg("AutoWords guide: cannot locate the sentence for scrolling")
        return
    end

    local view = ui.view
    local footer_h = 0
    if view and view.footer_visible and view.footer and view.footer.getHeight then
        local ok2, h = pcall(view.footer.getHeight, view.footer)
        if ok2 then footer_h = h or 0 end
    end
    local usable_h = Screen:getHeight() - footer_h
    if usable_h <= 0 then return end

    local current = rolling.current_pos or 0
    local screen_y = pos.y - current
    local trigger = usable_h * self:setting("scroll_trigger")
    if screen_y >= 0 and screen_y <= trigger then
        return -- already comfortably placed
    end

    local target_y = math.floor(usable_h * self:setting("scroll_position"))
    local new_pos = pos.y - target_y
    if new_pos < 0 then new_pos = 0 end
    logger.dbg("AutoWords guide: scrolling to", new_pos, "(sentence was at", screen_y, ")")
    local ok3, err = pcall(rolling._gotoPos, rolling, new_pos, false)
    if not ok3 then
        logger.warn("AutoWords guide: scrolling failed:", err)
    end
end

-- ---------------------------------------------------------------------------
-- The loop
-- ---------------------------------------------------------------------------

function Guide:scheduleIn(delay)
    -- Remember the exact function reference we schedule, so unscheduling cannot
    -- miss it if the plugin drops its own reference meanwhile.
    self.task = self.plugin.guide_task
    self.scheduled = true
    UIManager:scheduleIn(delay, self.task)
end

function Guide:unschedule()
    if self.scheduled and self.task then
        UIManager:unschedule(self.task)
    end
    self.scheduled = false
end

--- Restart the countdown for the sentence on screen (the reader touched the
--- screen, or wants more time on this sentence).
function Guide:restartTimer()
    if not self:isActive() or not self.scheduled then return end
    local seg = self.segment
    if not seg then return end
    self:unschedule()
    self:scheduleIn(self:delayForSentence(seg.text or ""))
end

--- One step: show the current sentence, then schedule the move to the next one.
function Guide:step()
    self.scheduled = false
    if not self:isActive() then return end
    if self.paused then return end

    -- Do not move while a menu / dialog / dictionary popup is up.
    local top_widget = UIManager:getTopmostVisibleWidget() or {}
    if top_widget.name ~= "ReaderUI" then
        self:scheduleIn(self.plugin.retry_delay or 2)
        return
    end

    local seg = self:currentSegment()
    if not seg then
        self:finish(self.stop_reason or "end_of_document")
        return
    end

    self.segment = seg
    -- remember where this sentence started, so "previous sentence" can go back
    self.history = self.history or {}
    table.insert(self.history, seg.pos0)
    while #self.history > 50 do table.remove(self.history, 1) end
    self:trace("sentence (%d chars) from %s", #(seg.text or ""), tostring(seg.pos0))
    -- scroll first: scrolling clears the temporary highlight and moves the text
    self:ensureVisible(seg)
    self:showUnderline(seg)

    local delay = self:delayForSentence(seg.text or "")
    self.xp = seg.pos1
    self:scheduleIn(delay)
end

--- Move on immediately (manual "next sentence").
function Guide:goForward()
    self:unschedule()
    self:step()
end

--- Go back to the previous sentence (manual "previous sentence").
--- Uses the history of sentences shown, which is far more reliable than trying
--- to walk backwards through the document.
function Guide:goBack()
    self:unschedule()
    local history = self.history
    if not history or #history == 0 then return end
    table.remove(history)                -- drop the sentence being shown
    local previous = table.remove(history)
    if not previous then return end
    self.xp = previous
    self:step()
end

function Guide:start()
    self:unschedule()
    self.paused = false
    self.xp = nil
    self.segment = nil
    if not self:isActive() then return end
    self:step()
end

function Guide:stop()
    self:unschedule()
    self.paused = false
    self.xp = nil
    self.segment = nil
    self:clearUnderline()
end

--- Hold on the sentence being read: no further movement until resumed.
--- The underline stays where it is, so it is obvious where reading stopped.
function Guide:pause()
    if not self:isActive() then return end
    self.paused = true
    self:unschedule()
    logger.dbg("AutoWords guide: paused on", (self.segment and self.segment.text or "?"))
end

--- Continue reading: restart the countdown for the sentence on screen.
function Guide:resume()
    if not self:isActive() then return end
    self.paused = false
    self:unschedule()
    local seg = self.segment
    if seg then
        -- stay on the same sentence, give it its full time again
        self:scheduleIn(self:delayForSentence(seg.text or ""))
    else
        self:step()
    end
end

--- @treturn boolean true when the guide is now paused
function Guide:togglePause()
    if self.paused then
        self:resume()
    else
        self:pause()
    end
    return self.paused
end

--- The guide ran out of text (or was stopped from elsewhere).
function Guide:finish(reason)
    logger.dbg("AutoWords guide: finishing:", reason)
    self:stop()
    self.plugin:onGuideFinished(reason)
end

--- Called when the document/page changed from the outside: redraw the
--- underline for the sentence we are on (KOReader clears highlight.temp itself
--- on every page/pos update).
function Guide:refresh()
    if not self:isActive() then return end
    if not self.segment then return end
    self:showUnderline(self.segment)
end

return Guide

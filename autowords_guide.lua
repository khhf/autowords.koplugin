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
        xp = nil,             -- xpointer the next sentence starts at
        segment = nil,        -- { text, pos0, pos1, sboxes } of the current sentence
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

-- ---------------------------------------------------------------------------
-- Document support
-- ---------------------------------------------------------------------------

function Guide:isSupported()
    local ui = self.plugin and self.plugin.ui
    if not ui or not ui.document or not ui.rolling then return false end
    return ui.document.extendXPointersToSentenceSegment ~= nil
        and ui.document.getScreenBoxesFromPositions ~= nil
end

function Guide:isActive()
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

--- Is this snippet a character a sentence may start after?
--- (whitespace, or punctuation -- which is how crengine itself decides)
function Guide.isBoundaryText(chunk)
    if not chunk or chunk == "" then return true end
    local cp = Count.decode(chunk, 1, #chunk)
    if not cp then return true end
    return Count.isWhitespaceCp(cp) or Count.punctClassOf(cp) ~= nil
end

-- ---------------------------------------------------------------------------
-- Sentence lookup
-- ---------------------------------------------------------------------------

--- Walk backwards from `xp` until we are at a sentence boundary, so that the
--- first sentence shown is a complete one.  Bounded, because a paragraph
--- without any punctuation would otherwise walk the whole document.
function Guide:findSentenceStart(xp)
    local doc = self.plugin.ui.document
    local cur = xp
    for _ = 1, 200 do
        local prev = doc:getPrevVisibleChar(cur)
        if not prev or prev == cur then return cur end
        local chunk = doc:getTextFromXPointers(prev, cur)
        if Guide.isBoundaryText(chunk) then return cur end
        cur = prev
    end
    return cur
end

--- The sentence starting at self.xp (or at the current position the first time).
-- @treturn table|nil segment
function Guide:currentSegment()
    local doc = self.plugin.ui.document
    if not self.xp then
        self.xp = self:findSentenceStart(doc:getXPointer())
    end
    local ok, seg = pcall(doc.extendXPointersToSentenceSegment, doc, self.xp, self.xp)
    if not ok then
        logger.warn("AutoWords guide: extendXPointersToSentenceSegment failed:", seg)
        return nil
    end
    if not seg or not seg.pos0 or not seg.pos1 or seg.pos1 == seg.pos0 then
        return nil
    end
    return seg
end

--- The screen boxes of a segment, one per displayed line.
function Guide:sentenceBoxes(seg)
    local doc = self.plugin.ui.document
    local ok, boxes = pcall(doc.getScreenBoxesFromPositions, doc, seg.pos0, seg.pos1, true)
    if not ok or not boxes or #boxes == 0 then return nil end
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

    local page = self.plugin.ui.document:getCurrentPage()
    view.highlight.temp = { [page] = boxes }
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
    local ui = self.plugin.ui
    local rolling = ui.rolling
    local doc = ui.document
    if not rolling or not doc.getPosFromXPointer then return end

    local ok, pos = pcall(doc.getPosFromXPointer, doc, seg.pos0)
    if not ok or not pos or not pos.y then return end

    local view = ui.view
    local footer_h = 0
    if view and view.footer_visible and view.footer and view.footer.getHeight then
        footer_h = view.footer:getHeight() or 0
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
    rolling:_gotoPos(new_pos, false)
end

-- ---------------------------------------------------------------------------
-- The loop
-- ---------------------------------------------------------------------------

function Guide:scheduleIn(delay)
    self.scheduled = true
    UIManager:scheduleIn(delay, self.plugin.guide_task)
end

function Guide:unschedule()
    if self.scheduled and self.plugin.guide_task then
        UIManager:unschedule(self.plugin.guide_task)
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
        self:finish("end of document")
        return
    end

    self.segment = seg
    -- scroll first: scrolling clears the temporary highlight and moves the text
    self:ensureVisible(seg)
    self:showUnderline(seg)

    local delay = self:delayForSentence(seg.text or "")
    logger.dbg("AutoWords guide: sentence", #(seg.text or ""), "bytes ->", delay, "s")
    self.xp = seg.pos1
    self:scheduleIn(delay)
end

--- Move on immediately (manual "next sentence").
function Guide:goForward()
    self:unschedule()
    self:step()
end

--- Go back to the previous sentence (manual "previous sentence").
function Guide:goBack()
    self:unschedule()
    local doc = self.plugin.ui.document
    local from = (self.segment and self.segment.pos0) or self.xp or doc:getXPointer()
    local prev = doc:getPrevVisibleChar(from)
    if not prev or prev == from then return end
    self.xp = self:findSentenceStart(prev)
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

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
local Event = require("ui/event")
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
        turn_pending = false, -- a page turn is already queued
        visible_boxes = nil,  -- screen boxes of the current sentence
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

--- Where the self-test trace is written.
---
--- Kept in /tmp because that directory exists and is writable on every platform
--- KOReader runs on (Linux, Android, Kindle, Kobo), and because on Android the
--- app data directory is awkward to get at from a PC.  If /tmp cannot be
--- written, the plugin falls back to the KOReader settings directory.
local SELFTEST_PATH = "/tmp/autowords-selftest.txt"

--- Write one line to the self-test file, flushed immediately.
---
--- Flushing matters: a crash kills the process and anything still sitting in a
--- stdio buffer is lost, which is exactly why "run it with -d and look at the
--- output" never showed us anything.
local function selftest_write(line)
    local function write_to(path)
        local fh = io.open(path, "a")
        if not fh then return false end
        fh:write(line, "\n")
        fh:flush()
        fh:close()
        return true
    end

    if not Guide._selftest_ok then
        -- first call: truncate, so every run starts clean
        local fh = io.open(SELFTEST_PATH, "w")
        if fh then
            fh:write("AutoWords self-test\n")
            fh:close()
            Guide._selftest_ok = true
        else
            Guide._selftest_ok = false
        end
    end

    if Guide._selftest_ok and write_to(SELFTEST_PATH) then return end

    -- fall back to the settings directory
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage then
        local ok2, dir = pcall(DataStorage.getSettingsDir, DataStorage)
        if ok2 and dir then
            write_to(dir .. "/autowords-selftest.txt")
        end
    end
end

--- Announce what we are about to do, BEFORE doing it.
---
--- If the next call takes the process down, the self-test file already says
--- which one it was -- that is the whole point of writing before, not after.
function Guide:stage(fmt, ...)
    local line = string.format(fmt, ...)
    self.stage_current = line
    local ok, err = pcall(selftest_write, string.format("%s  >>> %s",
        os.date("%H:%M:%S"), line))
    if not ok then
        logger.warn("AutoWords guide: self-test write failed:", err)
    end
end

--- Remember a decision: in the log, in a small in-memory buffer, and in the
--- self-test file.
---
--- The buffer feeds the Diagnostics dialog, the file survives a crash -- on
--- Android and in minimal Docker images there is no crash.log to look at, and
--- stdout is buffered away when the process dies.
function Guide:trace(fmt, ...)
    local line = string.format(fmt, ...)
    logger.dbg("AutoWords guide: " .. line)
    local ok, err = pcall(selftest_write, string.format("%s  %s",
        os.date("%H:%M:%S"), line))
    if not ok then
        logger.warn("AutoWords guide: self-test write failed:", err)
    end
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
    self:stage("getTextFromPositions (visible area)")
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
    -- Show what we are about to scan, so a bad xpointer is visible in the log.
    local preview = res.text or ""
    if #preview > 40 then preview = preview:sub(1, 40) .. "…" end
    preview = preview:gsub("%s+", " ")
    self:trace("visible text starts at %s: %s", tostring(res.pos0), preview)
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
--- Scan forward from xp until a sentence ends.
---
--- Steps by WORD, not by character, and that is not an optimisation:
--- getNextVisibleChar() returns nothing once it reaches the end of the current
--- text node, so a sentence that starts in one node could never be finished
--- (this is exactly what stopped the guide on a chapter title: the title's text
--- node ended, the scan found nothing more, and it looked like end of book).
--- getNextVisibleWordEnd() walks on into the next node, so scanning crosses
--- from a heading into the following paragraph, and from paragraph to paragraph.
---
--- Two safety nets, because a runaway loop here kills the whole reader: the
--- step limit, and a "seen this position before" check.
-- @tparam string xp start xpointer
-- @tparam[opt=400] number max_chars hard limit, so a paragraph without any
--        punctuation cannot turn into an endless scan
-- @treturn table|nil { text, pos0, pos1 }
function Guide:scanSentence(xp, max_chars)
    local doc = self.plugin.ui.document
    local limit = max_chars or 400
    local parts = {}
    local seen = {}
    local cur = xp
    local count = 0
    local oscillated = false
    for i = 1, limit do
        if i % 25 == 1 then
            -- heartbeat: if the next call hangs or crashes, the file says how
            -- far we got
            self:stage("scanning step %d at %s", i, tostring(cur))
        end
        local ok, nxt = pcall(doc.getNextVisibleWordEnd, doc, cur)
        if not ok or not nxt or nxt == "" then
            -- no more text in this direction: we are at the end of the book
            break
        end
        if nxt == cur then
            -- the word-end is the position itself: try one character so a
            -- single-character word still advances
            local okc, char_next = pcall(doc.getNextVisibleChar, doc, cur)
            if not okc or not char_next or char_next == cur or char_next == "" then break end
            nxt = char_next
        end
        if seen[nxt] then
            oscillated = true
            break
        end
        seen[cur] = true
        local ok2, chunk = pcall(doc.getTextFromXPointers, doc, cur, nxt)
        if not ok2 or not chunk or chunk == "" then break end
        parts[#parts + 1] = chunk
        count = count + 1
        cur = nxt
        if Guide.sentenceEndsIn(chunk) then break end
    end
    if oscillated then
        self:trace("scan stopped advancing at %s", tostring(cur))
    end
    if count == 0 then
        self.last_reason = "no_text_scanned"
        return nil
    end
    self.last_reason = nil
    self.scanned_chars = count
    return { pos0 = xp, pos1 = cur, text = table.concat(parts) }
end

--- Start reading at a sensible place.
---
--- Preference order:
---  1. wherever the reader actually is (the cursor), pulled forward to the
---     first real sentence start -- this is what the reader expects;
---  2. the start of the visible text, if the cursor cannot be used.
---
--- Deliberately NOT "the first thing on screen": on a chapter opening that is
--- the heading, and the underline then sits on the title while the body text is
--- never reached.  Guessing headings from their length does not work either --
--- a short body paragraph looks exactly the same -- so the cursor is used.
-- @treturn string|nil position to start reading at
function Guide:startPosition()
    local doc = self.plugin.ui.document
    local ok, here = pcall(doc.getXPointer, doc)
    if ok and here and here ~= "" then
        -- step forward to the first sentence end, then continue from there:
        -- guarantees we begin on a sentence boundary in the reader's own place
        local seg = self:scanSentence(here, 200)
        if seg then
            self:trace("starting at the reading position %s", tostring(here))
            return here
        end
    end
    local start = self:visibleStart()
    if start then
        self:trace("starting at the visible text start")
    end
    return start
end

--- The sentence starting at self.xp (at the reading position the first time).
-- @treturn table|nil segment
function Guide:currentSegment()
    if not self.xp then
        self.xp = self:startPosition()
        if not self.xp then
            self.stop_reason = "no_position"
            return nil
        end
    end

    -- Keep the first sentences short: a paragraph with no punctuation at all
    -- would otherwise scan far too long before the underline appears.
    local seg = self:scanSentence(self.xp, 200)
    if not seg then
        -- The cursor may sit in a spot that cannot be scanned (an empty node,
        -- the very end of a node).  Once, fall back to the visible text start
        -- instead of declaring the book finished.
        if not self.tried_visible_fallback then
            self.tried_visible_fallback = true
            local start = self:visibleStart()
            if start and start ~= self.xp then
                self:trace("retrying from the visible text start")
                self.xp = start
                seg = self:scanSentence(self.xp, 200)
            end
        end
    end
    if not seg then
        self.stop_reason = "end_of_document"
        self:trace("nothing to read from %s", tostring(self.xp))
        return nil
    end
    return seg
end


--- Does this chunk of scanned text contain a sentence ending?
---
--- Called with the text between two scan steps, which may hold more than one
--- character, so it checks every code point instead of only the first.
function Guide.sentenceEndsIn(text)
    if not text or text == "" then return false end
    local i, len = 1, #text
    while i <= len do
        local cp
        cp, i = Count.decode(text, i, len)
        if not cp then break end
        if Count.punctClassOf(cp) == "sentence_end" then return true end
    end
    return false
end

--- Does this chunk of scanned text end a paragraph or a line?
function Guide.paragraphEndsIn(text)
    if not text or text == "" then return false end
    return text:find("\n%s*$") ~= nil
end

--- Step over a chapter heading that happens to be the first thing on screen.
---
--- NOTE: not used for the first sentence any more -- telling a heading from a
--- short paragraph by its text alone does not work, and it happily skipped
--- whole body paragraphs.  Kept out of the start path on purpose.
-- @tparam string xp position to start from
-- @treturn string position to start reading at
function Guide:skipHeading(xp)
    return xp
end

--- The screen boxes of a segment, one per displayed line.
function Guide:sentenceBoxes(seg)
    local doc = self.plugin.ui.document
    self:stage("getScreenBoxesFromPositions")
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
    -- remember them even on failure, so follow() never works from stale boxes
    self.visible_boxes = boxes
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
    self:stage("repainting the view")
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

--- The path of the self-test file, for the Diagnostics dialog.
function Guide.selftestPath()
    return SELFTEST_PATH
end

-- ---------------------------------------------------------------------------
-- Following the sentence
--
-- Everything here works from the SCREEN boxes of the sentence -- the same ones
-- the underline is drawn from.  It used to use
-- document:getPosFromXPointer(), which returns a DOCUMENT coordinate (tens of
-- thousands of pixels into the book); comparing that against the screen height
-- made every sentence look like it had fallen off the page, so the guide turned
-- the page over and over and took the reader down with it.
-- ---------------------------------------------------------------------------

--- The vertical range of the screen that text can occupy.
-- @treturn number top edge, @treturn number bottom edge
function Guide:visibleArea()
    local ui = self.plugin.ui
    local view = ui.view
    local footer_h = 0
    if view and view.footer_visible and view.footer and view.footer.getHeight then
        local ok, h = pcall(view.footer.getHeight, view.footer)
        if ok and type(h) == "number" then footer_h = h end
    end
    local header_h = 0
    local doc = ui.document
    if doc and doc.getHeaderHeight then
        local ok, h = pcall(doc.getHeaderHeight, doc)
        if ok and type(h) == "number" then header_h = h end
    end
    return header_h, Screen:getHeight() - footer_h
end

--- Keep the sentence being read on screen.
---
--- Paged mode: the underline can only sit on a page that is showing, so once
--- the sentence drops below the visible page the view moves on.
--- Scroll mode: the sentence is nudged to the configured fraction of the
--- screen.
-- @tparam table boxes screen boxes of the sentence, one per displayed line
function Guide:follow(boxes)
    if self.plugin.guide_scroll == false then return end
    if not boxes or #boxes == 0 then return end
    local ui = self.plugin.ui
    local view = ui.view
    if not view then return end

    local top, bottom = self:visibleArea()
    if bottom <= top then return end

    local first, last = boxes[1], boxes[#boxes]
    if type(first.y) ~= "number" or type(last.y) ~= "number" then return end
    local sentence_top = first.y
    local sentence_bottom = last.y + (last.h or 0)
    self.last_sentence_top = sentence_top
    self.last_sentence_bottom = sentence_bottom
    self:trace("sentence occupies y=%d..%d, text area is %d..%d",
        sentence_top, sentence_bottom, top, bottom)

    if (view.view_mode or "page") == "page" then
        -- Only turn when the sentence STARTS below the visible area.  A
        -- sentence that merely runs over the bottom edge is the one being read
        -- right now, and turning the page would take it away mid-read; the
        -- following sentence triggers the turn instead.
        if sentence_top < bottom then
            return
        end
        self:turnPage()
    else
        self:scrollTo(sentence_top, top, bottom)
    end
end

--- Move on to the next page.
---
--- Never synchronously: this runs inside a UIManager timer callback, and turning
--- the page from there re-enters the layout and the repaint while the timer is
--- still on the stack.  One turn at a time, too -- otherwise a sentence that
--- stays off-page would queue turns forever.
-- @tparam[opt] function after called once the turn has been performed
function Guide:turnPage(after)
    if self.turn_pending then return end
    self.turn_pending = true
    self:trace("turning the page")
    UIManager:nextTick(function()
        self.turn_pending = false
        if not self:isActive() then return end
        local ok, err = pcall(function()
            self.plugin.ui:handleEvent(Event:new("GotoViewRel", 1))
        end)
        if not ok then
            self:trace("turning the page failed: %s", tostring(err))
            return
        end
        if after then
            local ok2, err2 = pcall(after)
            if not ok2 then
                self:trace("after the page turn: %s", tostring(err2))
            end
        end
    end)
end

--- Scroll the sentence to the configured fraction of the screen.
function Guide:scrollTo(sentence_top, top, bottom)
    local ui = self.plugin.ui
    local rolling = ui.rolling
    if not rolling or not rolling._gotoPos then return end

    local usable_h = bottom - top
    local trigger = top + usable_h * self:setting("scroll_trigger")
    if sentence_top >= top and sentence_top <= trigger then
        return -- comfortably placed
    end

    -- ReaderRolling's offset and the sentence position are both document
    -- coordinates, so their difference is what has to move.
    local current = rolling.current_pos
    if type(current) ~= "number" then
        self:trace("not scrolling: current_pos is %s", tostring(current))
        return
    end
    if current <= 0 and sentence_top <= top then
        self:trace("not scrolling: already at the top of the document")
        return
    end

    local target = top + math.floor(usable_h * self:setting("scroll_position"))
    local new_pos = current + (sentence_top - target)
    if new_pos < 0 then new_pos = 0 end
    if new_pos == current then return end

    self:stage("scrolling to %d", new_pos)
    local ok, err = pcall(rolling._gotoPos, rolling, new_pos, false)
    if not ok then
        self:trace("scrolling failed: %s", tostring(err))
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

    -- Paged mode: the sentence may already be on a page that is not shown yet.
    -- Its screen boxes cannot be read there (crengine only lays out the pages
    -- around the current one), so the page has to be turned first -- judging by
    -- the boxes is exactly what deadlocked the guide: no boxes, so no underline
    -- and no turn either.
    if self:needsPageTurn(seg) then
        self.segment = seg
        self:trace("sentence is not on the shown page yet: turning to it")
        self:turnPage(function() self:step() end)
        return
    end

    self.segment = seg
    -- remember where this sentence started, so "previous sentence" can go back
    self.history = self.history or {}
    table.insert(self.history, seg.pos0)
    while #self.history > 50 do table.remove(self.history, 1) end
    self:trace("sentence (%d chars) from %s", #(seg.text or ""), tostring(seg.pos0))
    -- underline first: it computes the screen boxes that follow() needs
    self:showUnderline(seg)
    self:follow(self.visible_boxes)

    local delay = self:delayForSentence(seg.text or "")
    self.xp = seg.pos1
    self:scheduleIn(delay)
end

--- Is this sentence on a page that has not been reached yet?
---
--- Judged by page number, not by screen boxes: a sentence on the next page has
--- no boxes at all, which is precisely the case where a turn is needed.
function Guide:needsPageTurn(seg)
    local ui = self.plugin.ui
    local view = ui.view
    if not view or (view.view_mode or "page") ~= "page" then return false end
    if self.plugin.guide_scroll == false then return false end
    local doc = ui.document
    if not doc.getPageFromXPointer or not doc.getCurrentPage then return false end

    local ok, sentence_page = pcall(doc.getPageFromXPointer, doc, seg.pos0)
    if not ok or type(sentence_page) ~= "number" then return false end
    local ok2, current_page = pcall(doc.getCurrentPage, doc)
    if not ok2 or type(current_page) ~= "number" then return false end
    if sentence_page <= current_page then return false end

    self:trace("sentence is on page %d while page %d is shown",
        sentence_page, current_page)
    return true
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
    self.turn_pending = false
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

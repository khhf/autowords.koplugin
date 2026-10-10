--[[--
AutoWords sentence guide: underline the sentence being read, one at a time.

How it works (and why it is built this way)
-------------------------------------------
The guide handles one page at a time and never keeps a position across pages:

  1. a single call to document:getTextFromPositions() returns the whole visible
     text, the screen box of every line, and the start/end xpointers;
  2. the text is split into sentences in plain Lua.  No per-character calls into
     crengine: an earlier version scanned character by character and needed
     hundreds of FFI calls per sentence, which is far too slow on a Kindle;
  3. each sentence is mapped onto the lines it covers, and the underline is
     drawn from those line boxes -- the same mechanism KOReader uses for a
     temporary highlight, so nothing is ever written to the annotation store;
  4. sentences follow one another with a delay derived from the configured
     reading speed.  It is the same speed the whole page mode uses, so the two
     stay in step by construction;
  5. once the last sentence of the page has had its time, the page is turned.

Known limits, documented rather than hidden:

  * a sentence that spans two pages is underlined only over the part shown;
  * sentence detection is punctuation based, so a full stop inside quotes or an
    abbreviation can cut a sentence in the wrong place;
  * every sentence costs a (partial) screen refresh.  On e-ink that is the real
    price of this mode -- it draws noticeably more power than plain page
    turning -- so it is off by default and the menu says so.
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
    end_pause = 0.4,
    paragraph_pause = 0.6,
    punct_scale = 1.0,         -- scales every punctuation pause at once
    scroll_position = 0.33,    -- (kept for scroll mode)
    scroll_trigger = 0.66,
}

function Guide:new(plugin)
    return setmetatable({
        plugin = plugin,
        scheduled = false,
        paused = false,
        turn_pending = false,   -- a page turn is already queued
        page = nil,             -- page number the sentences below belong to
        page_sentences = nil,   -- { { text, boxes, from, to }, ... } of that page
        index = 1,              -- which sentence of the page is current
        segment = nil,          -- the sentence being shown
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
-- Self-test file
--
-- Android builds and minimal Docker images have no crash.log, and stdout is
-- lost when the process is killed, so every step is written to a file and
-- flushed immediately.  The Diagnostics dialog shows the same lines.
-- ---------------------------------------------------------------------------

local SELFTEST_PATH = "/tmp/autowords-selftest.txt"

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

--- The path of the self-test file, for the Diagnostics dialog.
function Guide.selftestPath()
    return SELFTEST_PATH
end

-- ---------------------------------------------------------------------------
-- Document support
-- ---------------------------------------------------------------------------

function Guide:isSupported()
    local ui = self.plugin and self.plugin.ui
    if not ui or not ui.document then return false end
    return ui.document.getTextFromPositions ~= nil
end

function Guide:isActive()
    local ui = self.plugin and self.plugin.ui
    -- Never touch the document through the FFI once it has been closed: a
    -- stray timer callback running after onCloseDocument would be calling into
    -- a torn-down crengine object.
    if not ui or not ui.document then return false end
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
-- Splitting the page into sentences (plain Lua, no FFI)
-- ---------------------------------------------------------------------------

--- Closing punctuation that belongs to the sentence before it.
--- So "他说“好。”" ends after the closing quote, not after the full stop.
local CLOSING = {
    [0x0022] = true, -- "
    [0x0027] = true, -- '
    [0x0029] = true, -- )
    [0x005D] = true, -- ]
    [0x007D] = true, -- }
    [0x2019] = true, -- ’
    [0x201D] = true, -- ”
    [0x3009] = true, -- 〉
    [0x300B] = true, -- 》
    [0x300D] = true, -- 」
    [0x300F] = true, -- 』
    [0x3011] = true, -- 】
    [0x3015] = true, -- 〕
    [0xFF09] = true, -- ）
    [0xFF3D] = true, -- ］
}

--- Split the page text into lines, as byte ranges (from is 1-based, to is
--- inclusive).
-- @tparam string text
-- @treturn table list of { from, to }
function Guide.splitLines(text)
    local lines = {}
    local start = 1
    local len = #text
    for i = 1, len do
        if text:byte(i) == 10 then -- \n
            lines[#lines + 1] = { from = start, to = i - 1 }
            start = i + 1
        end
    end
    lines[#lines + 1] = { from = start, to = len }
    return lines
end

--- Split the page text into sentences, as byte ranges (to is exclusive).
--- Leading whitespace is trimmed off each sentence, so a sentence that starts
--- after a line break does not carry that break around (it would show up in the
--- pacing and in the diagnostics).
-- @tparam string text
-- @treturn table list of { text, from, to }
function Guide.splitSentences(text)
    local sentences = {}
    local len = #text
    local start = 1
    local i = 1

    --- First non-space byte at or after `from`, never past `limit`.
    local function skipBlanks(from, limit)
        while from < limit do
            local cp, nxt = Count.decode(text, from, limit)
            if not cp or not Count.isWhitespaceCp(cp) then break end
            from = nxt
        end
        return from
    end

    while i <= len do
        local cp, nxt = Count.decode(text, i, len)
        if not cp then break end

        if Count.punctClassOf(cp) == "sentence_end" then
            -- take any closing punctuation and repeated marks with it
            local stop = nxt
            while stop <= len do
                local cp2, n2 = Count.decode(text, stop, len)
                if not cp2 then break end
                if Count.punctClassOf(cp2) == "sentence_end" or CLOSING[cp2] then
                    stop = n2
                else
                    break
                end
            end
            local from = skipBlanks(start, stop)
            if from < stop then
                sentences[#sentences + 1] = {
                    text = text:sub(from, stop - 1),
                    from = from,
                    to = stop,
                }
            end
            start = stop
            i = stop
        else
            i = nxt
        end
    end

    -- whatever is left over (a paragraph with no sentence end)
    if start <= len then
        local from = skipBlanks(start, len + 1)
        local rest = text:sub(from)
        if rest:match("%S") then
            sentences[#sentences + 1] = { text = rest, from = from, to = len + 1 }
        end
    end

    return sentences
end

--- How many characters are in this byte range (inclusive)?
-- @tparam string text
-- @tparam number from first byte
-- @tparam number to last byte
-- @treturn number character count
function Guide.countChars(text, from, to)
    local n = 0
    local i = from
    while i <= to do
        local cp, nxt = Count.decode(text, i, to + 1)
        if not cp then break end
        n = n + 1
        i = nxt
    end
    return n
end

--- Trim a whole-line box down to the part of it a sentence covers.
---
--- Chinese text is set in a monospaced font, where the share of characters is
--- the share of the width; for proportional scripts this is an approximation.
-- @treturn table|nil trimmed box, or nil when the whole line is covered
function Guide.trimBox(box, line, sentence, text)
    if not text or type(box.w) ~= "number" or box.w <= 0 then return nil end

    local line_chars = Guide.countChars(text, line.from, line.to)
    if line_chars <= 0 then return nil end

    local overlap_from = math.max(sentence.from, line.from)
    local overlap_to = math.min(sentence.to - 1, line.to)
    if overlap_to < overlap_from then return nil end

    local inside = Guide.countChars(text, overlap_from, overlap_to)
    if inside >= line_chars then return nil end -- the sentence fills the line

    local before = Guide.countChars(text, line.from, overlap_from - 1)
    local from_frac = before / line_chars
    local to_frac = (before + inside) / line_chars

    return {
        x = box.x + box.w * from_frac,
        y = box.y,
        w = box.w * (to_frac - from_frac),
        h = box.h,
    }
end

--- Which lines does each sentence cover, and which boxes belong to them.
---
--- The page text and the line boxes come from the same call and line up one to
--- one, so a sentence's line range gives exactly the boxes to underline.
---
--- Those boxes span a whole line, though, and a sentence usually ends part way
--- through one -- underlining the full line made the first words of the NEXT
--- sentence look like they belonged to this one.  So the first and last line of
--- each sentence are trimmed to the part it really covers.
-- @tparam table sentences from splitSentences()
-- @tparam table lines from splitLines()
-- @tparam table boxes screen boxes, one per line
-- @tparam string text the page text those offsets refer to
-- @treturn table sentences with `boxes` and `lines` filled in
function Guide.attachBoxes(sentences, lines, boxes, text)
    local out = {}
    for _, sentence in ipairs(sentences) do
        local first, last
        for i, line in ipairs(lines) do
            if sentence.from <= line.to and sentence.to > line.from then
                if not first then first = i end
                last = i
            end
        end

        local sentence_boxes = {}
        if first and last then
            for i = first, last do
                local line = lines[i]
                local box = line.box or boxes[i]
                if box then
                    local trimmed = Guide.trimBox(box, line, sentence, text)
                    sentence_boxes[#sentence_boxes + 1] = trimmed or box
                end
            end
        end

        out[#out + 1] = {
            text = sentence.text,
            from = sentence.from,
            to = sentence.to,
            lines = { first, last },
            boxes = sentence_boxes,
        }
    end
    return out
end

--- Fallback when the text lines and the screen boxes do not line up: underline
--- one line at a time instead of one sentence at a time.
-- @tparam string text the page text
-- @tparam table lines from splitLines()
-- @tparam table boxes screen boxes
function Guide.sentencesPerLine(text, lines, boxes)
    local out = {}
    local count = math.min(#lines, #boxes)
    for i = 1, count do
        local line = lines[i]
        local line_text = text:sub(line.from, line.to)
        if line_text:match("%S") then
            out[#out + 1] = {
                text = line_text,
                from = line.from,
                to = line.to + 1,
                lines = { i, i },
                boxes = { boxes[i] },
            }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Reading the page
-- ---------------------------------------------------------------------------

--- Read the visible page and split it into sentences.
---
--- Two calls are needed, not one, and that is deliberate.  The text KOReader
--- returns for the page breaks at PARAGRAPHS, not at screen lines: a page of
--- 950 characters came back as 8 newlines for 38 lines of screen.  Mapping
--- sentences onto boxes with that text put every sentence on the wrong line
--- (and fell back to one step per paragraph, so a whole page was "read" in
--- eight steps).
---
--- So the line boxes are taken first, and then the text of each line is read
--- back from its own box.  That gives lines and boxes that really do correspond,
--- one to one.
-- @treturn boolean true when there is something to read
function Guide:loadPage()
    local ui = self.plugin.ui
    local doc = ui.document

    self:stage("getTextFromPositions (read the visible page)")
    local ok, res = pcall(doc.getTextFromPositions, doc,
        { x = 0, y = 0 },
        { x = Screen:getWidth(), y = Screen:getHeight() },
        true)

    if not ok or not res or not res.text or res.text == "" then
        self:trace("cannot read the page text")
        self.page_sentences = nil
        return false
    end

    local page_ok, page = pcall(doc.getCurrentPage, doc)
    self.page = page_ok and page or nil

    local boxes = res.sboxes or {}
    self:trace("page %s: %d bytes, %d box(es)",
        tostring(self.page), #res.text, #boxes)

    if #boxes == 0 then
        -- No line boxes: underline nothing rather than the wrong thing.
        self:trace("the page reported no line boxes")
        self.page_sentences = nil
        return false
    end

    local text, lines = self:readLines(boxes)
    self:trace("read back %d line(s)", #lines)

    if #lines == 0 then
        -- Could not read individual lines: fall back to the page text, which
        -- at least follows the paragraphs.
        text = res.text
        lines = Guide.visualLines(text, Guide.splitLines(text))
        self.page_sentences = Guide.attachBoxes(Guide.splitSentences(text),
            lines, boxes, text)
    else
        self.page_sentences = Guide.attachBoxes(Guide.splitSentences(text),
            lines, boxes, text)
    end

    self.index = 1
    self:trace("page %s has %d step(s)", tostring(self.page), #self.page_sentences)
    return #self.page_sentences > 0
end

--- Read the text of every line box, one call per line.
---
--- Returns the lines joined by newlines together with their byte ranges, so the
--- usual splitting and box mapping work on text whose lines really are screen
--- lines.
-- @tparam table boxes line boxes, top to bottom
-- @treturn string the page text, one line per box
-- @treturn table line ranges in that text
function Guide:readLines(boxes)
    local doc = self.plugin.ui.document
    local width = Screen:getWidth()
    local parts = {}
    local lines = {}
    local offset = 1
    local last = nil

    for i, box in ipairs(boxes) do
        -- Take the half-way points to the neighbouring boxes, so the regions
        -- cannot overlap and no line is read twice.
        local y_top = box.y
        local y_bottom = box.y + (box.h or 1)
        if i > 1 and boxes[i - 1] then
            local prev_bottom = boxes[i - 1].y + (boxes[i - 1].h or 0)
            y_top = (prev_bottom + box.y) / 2
        end
        if i < #boxes and boxes[i + 1] then
            y_bottom = (box.y + (box.h or 0) + boxes[i + 1].y) / 2
        end
        if y_bottom <= y_top then y_bottom = y_top + 1 end

        local ok, line = pcall(doc.getTextFromPositions, doc,
            { x = 0, y = math.floor(y_top) },
            { x = width, y = math.ceil(y_bottom) },
            true)

        local line_text = ok and line and line.text or ""
        line_text = line_text:gsub("^%s+", ""):gsub("%s+$", "")

        -- The regions are cut at half-way points so they cannot overlap, but
        -- crengine snaps a position to the nearest line: if a line comes back
        -- with exactly the previous line's text, the region overlapped it and
        -- reading it twice would duplicate sentences.
        if line_text ~= "" and line_text == last then
            line_text = ""
        end

        -- Keep every line, empty ones included: that way lines and boxes stay
        -- one to one, and an empty line simply holds no characters to map.
        parts[#parts + 1] = line_text
        lines[#lines + 1] = {
            from = offset,
            to = offset + #line_text - 1,
            box = box,
        }
        offset = offset + #line_text + 1 -- +1 for the newline
        if line_text ~= "" then last = line_text end
    end

    return table.concat(parts, "\n"), lines
end

--- The lines that actually hold text: blank lines have no screen box, so they
--- must not take part in the line-to-box mapping.
-- @tparam string text the page text
-- @tparam table lines from splitLines()
-- @treturn table the lines that contain something
function Guide.visualLines(text, lines)
    local visual = {}
    for _, line in ipairs(lines) do
        if line.to >= line.from and text:sub(line.from, line.to):match("%S") then
            visual[#visual + 1] = line
        end
    end
    return visual
end

--- Paint the underline under the sentence being read.
--- Uses the temporary highlight, which is never persisted.
function Guide:showUnderline(sentence)
    local view = self.plugin.ui.view
    if not view or not view.highlight then return end
    local boxes = sentence and sentence.boxes
    if not boxes or #boxes == 0 then
        self:trace("no line boxes for this sentence")
        return
    end

    if self.saved_temp_drawer == nil then
        self.saved_temp_drawer = view.highlight.temp_drawer
    end
    view.highlight.temp_drawer = "underscore"

    local doc = self.plugin.ui.document
    local ok, page = pcall(doc.getCurrentPage, doc)
    if not ok or not page then page = self.page or 1 end
    view.highlight.temp = { [page] = boxes }

    self.last_boxes = #boxes
    self.last_text = sentence.text
    self:trace("underline over %d line(s) of %d: %s", #boxes, #(sentence.text or ""),
        (sentence.text or ""):gsub("%s+", " "):sub(1, 40))
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

-- ---------------------------------------------------------------------------
-- Turning the page
-- ---------------------------------------------------------------------------

--- Move on to the next page.
---
--- Never synchronously: this runs inside a UIManager timer callback, and turning
--- the page from there re-enters the layout and the repaint while the timer is
--- still on the stack.
-- @tparam[opt] function after called once the turn has been performed
function Guide:turnPage(after)
    if self.turn_pending then return end
    self.turn_pending = true
    self:trace("the page has been read: turning it")
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

-- ---------------------------------------------------------------------------
-- The loop
-- ---------------------------------------------------------------------------

function Guide:scheduleIn(delay)
    self:unschedule()
    if not self:isActive() then return end
    self.scheduled = true
    self.task = function() self:step() end
    UIManager:scheduleIn(delay, self.task)
end

function Guide:unschedule()
    if self.task then
        UIManager:unschedule(self.task)
        self.task = nil
    end
    self.scheduled = false
end

--- Restart the countdown for the sentence on screen (after a pause).
function Guide:restartTimer()
    local sentence = self.segment
    if not sentence then return end
    self:scheduleIn(self:delayForSentence(sentence.text or ""))
end

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

    -- The reader may have turned the page (or jumped) themselves: start over on
    -- whatever is on screen now.
    local doc = self.plugin.ui.document
    local ok, page = pcall(doc.getCurrentPage, doc)
    if ok and page and self.page and page ~= self.page then
        self:trace("now reading page %s (was %s)", tostring(page), tostring(self.page))
        self.page_sentences = nil
    end

    if not self.page_sentences then
        if not self:loadPage() then
            self:finish("end_of_document")
            return
        end
    end

    local sentence = self.page_sentences[self.index]
    if not sentence then
        -- Everything on this page has been read.
        self.page_sentences = nil
        self.segment = nil
        if self.plugin.guide_auto_turn == false then
            self:trace("page finished, automatic page turning is off")
            self:finish("end_of_page")
            return
        end
        self:turnPage(function()
            -- Let the view finish laying the new page out before reading it
            -- back: asking straight away can return the page we just left,
            -- whose sentences are already done with -- which turned the page
            -- again immediately, over and over.
            UIManager:scheduleIn(0.3, function()
                if self:isActive() then self:step() end
            end)
        end)
        return
    end

    self.segment = sentence
    self:showUnderline(sentence)

    local delay = self:delayForSentence(sentence.text or "")
    self.index = self.index + 1
    self:trace("step %d/%d done, next in %.1f s", self.index - 1,
        #self.page_sentences, delay)
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
    if not self.page_sentences then return end
    -- step() has already advanced past the sentence on screen
    self.index = math.max(1, self.index - 2)
    self:step()
end

function Guide:start()
    self:unschedule()
    self.paused = false
    self.page_sentences = nil
    self.segment = nil
    if not self:isActive() then return end
    self:step()
end

function Guide:stop()
    self:unschedule()
    self.turn_pending = false
    self.paused = false
    self.page_sentences = nil
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
    if self.segment then
        -- stay on the same sentence, give it its full time again
        self:restartTimer()
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

--- Called when the document/page changed from the outside: KOReader clears
--- highlight.temp on every page/pos update, so the underline may have to be
--- redrawn.
---
--- It is skipped when our highlight is still in place.  Redrawing costs a screen
--- refresh, on e-ink the expensive part of this mode, and the same sentence was
--- being drawn two or three times in a row because several events fire for one
--- position change.
function Guide:refresh()
    if not self:isActive() then return end
    if not self.segment then return end
    local view = self.plugin.ui.view
    local temp = view and view.highlight and view.highlight.temp
    if temp and next(temp) ~= nil then
        return -- still on screen, nothing to do
    end
    self:showUnderline(self.segment)
end

return Guide

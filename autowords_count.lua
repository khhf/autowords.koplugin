--[[
Text counting helpers for AutoWords.

Pure Lua, no dependencies: counting must stay cheap enough to be called
once per page turn on an e-ink device.

Two counting modes:
  * "chars": every non-whitespace UTF-8 code point counts as 1 (CJK friendly).
  * "words": CJK/kana/hangul code points count as 1 each, runs of latin
             letters/digits count as 1 word.
]]--

local Count = {}

local function decode_utf8(s, i, len)
    local b = s:byte(i)
    if not b then return nil, i end
    if b < 0x80 then
        return b, i + 1
    elseif b < 0xE0 then
        local b2 = s:byte(i + 1) or 0x80
        return (b - 0xC0) * 0x40 + (b2 - 0x80), i + 2
    elseif b < 0xF0 then
        local b2 = s:byte(i + 1) or 0x80
        local b3 = s:byte(i + 2) or 0x80
        return (b - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80), i + 3
    else
        local b2 = s:byte(i + 1) or 0x80
        local b3 = s:byte(i + 2) or 0x80
        local b4 = s:byte(i + 3) or 0x80
        return (b - 0xF0) * 0x40000 + (b2 - 0x80) * 0x1000 + (b3 - 0x80) * 0x40 + (b4 - 0x80), i + 4
    end
end

-- Whitespace we never want to count: ASCII space/tab/newlines, NBSP,
-- ideographic space, and the various thin/hair spaces around U+2000.
local function is_whitespace(cp)
    return cp == 0x20 or cp == 0x09 or cp == 0x0A or cp == 0x0D
        or cp == 0xA0 or cp == 0x1680 or cp == 0x2028 or cp == 0x2029
        or cp == 0x202F or cp == 0x205F or cp == 0x3000
        or (cp >= 0x2000 and cp <= 0x200B)
end

-- CJK ideographs, kana, hangul, CJK punctuation-adjacent blocks:
-- these are counted one code point = one "word" in words mode.
local function is_cjk(cp)
    return (cp >= 0x2E80 and cp <= 0x303F)      -- CJK radicals / punctuation
        or (cp >= 0x3040 and cp <= 0x30FF)      -- hiragana, katakana
        or (cp >= 0x3130 and cp <= 0x318F)      -- hangul compatibility jamo
        or (cp >= 0x3400 and cp <= 0x4DBF)      -- CJK ext A
        or (cp >= 0x4E00 and cp <= 0x9FFF)      -- CJK unified
        or (cp >= 0xAC00 and cp <= 0xD7AF)      -- hangul syllables
        or (cp >= 0xF900 and cp <= 0xFAFF)      -- CJK compatibility ideographs
        or (cp >= 0xFF00 and cp <= 0xFF60)      -- fullwidth forms
        or (cp >= 0x20000 and cp <= 0x2FA1F)    -- CJK ext B..
end

local function is_wordish(cp)
    return (cp >= 0x30 and cp <= 0x39)          -- 0-9
        or (cp >= 0x41 and cp <= 0x5A)          -- A-Z
        or (cp >= 0x61 and cp <= 0x7A)          -- a-z
        or (cp >= 0xAA and cp <= 0x2AF)         -- latin supplements/extended
        or (cp >= 0x370 and cp <= 0x3FF)        -- greek
        or (cp >= 0x400 and cp <= 0x4FF)        -- cyrillic
        or (cp >= 0x531 and cp <= 0x58F)        -- armenian
        or (cp >= 0x5D0 and cp <= 0x5EA)        -- hebrew
        or (cp >= 0x600 and cp <= 0x6FF)        -- arabic
end

local function is_latin_extended(cp)
    -- Latin-1 letters (accented chars in western text)
    return cp >= 0xC0 and cp <= 0xFF
end

--- Count text according to mode ("chars" or "words").
-- @string text
-- @string[opt="chars"] mode
-- @treturn number count
function Count.count(text, mode)
    if type(text) ~= "string" or text == "" then return 0 end
    mode = mode or "chars"
    local total = 0
    local i, len = 1, #text
    local in_word = false
    while i <= len do
        local cp
        cp, i = decode_utf8(text, i, len)
        if not cp then break end
        if is_whitespace(cp) then
            in_word = false
        elseif mode == "chars" then
            total = total + 1
        elseif is_cjk(cp) then
            total = total + 1
            in_word = false
        elseif is_wordish(cp) or is_latin_extended(cp) then
            if not in_word then
                total = total + 1
                in_word = true
            end
        else
            -- punctuation, symbols, ...
            in_word = false
        end
    end
    return total
end

return Count

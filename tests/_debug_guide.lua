
package.path = "./?.lua;" .. package.path

-- minimal KOReader stubs
package.preload["gettext"] = function() return function(s) return s end end
package.preload["logger"] = function()
    return { dbg = function() end, warn = function() end, err = function() end }
end
package.preload["pluginshare"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function() end, unschedule = function() end,
        nextTick = function() end, show = function() end, close = function() end,
        setDirty = function() end, broadcastEvent = function() end,
        getTopmostVisibleWidget = function() return { name = "ReaderUI" } end,
    }
end
package.preload["device"] = function()
    return { screen = {
        getWidth = function() return 600 end,
        getHeight = function() return 800 end,
        scaleBySize = function(_, v) return v end,
    } }
end

local CHARS = { "第", "一", "章", "你", "好", "。" }
local doc = {
    is_open = true,
    getCurrentPage = function() return 1 end,
    getTextFromPositions = function()
        return { text = table.concat(CHARS), pos0 = "c0", pos1 = "c6" }
    end,
    getNextVisibleWordEnd = function(_, xp)
        local i = tonumber(xp:match("^c(%d+)$"))
        if not i or i + 1 > #CHARS then return nil end
        return "c" .. (i + 1)
    end,
    getNextVisibleChar = function(_, xp)
        local i = tonumber(xp:match("^c(%d+)$"))
        if not i or i + 1 > #CHARS then return xp end
        return "c" .. (i + 1)
    end,
    getTextFromXPointers = function(_, a)
        local i = tonumber(a:match("^c(%d+)$"))
        if i and i >= 0 and i < #CHARS then return CHARS[i + 1] end
        return ""
    end,
    getScreenBoxesFromPositions = function()
        return { { x = 0, y = 20, w = 100, h = 16 } }
    end,
    getPosFromXPointer = function() return { y = 100 } end,
}

local Guide = require("autowords_guide")
local plugin = {
    enabled = true,
    reading_mode = "sentence",
    speed = 300,
    count_mode = "chars",
    guide_scroll = false,
    guide_task = function() end,
    ui = {
        document = doc,
        view = { highlight = { temp = {}, temp_drawer = "lighten" }, dialog = {}, footer_visible = false },
        rolling = { current_pos = 0, _gotoPos = function() end },
    },
}
plugin.onGuideFinished = function() end

local guide = Guide:new(plugin)
print("--- skipHeading from c0 ---")
local after = guide:skipHeading("c0")
print("result:", after)

print("--- scanSentence from c0 ---")
local s1 = guide:scanSentence("c0", 60)
print("scan(c0):", s1 and ("text=" .. s1.text .. " pos1=" .. s1.pos1) or "nil")

print("--- scanSentence from c3 ---")
local s2 = guide:scanSentence("c3", 200)
print("scan(c3):", s2 and ("text=" .. s2.text .. " pos1=" .. s2.pos1) or "nil")

print("--- full step ---")
guide:step()
print("segment:", guide.segment and guide.segment.text or "nil")
print("stop_reason:", tostring(guide.stop_reason))
print("last_reason:", tostring(guide.last_reason))

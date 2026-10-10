
package.path = "./?.lua;" .. package.path
package.preload["gettext"] = function() return function(s) return s end end
package.preload["logger"] = function()
    return { dbg = function() end, warn = function() end, err = function() end }
end
package.preload["pluginshare"] = function() return {} end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function() end, unschedule = function() end, nextTick = function() end,
        show = function() end, close = function() end, setDirty = function() end,
        broadcastEvent = function() end,
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

local PAGE_LINES = { "你好。世界！", "第三句。" }
local PAGE_BOXES = {
    { x = 0, y = 20, w = 200, h = 16 },
    { x = 0, y = 40, w = 200, h = 16 },
}

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

local calls = {}
local doc = {
    is_open = true,
    getCurrentPage = function() return 5 end,
    getTextFromPositions = function(_, p0, p1)
        table.insert(calls, string.format("y=%s..%s", tostring(p0.y), tostring(p1.y)))
        if p1.y - p0.y > 100 then
            return { text = table.concat(PAGE_LINES, "\n"), pos0 = "c0", pos1 = "c1", sboxes = PAGE_BOXES }
        end
        for i = 1, #PAGE_BOXES do
            local top, bottom = box_region(i)
            if p0.y >= top and p0.y <= bottom then
                return { text = PAGE_LINES[i], pos0 = "L" .. i, pos1 = "L" .. i .. "e" }
            end
        end
        return { text = "", pos0 = "", pos1 = "" }
    end,
}

local Guide = require("autowords_guide")
local plugin = {
    enabled = true, reading_mode = "sentence", speed = 300, count_mode = "chars",
    guide_task = function() end,
    ui = {
        document = doc,
        view = { highlight = { temp = {}, temp_drawer = "lighten" }, dialog = {}, view_mode = "page" },
    },
}
plugin.onGuideFinished = function() end

local guide = Guide:new(plugin)
guide:loadPage()
print("calls:", table.concat(calls, " | "))
print("steps:", guide.page_sentences and #guide.page_sentences or 0)
for i, s in ipairs(guide.page_sentences or {}) do
    print(string.format("  %d: [%s] lines=%s..%s", i, s.text,
        tostring(s.lines[1]), tostring(s.lines[2])))
end

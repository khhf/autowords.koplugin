
package.path = "./?.lua;" .. package.path
package.preload["gettext"] = function() return function(s) return s end end
package.preload["logger"] = function()
    return { dbg = function() end, warn = function() end, err = function() end }
end
package.preload["pluginshare"] = function() return {} end
package.preload["ui/event"] = function()
    return { new = function(_, name, ...) return { name = name, args = { ... } } end }
end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function() end, unschedule = function() end, nextTick = function() end,
        show = function() end, close = function() end, setDirty = function() end,
        broadcastEvent = function() end,
        getTopmostVisibleWidget = function() return { name = "ReaderUI" } end,
    }
end
local SW, SH = 600, 800
package.preload["device"] = function()
    return { screen = {
        getWidth = function() return SW end,
        getHeight = function() return SH end,
        scaleBySize = function(_, v) return v end,
    } }
end

local Guide = require("autowords_guide")

local function run(pos_y, dimen_h, view_mode)
    local events = {}
    local plugin = {
        enabled = true, reading_mode = "sentence", speed = 300, count_mode = "chars",
        guide_scroll = true, guide_task = function() end,
        ui = {
            document = {
                getPosFromXPointer = function() return { y = pos_y } end,
                getHeaderHeight = function() return 0 end,
                getCurrentPage = function() return 1 end,
                getScreenBoxesFromPositions = function() return { { x = 0, y = pos_y, w = 10, h = 10 } } end,
            },
            view = {
                highlight = { temp = {}, temp_drawer = "lighten" }, dialog = {},
                footer_visible = false, view_mode = view_mode,
            },
            rolling = { current_pos = 0, _gotoPos = function() end },
            dimen = { h = dimen_h, w = 600 },
            handleEvent = function(_, ev) table.insert(events, ev.name) end,
        },
    }
    plugin.onGuideFinished = function() end
    local guide = Guide:new(plugin)
    guide:ensureVisible({ pos0 = "c0" })
    return #events, guide.trace_log and guide.trace_log[#guide.trace_log] or "-"
end

print("page mode, y=820, dimen=800 ->", run(820, 800, "page"))
print("page mode, y=300, dimen=800 ->", run(300, 800, "page"))
print("scroll mode, y=820, dimen=800 ->", run(820, 800, "scroll"))

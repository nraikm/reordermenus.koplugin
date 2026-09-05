-- Scan seed 1466206: find the FIRST step whose emitted projection contains
-- two adjacent dividers in any menu; print op + full menu list.
dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))
package.path = project_dir .. "/?.lua;" .. project_dir .. "/tests/?.lua;" .. package.path
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
local _ = require("gettext")
require("main")
local Manager = require("lib.menuorder_manager")
local World = require("tests.lib.sm_world")
local IntentStore = require("lib.intent_store")

local SEED = tonumber(arg and arg[1]) or 1466206
local STEPS = 200
local SEP = "----------------------------"

local w = World:new(SEED)
for step = 1, STEPS do
    local desc = w:step()
    Manager:saveOrder(w.view)
    local view = w.view
    local o = Manager:loadOrder(view)
    for menu_id, list in pairs(o) do
        if type(list) == "table" then
            for i = 2, #list do
                if list[i] == SEP and list[i-1] == SEP then
                    print(string.format("FIRST DOUBLE at step=%d view=%s op=%s menu=%s",
                        step, view, tostring(desc), menu_id))
                    print("LIST:", table.concat(list, ","))
                    print("DEFAULTS:", table.concat(
                        Manager:getDefaultOrder(view)[menu_id] or {}, ","))
                    for k, v in pairs(IntentStore.view(view).separators or {}) do
                        if v.parent == menu_id then
                            print("  sep:", k, tostring(v.after))
                        end
                    end
                    os.exit(2)
                end
            end
        end
    end
end
print("no doubled divider in", STEPS, "steps")

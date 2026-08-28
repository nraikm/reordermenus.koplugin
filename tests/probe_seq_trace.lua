-- Replicate the fuzzer's exact sequence shape: hide via setItemHidden with
-- current_menu_id = the item's parent, then unhide WITHOUT menu id (the fuzz
-- op passes no third arg), across a restart. Watch separator records.
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
local Manager = require("reorderingmenus_menuorder_manager")
local World = require("tests.lib.sm_world")
local IntentStore = require("reorderingmenus_intent_store")

-- Drive a real world to step 47, then hand-run steps 48+.
local SEED, PRE, POST = 1466206, 47, 14
local w = World:new(SEED)
for i = 1, PRE do w:step() end
print("world ready; view=" .. w.view)

local function dumpseps(tag)
    for _, v in ipairs({ "reader", "filemanager" }) do
        for k, sep in pairs(IntentStore.view(v).separators or {}) do
            print(string.format("%s %s.%s parent=%s after=%s", tag, v, k,
                tostring(sep.parent), tostring(sep.after)))
        end
    end
end
dumpseps("pre48")

for i = PRE + 1, PRE + POST do
    local desc = w:step()
    Manager:saveOrder(w.view)
    print(i, desc)
    dumpseps("  post" .. i)
end

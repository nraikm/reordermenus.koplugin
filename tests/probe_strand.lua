-- Minimal-ish repro: hide BOTH items around a stock divider so a divider
-- becomes stranded, then unhide one across restarts. Compare projections.
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
local IntentStore = require("reorderingmenus_intent_store")

local view = "filemanager"
local function fp(menu)
    local o = Manager:loadOrder(view)
    return table.concat(o[menu] or {}, ",")
end

-- defaults.setting: frontlight,night_mode,[d],network,screen,[d],taps_and_gestures,navigation,document,[d],language,device
-- frontlight is conditional (absent on many devices but present here).
-- Hide EVERYTHING before the first divider -> divider strands at list head?
Manager:setItemHidden(view, "frontlight", true, "setting")
Manager:setItemHidden(view, "night_mode", true, "setting")
Manager:saveOrder(view)
print("A1:", fp("setting"))

Manager:dropSessionState(view)
IntentStore.load(true)
require("reorderingmenus_native_writer")._resetCaches()
print("A2 (restarted):", fp("setting"))

-- now hide screen too: first divider strands between nothing and taps-group
Manager:setItemHidden(view, "screen", true, "setting")
Manager:saveOrder(view)
Manager:dropSessionState(view)
IntentStore.load(true)
require("reorderingmenus_native_writer")._resetCaches()
print("A3 (restarted):", fp("setting"))

-- unhide everything back
for _, id in ipairs({ "frontlight", "night_mode", "screen" }) do
    Manager:setItemHidden(view, id, false)
end
Manager:saveOrder(view)
local b = fp("setting")
Manager:dropSessionState(view)
IntentStore.load(true)
require("reorderingmenus_native_writer")._resetCaches()
Manager:saveOrder(view)
Manager:reloadFromDisk(view)
local a = fp("setting")
print("restore B:", b)
print("restore A:", a)
print("STABLE:", b == a)

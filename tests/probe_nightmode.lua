-- Minimal repro of doubled-divider: hide night_mode (frontlight absent ->
-- divider follows it in defaults? no: frontlight is conditional). Sequence:
-- world where "frontlight" was removed upstream, then night_mode hidden.
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
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")

local view = "filemanager"
local function setting_fp()
    local o = Manager:loadOrder(view)
    return table.concat(o.setting or {}, ",")
end

print("baseline:", setting_fp())
print("defaults.setting:", table.concat(Manager:getDefaultOrder(view).setting or {}, ","))

-- Simulate the fuzzer's world: frontlight (conditional) not present.
-- The DEFAULTS list still contains frontlight; projection skips it.

-- Hide night_mode: the divider AFTER night_mode has no live anchor before
-- the next non-hidden item... watch what happens across restart.
Manager:setItemHidden(view, "night_mode", true, "setting")
Manager:saveOrder(view)
print("after hide night_mode:", setting_fp())

Manager:dropSessionState(view)
IntentStore.load(true)
require("reorderingmenus_native_writer")._resetCaches()
local b = setting_fp()
Manager:saveOrder(view)
Manager:reloadFromDisk(view)
local a = setting_fp()
print("roundtrip:", b == a)
print("B:", b)
if b ~= a then print("A:", a) end
for k, v in pairs(IntentStore.view(view).separators or {}) do
    print("  sep:", k, v.parent, tostring(v.after))
end

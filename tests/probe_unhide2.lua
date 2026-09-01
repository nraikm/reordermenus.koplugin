-- Focused: does unhide_item on a stock-resident item leave a stale separator
-- record that then duplicates a divider after restart?
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
local Manager = require("menuorder_manager")
local IntentStore = require("intent_store")

local view = "filemanager"
local function setting_fp()
    local o = Manager:loadOrder(view)
    return table.concat(o.setting or {}, ",")
end

-- 1. hide "network" (stock divider sits right before it)
Manager:setItemHidden(view, "network", true, "setting")
Manager:saveOrder(view)
print("after hide  :", setting_fp())

-- 2. hide "night_mode" too, so TWO records exist; then round trip
Manager:setItemHidden(view, "night_mode", true, "setting")
Manager:saveOrder(view)
print("after hide2 :", setting_fp())
for k, v in pairs(IntentStore.view(view).separators or {}) do
    print("  sep:", k, v.parent, tostring(v.after))
end

-- 3. UNHIDE night_mode (no menu id — like the fuzzer)
Manager:setItemHidden(view, "night_mode", false)
Manager:saveOrder(view)
print("after unhide:", setting_fp())
for k, v in pairs(IntentStore.view(view).separators or {}) do
    print("  sep:", k, v.parent, tostring(v.after))
end

-- 4. restart + save (the round-trip the fuzz checks)
Manager:dropSessionState(view)
IntentStore.load(true)
require("native_writer")._resetCaches()
local before = setting_fp()
Manager:saveOrder(view)
Manager:reloadFromDisk(view)
local after = setting_fp()
print("roundtrip stable:", before == after)
print("B:", before)
if before ~= after then print("A:", after) end

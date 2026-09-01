-- Reproduce the in-session doubling: hide frontlight+night_mode (divider
-- strands at head of EMITTED list), save, then UNHIDE night_mode and save.
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
local function fp(menu)
    local o = Manager:loadOrder(view)
    return table.concat(o[menu] or {}, ",")
end

Manager:setItemHidden(view, "frontlight", true, "setting")
Manager:setItemHidden(view, "night_mode", true, "setting")
Manager:saveOrder(view)
print("A1:", fp("setting"))

-- Unhide night_mode WITHOUT restart (same session), then round-trip.
Manager:setItemHidden(view, "night_mode", false)
Manager:saveOrder(view)
print("A2 same-session unhide:", fp("setting"))
local before = fp("setting")
Manager:dropSessionState(view)
IntentStore.load(true)
require("native_writer")._resetCaches()
Manager:saveOrder(view)
Manager:reloadFromDisk(view)
local after = fp("setting")
print("roundtrip stable:", before == after)
print("B:", before)
if before ~= after then print("A:", after) end

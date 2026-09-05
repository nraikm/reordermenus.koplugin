-- Probe: why does deleteCustomSubmenu think the submenu is empty?
dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local _sd = DataStorage:getSettingsDir()
pcall(os.remove, _sd .. "/reorderingmenus_intent.lua")
pcall(os.remove, _sd .. "/reorderingmenus_materialization.lua")

local Mgr = require("lib.menuorder_manager")
require("main") -- like the suite does

local view = "reader"
Mgr:setLiveRegistrations(view, {}, {})
Mgr:reconcileRegisteredItems(view, {}, {})

local ok, first_id = Mgr:createSubmenu(view, "tools", "Probe Menu")
print("created:", ok, first_id)

print("before stage, tools list:", table.concat(Mgr:getMenuItems(view, "tools") or {}, ","))

-- Stage go_to into it, exactly like the suite
Mgr:stageList(view, first_id, { "go_to" })

local items = Mgr:getMenuItems(view, first_id)
print("submenu items after stage:", items and table.concat(items, ",") or "<nil>")
local tools2 = Mgr:getMenuItems(view, "tools")
print("tools after stage:", tools2 and table.concat(tools2, ",") or "<nil>")

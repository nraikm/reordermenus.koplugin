dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = "/Users/nr/Development/ReorderingMenus/tests/probe_bug2.lua"
local project_dir = "/Users/nr/Development/ReorderingMenus"
package.path = project_dir .. "/?.lua;" .. package.path
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
require("main")
local Manager = require("reorderingmenus_menuorder_manager")
local IntentStore = require("reorderingmenus_intent_store")

local view, other = "filemanager", "reader"
local function clean()
  local sd = DataStorage:getSettingsDir()
  os.remove(sd .. "/filemanager_menu_order.lua"); os.remove(sd .. "/reader_menu_order.lua")
  os.remove(sd .. "/reorderingmenus_intent.lua"); os.remove(sd .. "/reorderingmenus_materialization.lua")
  IntentStore.load(true)
  Manager.default_orders[view]=nil; Manager.default_orders[other]=nil
  Manager:dropSessionState(view); Manager:dropSessionState(other)
end
clean()
Manager:setLiveRegistrations(view, {}, {}); Manager:refreshRegistry(view)
Manager:setLiveRegistrations(other, {}, {}); Manager:refreshRegistry(other)

Manager:setTabHidden(view, "main", true)
print("after hide:", table.concat(Manager:getTabs(view), ","))
-- EXACT fixture op: setItemHidden(tab, false) — not setTabHidden!
print("setItemHidden main false ->", Manager:setItemHidden(view, "main", false))
print("after unhide via setItemHidden:", table.concat(Manager:getTabs(view), ","))

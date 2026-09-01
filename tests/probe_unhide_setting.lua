-- Does the unhide of a removed-from-defaults tab actually clear its record?
package.path = "/Users/nr/Development/ReorderingMenus/?.lua;" .. package.path
dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
_ = require("gettext")
require("main")
local Manager = require("menuorder_manager")
local IntentStore = require("intent_store")
local util = require("util")

local VIEW = "filemanager"
Manager.default_orders[VIEW] =
    util.tableDeepCopy(require("ui/elements/filemanager_menu_order"))
Manager:resetOrder(VIEW)
Manager:dropSessionState(VIEW)
_ = Manager:loadOrder(VIEW)

print("hide search:", Manager:setTabHidden(VIEW, "search", true))
print("hide setting:", Manager:setTabHidden(VIEW, "setting", true))
print("save1:", Manager:saveOrder(VIEW))

-- upstream removes hidden 'setting'
local defaults = util.tableDeepCopy(Manager.default_orders[VIEW])
local tb = defaults["KOMenu:menu_buttons"]
for i, t in ipairs(tb) do
    if t == "setting" then table.remove(tb, i) break end
end
defaults["setting"] = nil
Manager.default_orders[VIEW] = defaults
Manager:dropSessionState(VIEW)
_ = Manager:loadOrder(VIEW)

io.stderr:write("before unhide CANONICAL hidden.setting? " ..
    tostring(IntentStore.view(VIEW).hidden.setting ~= nil) .. "\n")

print("unhide setting:", Manager:setItemHidden(VIEW, "setting", false))
print("save2:", Manager:saveOrder(VIEW))
io.stderr:write("after save2 CANONICAL hidden.setting? " ..
    tostring(IntentStore.view(VIEW).hidden.setting ~= nil) .. "\n")
os.exit(0)

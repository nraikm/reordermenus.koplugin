-- Where does the 'setting' hidden record go? Trace through stagedView.
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
local Manager = require("reorderingmenus_menuorder_manager")
local IntentStore = require("reorderingmenus_intent_store")
local util = require("util")

local VIEW = "filemanager"
Manager.default_orders[VIEW] =
    util.tableDeepCopy(require("ui/elements/filemanager_menu_order"))
Manager:resetOrder(VIEW)
Manager:dropSessionState(VIEW)
_ = Manager:loadOrder(VIEW)

print("hide setting:", Manager:setTabHidden(VIEW, "setting", true))
local sec = Manager:stagedView(VIEW)  -- STAGED view
io.stderr:write("staged hidden has setting? " ..
    tostring(sec.hidden.setting ~= nil) .. "\n")
sec = IntentStore.view(VIEW)          -- CANONICAL (committed?) view
io.stderr:write("canonical hidden has setting? " ..
    tostring(sec.hidden.setting ~= nil) .. "\n")

-- upstream remove while hidden
local defaults = util.tableDeepCopy(Manager.default_orders[VIEW])
for i, t in ipairs(defaults["KOMenu:menu_buttons"]) do
    if t == "setting" then table.remove(defaults["KOMenu:menu_buttons"], i) break end
end
defaults["setting"] = nil
Manager.default_orders[VIEW] = defaults
Manager:dropSessionState(VIEW)
_ = Manager:loadOrder(VIEW)

sec = IntentStore.view(VIEW)
io.stderr:write("after removal, canonical hidden has setting? "
    .. tostring(sec.hidden.setting ~= nil) .. "\n")
os.exit(0)

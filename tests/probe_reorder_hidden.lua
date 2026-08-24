-- Does reorderTabs with a list EXCLUDING a hidden tab clear its record?
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

print("hide search:", Manager:setTabHidden(VIEW, "search", true))
print("hide setting:", Manager:setTabHidden(VIEW, "setting", true))
print("save1:", Manager:saveOrder(VIEW))

-- upstream removes hidden 'setting' from defaults
local defaults = util.tableDeepCopy(Manager.default_orders[VIEW])
local tb = defaults["KOMenu:menu_buttons"]
for i, t in ipairs(tb) do
    if t == "setting" then table.remove(tb, i) break end
end
defaults["setting"] = nil
Manager.default_orders[VIEW] = defaults
Manager:dropSessionState(VIEW)
_ = Manager:loadOrder(VIEW)

-- reorder visible tabs (rotate first to end)
local tabs = Manager:getTabs(VIEW)
local perm = {}
for _, t in ipairs(tabs) do perm[#perm + 1] = t end
table.insert(perm, table.remove(perm, 1))
print("reorder:", Manager:reorderTabs(VIEW, perm))

io.stderr:write('STAGED hidden.setting after reorder? ' ..
    tostring(Manager:stagedView(VIEW).hidden.setting ~= nil) .. '\n')
os.exit(0)

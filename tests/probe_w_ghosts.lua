-- W repro: do pinned-then-vanished items stay visible?
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
local KoreaderAdapter = require("koreader_adapter")
local util = require("util")

local VIEW = "reader"

local function fresh()
    local sd = KoreaderAdapter.getSettingsDir()
    for _, f in ipairs({ VIEW .. "_menu_order.lua", "filemanager_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        pcall(os.remove, sd .. "/" .. f)
    end
    for _, v in ipairs({ VIEW, "filemanager" }) do
        Manager:resetOrder(v); Manager:dropSessionState(v)
    end
    IntentStore.load(true)
end

fresh()
Manager.default_orders[VIEW] =
    util.tableDeepCopy(require("ui/elements/reader_menu_order"))

local W_N = 20
local regs, provs = {}, {}
for i = 1, W_N do
    regs["gh_item_" .. i] = { sorting_hint = "search" }
    provs["gh_item_" .. i] = "widgetX"
end
Manager:setLiveRegistrations(VIEW, regs, provs)
_ = Manager:loadOrder(VIEW)

local txn = IntentStore.openTransaction()
for i = 1, W_N do
    txn:setParentOverride(VIEW, "gh_item_" .. i,
        { provider = "plugin:widgetX", parent = "search" })
end
txn:commit(true)
print("save:", Manager:saveOrder(VIEW))

-- providers vanish
Manager:setLiveRegistrations(VIEW, {}, {})
local order = Manager:loadOrder(VIEW)
local visible = 0
for _, id in ipairs(order.search or {}) do
    if id:find("^gh_item_") then visible = visible + 1 end
end
io.stderr:write("ghosts visible after uninstall: " .. visible .. "\n")
os.exit(0)

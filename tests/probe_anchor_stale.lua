-- Trace via staged view (the transaction, not canonical).
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
Manager.default_orders[VIEW] =
    util.tableDeepCopy(require("ui/elements/reader_menu_order"))
os.remove(KoreaderAdapter.getNativePath(VIEW))
Manager:resetOrder(VIEW)
Manager:dropSessionState(VIEW)
_ = Manager:loadOrder(VIEW)

local function dump(tag)
    local sec = Manager:stagedView(VIEW)  -- THE TRANSACTION VIEW
    for coll, hash in pairs({ parent_override = sec.parent_override,
        position_override = sec.position_override, order_override = sec.order_override }) do
        local n = 0
        for k, r in pairs(hash or {}) do
            n = n + 1
            io.stderr:write(string.format("%s %s[%s] parent=%s after=%s anchor=%s\n",
                tag, coll, tostring(k), tostring(type(r) == "table" and r.parent),
                tostring(type(r) == "table" and r.after),
                tostring(type(r) == "table" and r.anchor)))
        end
        if n == 0 then io.stderr:write(tag .. " " .. coll .. " {}\n") end
    end
end

print("move:", Manager:moveItemToMenu(VIEW, "go_to", "navi", "search"))
dump("after-move")
local defaults = Manager.default_orders[VIEW]
print("stage:", Manager:stageList(VIEW, "search_settings",
    util.tableDeepCopy(defaults.search_settings)))
dump("after-restore-stage")
print("save:", Manager:saveOrder(VIEW))
dump("after-save")
io.stderr:flush()
os.exit(0)

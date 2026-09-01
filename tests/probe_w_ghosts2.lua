-- W repro 2: does the ghost stay visible after a RELOAD boundary?
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

local regs, provs = {}, {}
for i = 1, 5 do
    regs["gh_item_" .. i] = { sorting_hint = "search" }
    provs["gh_item_" .. i] = "widgetX"
end
Manager:setLiveRegistrations(VIEW, regs, provs)
_ = Manager:loadOrder(VIEW)

local txn = IntentStore.openTransaction()
for i = 1, 5 do
    txn:setParentOverride(VIEW, "gh_item_" .. i,
        { provider = "plugin:widgetX", parent = "search" })
end
txn:commit(true)
print("save:", Manager:saveOrder(VIEW))

-- providers vanish; reload boundary (like the suite does with loadOrder)
Manager:setLiveRegistrations(VIEW, {}, {})
local order = Manager:loadOrder(VIEW)
local visible = 0
for _, id in ipairs(order.search or {}) do
    if id:find("^gh_item_") then visible = visible + 1 end
end
io.stderr:write("immediately after vanish (no reload): visible=" ..
    visible .. "\n")

-- now a full session drop + disk reload
Manager:dropSessionState(VIEW)
order = Manager:loadOrder(VIEW)
visible = 0
for _, id in ipairs(order.search or {}) do
    if id:find("^gh_item_") then visible = visible + 1 end
end
io.stderr:write("after session drop+reload: visible=" .. visible .. "\n")

-- and what is in the native file?
local fh = io.open(KoreaderAdapter.getNativePath(VIEW), "rb")
local data = fh and fh:read("*a") or ""
if fh then fh:close() end
local count = 0
for m in data:gmatch("gh_item_%d+") do count = count + 1 end
io.stderr:write("native file mentions gh_item: " .. count .. "\n")
os.exit(0)

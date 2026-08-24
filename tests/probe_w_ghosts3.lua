-- W repro 3: does minimizeIntent drop ghost parent_overrides at save time
-- (before the vanish), leaving nothing to keep them invisible later?
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
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
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

-- 5 plugin items; pin 3 of them via moveItemToMenu (the REAL user path),
-- leave 2 unpinned (they sit at their sorting_hint default).
local regs, provs = {}, {}
for i = 1, 5 do
    regs["gh_item_" .. i] = { sorting_hint = "search" }
    provs["gh_item_" .. i] = "widgetX"
end
Manager:setLiveRegistrations(VIEW, regs, provs)
_ = Manager:loadOrder(VIEW)

print("move 1:", Manager:moveItemToMenu(VIEW, "gh_item_1", "search", "tools"))
print("move 2:", Manager:moveItemToMenu(VIEW, "gh_item_2", "search", "tools"))
print("move 3:", Manager:moveItemToMenu(VIEW, "gh_item_3", "search", "search"))
print("save:", Manager:saveOrder(VIEW))

local sec = IntentStore.view(VIEW)
for id, r in pairs(sec.parent_override or {}) do
    if id:find("^gh_item_") then
        io.stderr:write("intent: " .. id .. " parent=" .. tostring(r.parent) ..
            " anchor=" .. tostring(r.anchor) ..
            " provider=" .. tostring(r.provider) .. "\n")
    end
end

-- providers vanish
Manager:setLiveRegistrations(VIEW, {}, {})
Manager:dropSessionState(VIEW)
local order = Manager:loadOrder(VIEW)
local vis = {}
for _, list in pairs(order) do
    if type(list) == "table" then
        for _, id in ipairs(list) do
            if id:find("^gh_item_") then vis[id] = true end
        end
    end
end
local n = 0
for _ in pairs(vis) do n = n + 1 end
io.stderr:write("visible ghosts after vanish+reload: " .. n .. "\n")
os.exit(0)

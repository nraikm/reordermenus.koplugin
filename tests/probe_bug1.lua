dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = "/Users/nr/Development/ReorderingMenus/tests/probe_bug1.lua"
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
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")

-- clean slate
local sd = DataStorage:getSettingsDir()
os.remove(sd .. "/filemanager_menu_order.lua")
os.remove(sd .. "/reorderingmenus_intent.lua")
os.remove(sd .. "/reorderingmenus_materialization.lua")
IntentStore.load(true)
Manager:dropSessionState("filemanager")

local view = "filemanager"
Manager:setLiveRegistrations(view, {}, {})
Manager:refreshRegistry(view)

local items = Manager:getMenuItems(view, "setting")
print("BEFORE:", table.concat(items, ","))

-- stage a permutation (move first to last)
local staged = {}
for i, id in ipairs(items) do
    if id ~= Manager.SEPARATOR_ID then staged[#staged+1] = id end
end
local first = table.remove(staged, 1)
table.insert(staged, first)
Manager:stageList(view, "setting", staged)

local cs = IntentStore.view(view)
local oo = cs.order_override and cs.order_override["setting"]
local po = cs.position_override
print("AFTER STAGE: order_override[setting]=", oo and table.concat(oo,",") or "nil")
for id, rec in pairs(po or {}) do print("  pos anchor:", id, rec.after) end

local ok = Manager:resetSubmenu(view, "setting")
print("resetSubmenu ->", ok)

cs = IntentStore.view(view)
oo = cs.order_override and cs.order_override["setting"]
print("AFTER RESET: order_override[setting]=", oo and table.concat(oo,",") or "nil")
for id, rec in pairs(cs.position_override or {}) do print("  pos anchor:", id, rec.after) end
for k, sep in pairs(cs.separators or {}) do print("  separator:", k, sep.parent, tostring(sep.after)) end
print("staged section keys with content:")
for coll, tbl in pairs(cs) do
    if type(tbl) == "table" then
        local n = 0
        for _ in pairs(tbl) do n = n + 1 end
        if n > 0 then print("   ", coll, n) end
    end
end

local after = Manager:loadOrder(view)["setting"] or {}
print("PROJECTION after reset:", table.concat(after, ","))

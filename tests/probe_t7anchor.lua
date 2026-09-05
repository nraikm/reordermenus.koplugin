--[[--
probe_t7anchor.lua — where did the external help-swap anchor go?
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
local _ = require("gettext")
require("main")

local MenuOrderManager = require("lib.menuorder_manager")
local IntentStore = require("lib.intent_store")
local NativeWriter = require("lib.native_writer")
local UIScreens = require("lib.ui_screens")

local view = "filemanager"
local sd = DataStorage:getSettingsDir()
local ORDER_FILE = sd .. "/" .. view .. "_menu_order.lua"

os.remove(ORDER_FILE); os.remove(sd .. "/reorderingmenus_intent.lua")
os.remove(sd .. "/reorderingmenus_materialization.lua")
IntentStore.load(true); NativeWriter._resetCaches()
MenuOrderManager:dropSessionState(view)

local function launch()
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, view, false)
end
launch()
MenuOrderManager:saveOrder(view)

local Txn = IntentStore.openTransaction()
Txn:setParentOverride(view, "opds", { provider = nil, parent = "setting", anchor = false })

local order_now = MenuOrderManager:loadOrder(view)
local lst = order_now.help or {}
for i = 1, #lst - 1 do
    if lst[i] ~= "----------------------------" and lst[i + 1] ~= "----------------------------" then
        lst[i], lst[i + 1] = lst[i + 1], lst[i]
        break
    end
end
local dump = require("dump")
local fh = io.open(ORDER_FILE, "w")
fh:write("return " .. dump(order_now, nil, true)); fh:close()

NativeWriter._resetCaches(); MenuOrderManager:dropSessionState(view)
IntentStore.load(true); launch()   -- imports the external help swap

print("STAGED position_override:")
for id, rec in pairs(Txn:view(view).position_override or {}) do
    print("  staged po: " .. tostring(id) .. " after=" .. tostring(rec.after))
end
print("CANONICAL position_override:")
for id, rec in pairs(IntentStore.view(view).position_override or {}) do
    print("  canon po: " .. tostring(id) .. " after=" .. tostring(rec.after))
end

Txn.staged[view] = Txn:mergeSection(view)
Txn.base_generation = IntentStore.generation()
Txn.store_epoch = IntentStore.storeEpoch()
local ok = Txn:commit()
print("commit=" .. tostring(ok))

local sec = IntentStore.view(view)
print("POST-COMMIT position_override:")
for id, rec in pairs(sec.position_override or {}) do
    print("  final po: " .. tostring(id) .. " after=" .. tostring(rec.after))
end

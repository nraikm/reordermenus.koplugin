--[[--
probe_t7c.lua — T7's exact scenario, but inspecting the import mode.
The test writes a DENSE full order (loadOrder output) with one swapped pair.
With the sidecar wiped by dropSessionState... wait: dropSessionState does NOT
wipe the sidecar FILE. So the record survives; classify should be "external".
Check what actually happens.
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

-- T7 writes a DENSE file: loadOrder gives the FULL projection incl. all keys.
local order_now = MenuOrderManager:loadOrder(view)
print("dense keys written:")
for k in pairs(order_now) do print("  key: " .. tostring(k)) end
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
IntentStore.load(true); launch()   -- imports

print("CANONICAL position_override after dense import:")
for id, rec in pairs(IntentStore.view(view).position_override or {}) do
    print("  po: " .. tostring(id) .. " after=" .. tostring(rec.after))
end
print("CANONICAL order_override keys after dense import:")
for id in pairs(IntentStore.view(view).order_override or {}) do
    print("  oo: " .. tostring(id))
end

--[[--
probe_reset2.lua — trace resetOrder: what does the funnel commit?
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

local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local IntentStore = require("reorderingmenus_intent_store")
local NativeWriter = require("reorderingmenus_native_writer")
local UIScreens = require("reorderingmenus_ui_screens")

local view = "reader"
local sd = DataStorage:getSettingsDir()
os.remove(sd .. "/" .. view .. "_menu_order.lua")
os.remove(sd .. "/reorderingmenus_intent.lua")
os.remove(sd .. "/reorderingmenus_materialization.lua")
IntentStore.load(true); NativeWriter._resetCaches()
MenuOrderManager:dropSessionState(view)

local function launch()
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, view, false)
end
launch()
MenuOrderManager:setItemHidden(view, "calibre", true, "tools")
MenuOrderManager:saveOrder(view)

print("gen before reset=" .. IntentStore.generation())
print("epoch before reset=" .. IntentStore.storeEpoch())
MenuOrderManager:resetOrder(view)
print("gen after reset=" .. IntentStore.generation())
print("epoch after reset=" .. IntentStore.storeEpoch())

-- inspect canonical directly (fresh txn stages from canonical)
local t = IntentStore.openTransaction()
for coll, v in pairs(t:view(view)) do
    if type(v) == "table" and next(v) ~= nil then print("CANON non-empty: " .. coll) end
end
print("canonical customized=" ..
    tostring(next(IntentStore.view(view).hidden) ~= nil))
print("file exists=" .. tostring(IntentStore.hasPersistedState()))

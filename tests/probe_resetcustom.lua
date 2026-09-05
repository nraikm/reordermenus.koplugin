--[[--
probe_resetcustom.lua — after resetOrder, why is isCustomized still true?
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
print("after save customized=" .. tostring(MenuOrderManager:isCustomized(view)))

MenuOrderManager:resetOrder(view)

print("after reset customized=" ..
    tostring(MenuOrderManager:isCustomized(view)))
local txn = IntentStore.openTransaction()
local sec = txn:view(view)
for coll, v in pairs(sec) do
    if type(v) == "table" and next(v) ~= nil then
        print("  STAGED non-empty: " .. tostring(coll))
        for k in pairs(v) do print("    key: " .. tostring(k)) end
    end
end
print("canonical file exists=" ..
    tostring(IntentStore.hasPersistedState()))
local f = io.open(sd .. "/reorderingmenus_intent.lua", "r")
if f then
    local body = f:read("*a"); f:close()
    print("intent bytes len=" .. #body)
    print(body:sub(1, 600))
end

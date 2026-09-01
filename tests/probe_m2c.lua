--[[--
probe_m2c.lua — the M2 sequence with a PRISTINE baseline save. The pristine
save commits nothing (no records), so recordNeedsMaterialization should
still establish the checkpoint... does it?
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

local Manager = require("menuorder_manager")
local IntentStore = require("intent_store")
local NativeWriter = require("native_writer")
local UIScreens = require("ui_screens")

local view = "filemanager"
local sd = DataStorage:getSettingsDir()

os.remove(sd .. "/" .. view .. "_menu_order.lua")
os.remove(sd .. "/reorderingmenus_intent.lua")
os.remove(sd .. "/reorderingmenus_materialization.lua")
IntentStore.load(true); NativeWriter._resetCaches()
Manager:dropSessionState(view); Manager:dropSessionState("reader")

local function launch()
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, view, false)
end
launch()
print("needsMaterialization BEFORE save=" ..
    tostring(NativeWriter.recordNeedsMaterialization(view)))
print("record BEFORE save=" ..
    tostring(NativeWriter.getRecord(view) ~= nil))
Manager:saveOrder(view)
print("record AFTER save=" ..
    tostring(NativeWriter.getRecord(view) ~= nil))
print("needsMaterialization AFTER save=" ..
    tostring(NativeWriter.recordNeedsMaterialization(view)))

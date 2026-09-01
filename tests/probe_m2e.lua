--[[--
probe_m2e.lua — funnel says fm changed and saved, but record still missing?
Trace materializeView: does writeView actually get called for filemanager?
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

-- Patch writeView to log
local origWrite = NativeWriter.writeView
NativeWriter.writeView = function(view, reg, intent, graph)
    print("WRITEVIEW called for " .. tostring(view))
    local ok, native, err = origWrite(view, reg, intent, graph)
    print(string.format("  -> ok=%s native_keys=%d err=%s",
        tostring(ok), native and (function() local n=0 for _ in pairs(native) do n=n+1 end return n end)() or -1,
        tostring(err)))
    return ok, native, err
end

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
Manager:saveOrder(view)
print("record after=" .. tostring(NativeWriter.getRecord(view) ~= nil))

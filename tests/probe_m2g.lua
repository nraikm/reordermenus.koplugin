--[[--
probe_m2g.lua — pristine save: what does the funnel's changed_views say,
and does recordNeedsMaterialization fire for BOTH views?
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

local Manager = require("lib.menuorder_manager")
local IntentStore = require("lib.intent_store")
local NativeWriter = require("lib.native_writer")
local UIScreens = require("lib.ui_screens")
local CommitPipeline = require("lib.commit_pipeline")

-- wrap materializeView indirectly by watching clearRecord + writeView
local origClear = NativeWriter.clearRecord
NativeWriter.clearRecord = function(view)
    print("  CLEARRECORD " .. tostring(view))
    return origClear(view)
end
local origWriteView = NativeWriter.writeView
NativeWriter.writeView = function(view, reg, intent, graph)
    print("  WRITEVIEW " .. tostring(view))
    return origWriteView(view, reg, intent, graph)
end

-- CommitPipeline holds its own upvalue reference; patch the module field
-- used at line 96 instead (module table lookup happens per call).
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
print("--- saveOrder:")
Manager:saveOrder(view)
print("record fm after=" ..
    tostring(NativeWriter.getRecord("filemanager") ~= nil))
print("record rd after=" ..
    tostring(NativeWriter.getRecord("reader") ~= nil))

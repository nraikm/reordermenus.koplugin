--[[--
probe_m2d.lua — does the pristine saveOrder actually materialize the view?
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

-- Patch CommitPipeline to log materializeView calls
local CommitPipeline = require("lib.commit_pipeline")
local origCommit = CommitPipeline.commitAndApply
CommitPipeline.commitAndApply = function(txn, options)
    local outcome = origCommit(txn, options)
    print(string.format("FUNNEL: committed=%s status=%s changed={fm=%s,rd=%s} failed_fm=%s",
        tostring(outcome.committed), tostring(outcome.status),
        tostring(outcome.changed_views.filemanager),
        tostring(outcome.changed_views.reader),
        tostring(outcome.failed_views.filemanager)))
    return outcome
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
print("needsMat before=" ..
    tostring(NativeWriter.recordNeedsMaterialization(view)))
Manager:saveOrder(view)
print("needsMat after=" ..
    tostring(NativeWriter.recordNeedsMaterialization(view)))

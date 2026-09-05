--[[--
probe_m2f.lua — trace the funnel path for a pristine save: which branch?
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
local Materializer = require("lib.materializer")
local Validator = require("lib.validator")
local KoreaderAdapter = require("lib.koreader_adapter")
local MenuSchema = require("lib.menu_schema")

-- replicate materializeView with logging
local function materializeViewTraced(view, reg)
    local section = IntentStore.view(view)
    local graph = Materializer.resolve(reg, section)
    local _, repaired = Validator.validate(graph, reg, section)

    local has_records = false
    for _, collection_name in ipairs(MenuSchema.VIEW_COLLECTIONS) do
        local c = section[collection_name]
        if type(c) == "table" and next(c) ~= nil then
            has_records = true
            break
        end
    end
    print(string.format("  materializeView(%s): has_records=%s tab_order=%s",
        tostring(view), tostring(has_records), tostring(section.tab_order)))
    if not has_records and section.tab_order == nil then
        print("  -> EMPTY-BRANCH: remove + clearRecord (no writeView)")
        return true, nil
    end
    print("  -> writeView branch")
    return NativeWriter.writeView(view, reg, section, repaired)
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
local s = Manager.orders and nil or nil
-- get session registry like the funnel does
local sessions_ok, sess = pcall(function()
    -- reach into manager via stagedView to force session
    MenuOrderManager_staged = nil
    return nil
end)
print("needsMat before=" ..
    tostring(NativeWriter.recordNeedsMaterialization(view)))
-- call saveOrder; we cannot intercept materializeView directly, but we can
-- at least verify what WOULD happen given canonical is empty:
materializeViewTraced(view, nil)

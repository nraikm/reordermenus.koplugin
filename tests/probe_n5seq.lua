-- Extract: run JUST the N5 block by executing the real suite with a filter
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

local Manager = require("lib.menuorder_manager")
local IntentStore = require("lib.intent_store")
local NativeWriter = require("lib.native_writer")
local UIScreens = require("lib.ui_screens")
local KoreaderAdapter = require("lib.koreader_adapter")

local sd = DataStorage:getSettingsDir()
local VIEW, OTHER = "filemanager", "reader"
local function wipe_all()
    for _, f in ipairs({ VIEW.."_menu_order.lua", OTHER.."_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        os.remove(sd .. "/" .. f)
    end
    IntentStore.load(true); NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}; Manager.recent_moves.reader = {}
    Manager:dropSessionState(VIEW); Manager:dropSessionState(OTHER)
end
local function launch(v)
    UIScreens:reconcileRegisteredItems({ ui = { menu = { registered_widgets = {} } } }, v, false)
end
local function state(tag)
    local m = IntentStore.meta()
    print(("[%s] gen=%d fm=%s rd=%s"):format(tag, m.generation or -1,
        tostring(m.view_generations and m.view_generations.filemanager),
        tostring(m.view_generations and m.view_generations.reader)))
    local rec_f = NativeWriter.getRecord(VIEW)
    local rec_r = NativeWriter.getRecord(OTHER)
    print(("   recFM=%s@%s recRD=%s@%s"):format(
        rec_f and rec_f.fingerprint:sub(1,12) or "-",
        tostring(rec_f and rec_f.intent_gen),
        rec_r and rec_r.fingerprint:sub(1,12) or "-",
        tostring(rec_r and rec_r.intent_gen)))
    local sec = IntentStore.view(VIEW)
    local hs = {}
    for k in pairs(sec.hidden) do hs[#hs+1]=k end
    print("   FM hidden={" .. table.concat(hs,",") .. "} po.opds=" ..
        (sec.parent_override.opds and sec.parent_override.opds.parent or "-"))
end

print("==== eras ====")
wipe_all(); launch(VIEW)
launch(OTHER)
Manager:setItemHidden(OTHER, "screensaver", true, "screen")
Manager:saveOrder(OTHER)
state("mon saved")
Manager:setItemHidden(VIEW, "screensaver", true, "screen")
Manager:saveOrder(VIEW)
state("tue saved")
Manager:setItemHidden(VIEW, "calibre", true, "more_tools")
Manager:saveOrder(VIEW)
state("wed saved")
Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
Manager:saveOrder(VIEW)
state("fri saved")

print("==== assemble four eras ====")
wipe_all()
Manager.recent_moves.filemanager = {}; Manager.recent_moves.reader = {}
IntentStore.load(true); NativeWriter._resetCaches()
launch(VIEW)
state("fm synced")
launch(OTHER)
state("rd synced")
os.exit(0)

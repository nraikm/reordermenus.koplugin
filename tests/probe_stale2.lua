-- probe_stale2.lua: minimal repro - two views import at one startup
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

local Manager = require("menuorder_manager")
local IntentStore = require("intent_store")
local NativeWriter = require("native_writer")
local UIScreens = require("ui_screens")
local KoreaderAdapter = require("koreader_adapter")

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

wipe_all(); launch(VIEW); launch(OTHER)
Manager:setItemHidden(OTHER, "screensaver", true, "screen")
Manager:saveOrder(OTHER)
print("gen after reader save:", IntentStore.meta().generation)

-- BOTH files externally replaced while the plugin is off.
KoreaderAdapter.writeNativeOrder(OTHER,
    { ["KOMenu:disabled"] = { "calibre" } })
KoreaderAdapter.writeNativeOrder(VIEW,
    { search = { "search_settings", "opds", "dictionary_lookup",
        "dictionary_lookup_history", "vocabbuilder", "wikipedia_lookup",
        "wikipedia_history", "file_search", "file_search_results",
        "find_book_in_calibre_catalog" } })

-- One fresh process: both views sync for the first time (real KOReader
-- reconciles FM first, then Reader).
Manager.recent_moves.filemanager = {}; Manager.recent_moves.reader = {}
IntentStore.load(true); NativeWriter._resetCaches()
launch(VIEW)   -- FM import happens here (committed inside sessionFor)
launch(OTHER)  -- reader import stages on a now-STALE txn?
print("FM opds parent (want search_settings):", Manager:getParentMenu(VIEW, "opds"))
print("reader calibre hidden (want true):", Manager:isItemHidden(OTHER, "calibre"))
os.exit(0)

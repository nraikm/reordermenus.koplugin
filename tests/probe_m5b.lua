-- probe_m5b.lua: why did raw[1] differ inside the suite?
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
local VIEW = "filemanager"
local function wipe_all()
    for _, f in ipairs({ VIEW .. "_menu_order.lua", "reader_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        os.remove(sd .. "/" .. f)
    end
    IntentStore.load(true); NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}; Manager.recent_moves.reader = {}
    Manager:dropSessionState(VIEW); Manager:dropSessionState("reader")
end
local function launch()
    UIScreens:reconcileRegisteredItems({ ui = { menu = { registered_widgets = {} } } }, VIEW, false)
end
local function restart()
    Manager:dropSessionState(VIEW); IntentStore.load(true); NativeWriter._resetCaches()
    launch()
end

wipe_all(); launch(); Manager:saveOrder(VIEW)
KoreaderAdapter.writeNativeOrder(VIEW, {
    search = { "wikipedia_lookup", "opds", "search_settings",
        "dictionary_lookup", "dictionary_lookup_history", "vocabbuilder",
        "wikipedia_history", "file_search", "file_search_results",
        "find_book_in_calibre_catalog" },
    my_tool_panel = { "opds", "search_settings" },
})
restart()

local function show(tag)
    local raw = IntentStore.view(VIEW).raw_override.my_tool_panel
    print(tag, "raw:", raw and table.concat(raw, ",") or "nil")
end

show("after restart1 ")
restart()
show("after restart2 ")

-- now the exact suite tail: reloadFromDisk + saveOrder + restart
Manager:reloadFromDisk(VIEW)
Manager:saveOrder(VIEW)
show("after re-sync   ")
restart()
show("after restart3  ")

-- what does a save emit for the raw level?
local order = dofile(sd .. "/" .. VIEW .. "_menu_order.lua")
if order then
    print("emitted my_tool_panel:", order.my_tool_panel and table.concat(order.my_tool_panel, ",") or "(absent)")
else print("no native file on disk") end
os.exit(0)

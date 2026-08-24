-- probe_m5f.lua: print the raw_override block with line numbers
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

local Manager = require("reorderingmenus_menuorder_manager")
local IntentStore = require("reorderingmenus_intent_store")
local NativeWriter = require("reorderingmenus_native_writer")
local UIScreens = require("reorderingmenus_ui_screens")
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")

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

wipe_all(); launch(); Manager:saveOrder(VIEW)
KoreaderAdapter.writeNativeOrder(VIEW, {
    search = { "wikipedia_lookup", "opds", "search_settings",
        "dictionary_lookup", "dictionary_lookup_history", "vocabbuilder",
        "wikipedia_history", "file_search", "file_search_results",
        "find_book_in_calibre_catalog" },
    my_tool_panel = { "opds", "search_settings" },
})
Manager:dropSessionState(VIEW); IntentStore.load(true); NativeWriter._resetCaches()
launch()

local f = io.open(sd .. "/reorderingmenus_intent.lua", "r")
local body = f and f:read("*a"); if f then f:close() end
local n = 0
for line in body:gmatch("[^\n]+") do
    n = n + 1
    if line:find("raw_override") then
        print(">>> raw_override opens at line", n)
    end
end
print("---- lines around first raw_override ----")
local lines, i = {}, 0
for line in body:gmatch("[^\n]+") do
    i = i + 1; lines[i] = line
end
for idx = 1, #lines do
    if lines[idx]:find("raw_override") then
        for j = idx, math.min(idx + 8, #lines) do
            print(j .. "|" .. lines[j])
            if j > idx and lines[j]:match("%}") then break end
        end
        print("....")
    end
end
os.exit(0)

-- probe_m5c.lua: where does raw_override.my_tool_panel get emptied?
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

local function disk_raw(tag)
    local f = io.open(sd .. "/reorderingmenus_intent.lua", "r")
    local body = f and f:read("*a"); if f then f:close() end
    local chunk = body and body:gsub("^%-%-[^\n]*\n", "")
    local ok, data = pcall(load(chunk or ""))
    if ok and type(data) == "table" and data.views and data.views[VIEW] then
        local raw = data.views[VIEW].raw_override
        if raw and raw.my_tool_panel then
            print(tag, "disk raw:", #raw.my_tool_panel,
                table.concat(raw.my_tool_panel, ","))
        else
            print(tag, "disk raw: ABSENT", raw and "table" or type(raw))
        end
    else
        print(tag, "no parsable intent file")
    end
end

wipe_all(); launch(); Manager:saveOrder(VIEW)
KoreaderAdapter.writeNativeOrder(VIEW, {
    search = { "wikipedia_lookup", "opds", "search_settings",
        "dictionary_lookup", "dictionary_lookup_history", "vocabbuilder",
        "wikipedia_history", "file_search", "file_search_results",
        "find_book_in_calibre_catalog" },
    my_tool_panel = { "opds", "search_settings" },
})
disk_raw("before restart:")
Manager:dropSessionState(VIEW); IntentStore.load(true); NativeWriter._resetCaches()
launch()
disk_raw("after restart: ")
local mem = IntentStore.view(VIEW).raw_override.my_tool_panel
print("memory raw:", mem and #mem or "nil", mem and table.concat(mem, ",") or "")
os.exit(0)

--[[--
probe_m2iso.lua — M2 under hermetic KO_HOME: what does the double
write_native + restart import as?
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
require("main")

local Manager = require("reorderingmenus_menuorder_manager")
local IntentStore = require("reorderingmenus_intent_store")
local NativeWriter = require("reorderingmenus_native_writer")
local UIScreens = require("reorderingmenus_ui_screens")
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")

local sd = DataStorage:getSettingsDir()
print("settings=" .. sd)
local VIEW = "filemanager"

local function wipe_all()
    for _, f in ipairs({ VIEW .. "_menu_order.lua", "reader_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        os.remove(sd .. "/" .. f)
    end
    IntentStore.load(true); NativeWriter._resetCaches()
    Manager:dropSessionState(VIEW); Manager:dropSessionState("reader")
end
local function launch()
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)
end
local function write_native(tbl) KoreaderAdapter.writeNativeOrder(VIEW, tbl) end
local function restart()
    Manager:dropSessionState(VIEW); IntentStore.load(true)
    NativeWriter._resetCaches(); launch()
end

wipe_all(); launch(); Manager:saveOrder(VIEW)

-- Was anything written by the baseline save? (P0 funnel: unchanged save may
-- write nothing -> no sidecar -> next edit is LEGACY not EXTERNAL.)
local rec = NativeWriter.getRecord(VIEW)
print("after pristine save: record=" .. tostring(rec ~= nil)
    .. " fileExists=" .. tostring(KoreaderAdapter.nativeFileExists(VIEW)))

write_native({
    search = { "search_settings", "opds", "dictionary_lookup",
        "dictionary_lookup_history", "vocabbuilder", "wikipedia_lookup",
        "wikipedia_history", "file_search", "file_search_results",
        "find_book_in_calibre_catalog" },
})
write_native({
    search = { "search_settings", "dictionary_lookup",
        "dictionary_lookup_history", "vocabbuilder", "opds",
        "wikipedia_lookup", "wikipedia_history", "file_search",
        "file_search_results", "find_book_in_calibre_catalog" },
})
restart()

local sec = IntentStore.view(VIEW)
print("anchor after=vocabbuilder? " ..
    tostring(sec.position_override.opds ~= nil
        and sec.position_override.opds.after == "vocabbuilder"))
print("order_override.search frozen? " ..
    tostring(sec.order_override.search ~= nil))

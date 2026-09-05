--[[--
probe_m2b.lua — M2 in isolation: pristine baseline save, then two
unobserved writes, then restart. Does the import classify EXTERNAL?
The M-suite's restart() does NOT drop the OTHER view; and its baseline
saveOrder happens BEFORE any customization (pristine world).
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

local Manager = require("lib.menuorder_manager")
local IntentStore = require("lib.intent_store")
local NativeWriter = require("lib.native_writer")
local UIScreens = require("lib.ui_screens")
local KoreaderAdapter = require("lib.koreader_adapter")

local sd = DataStorage:getSettingsDir()
local VIEW = "filemanager"

local function wipe_all()
    for _, f in ipairs({ VIEW .. "_menu_order.lua", "reader_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        os.remove(sd .. "/" .. f)
    end
    IntentStore.load(true); NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}
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

local rec = NativeWriter.getRecord(VIEW)
print("pristine save -> record exists=" .. tostring(rec ~= nil)
    .. ", fileExists=" .. tostring(KoreaderAdapter.nativeFileExists(VIEW)))

-- The suite then writes native TWICE. But between write B and C there is no
-- observation; only C is seen at restart.
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

print("pre-restart record exists=" ..
    tostring(NativeWriter.getRecord(VIEW) ~= nil))
restart()

local sec = IntentStore.view(VIEW)
print("anchor? " .. tostring(sec.position_override.opds ~= nil))
if sec.position_override.opds then
    print("  after=" .. tostring(sec.position_override.opds.after))
end
print("frozen oo.search? " .. tostring(sec.order_override.search ~= nil))

-- Now: what if a REAL prior emission exists? (hide + save first)
wipe_all(); launch()
Manager:setItemHidden(VIEW, "screensaver", true, "screen")
Manager:saveOrder(VIEW)
rec = NativeWriter.getRecord(VIEW)
print("WITH prior emission: record=" .. tostring(rec ~= nil)
    .. " fileExists=" .. tostring(KoreaderAdapter.nativeFileExists(VIEW)))

write_native({
    search = { "search_settings", "opds", "dictionary_lookup",
        "dictionary_lookup_history", "vocabbuilder", "wikipedia_lookup",
        "wikipedia_history", "file_search", "file_search_results",
        "find_book_in_calibre_catalog" },
})
restart()

sec = IntentStore.view(VIEW)
print("anchor(opds after search_settings)? " ..
    tostring(sec.position_override.opds ~= nil
        and sec.position_override.opds.after == "search_settings"))
print("frozen oo.search? " .. tostring(sec.order_override.search ~= nil))

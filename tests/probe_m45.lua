-- probe_m45.lua: reproduce M4 (stale hidden) and M5 (vanishing raw_override)
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
local function restart()
    Manager:dropSessionState(VIEW); IntentStore.load(true); NativeWriter._resetCaches()
    launch()
end

print("=== M5 reproduction ===")
wipe_all(); launch(); Manager:saveOrder(VIEW)
KoreaderAdapter.writeNativeOrder(VIEW, {
    search = { "wikipedia_lookup", "opds", "search_settings",
        "dictionary_lookup", "dictionary_lookup_history", "vocabbuilder",
        "wikipedia_history", "file_search", "file_search_results",
        "find_book_in_calibre_catalog" },
    my_tool_panel = { "opds", "search_settings" },
})
restart()
print("after restart1 raw:", IntentStore.view(VIEW).raw_override.my_tool_panel ~= nil)
print("sidecar structure keys:")
local rec = NativeWriter.getRecord(VIEW)
if rec and rec.structure then
    for k in pairs(rec.structure) do print("  ", k) end
else print("   (nil structure)") end
restart()
print("after restart2 raw:", IntentStore.view(VIEW).raw_override.my_tool_panel ~= nil)
local sec = IntentStore.view(VIEW)
print("intent dump: oo=", next(sec.order_override), "raw=", next(sec.raw_override),
    "cm=", next(sec.custom_menus))
for k,v in pairs(sec.order_override or {}) do print("oo key:", k) end
for k,v in pairs(sec.custom_menus or {}) do print("cm key:", k, type(v)) end

print("=== M4 reproduction ===")
wipe_all(); launch()
Manager:setItemHidden(VIEW, "screensaver", true, "screen")  -- real emission
Manager:saveOrder(VIEW)
KoreaderAdapter.writeNativeOrder(VIEW, { ["KOMenu:disabled"] = { "calibre" } })
restart()
print("hidden after hide-import:", Manager:isItemHidden(VIEW, "calibre"))
rec = NativeWriter.getRecord(VIEW)
if rec and rec.structure then
    for k, v in pairs(rec.structure) do print("  struct", k, v and #v or type(v)) end
end
KoreaderAdapter.writeNativeOrder(VIEW, { ["KOMenu:disabled"] = {} })
restart()
print("hidden after unhide-import:", Manager:isItemHidden(VIEW, "calibre"))
sec = IntentStore.view(VIEW)
for k in pairs(sec.hidden or {}) do print("hidden rec:", k) end
os.exit(0)

-- appendix: raw contents detail

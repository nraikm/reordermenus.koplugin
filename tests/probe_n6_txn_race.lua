--[[--
probe_n6_txn_race.lua — diagnose N6: consistent whole-directory rollback.

Hypothesis under test: after a rollback restores ALL files (including
reorderingmenus_intent.lua), the still-open active transaction in the NEW
process was opened BEFORE syncView's import commit; if any verb staged
edits on it, its base_generation predates the restore and commit() refuses,
leaving the restored canonical intent unabsorbed while the projection shows
era-2 state (the "accidental merge" Area N forbids).
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
local VIEW = "filemanager"
local OTHER = "reader"

local function wipe_all()
    for _, f in ipairs({ VIEW .. "_menu_order.lua", OTHER .. "_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        os.remove(sd .. "/" .. f)
    end
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}
    Manager.recent_moves.reader = {}
    Manager:dropSessionState(VIEW)
    Manager:dropSessionState(OTHER)
end

local function launch()
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)
end

wipe_all(); launch()

-- era 1: the future snapshot
Manager:setItemHidden(VIEW, "screensaver", true, "screen")
Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
Manager:saveOrder(VIEW)
local snap = {}
for _, name in ipairs({ VIEW .. "_menu_order.lua", OTHER .. "_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
    local f = io.open(sd .. "/" .. name, "r")
    snap[name] = f and f:read("*a"); if f then f:close() end
end

-- era 2: life goes on
launch()
Manager:setItemHidden(VIEW, "calibre", true, "more_tools")
Manager:moveItemToMenu(VIEW, "opds", "tools", "search")
Manager:saveOrder(VIEW)
print("PROBE era2: parent(opds)=" .. tostring(Manager:getParentMenu(VIEW, "opds"))
    .. " hidden(calibre)=" .. tostring(Manager:isItemHidden(VIEW, "calibre")))

-- cloud client reinstalls the WHOLE snapshot directory
for name, body in pairs(snap) do
    local h = io.open(sd .. "/" .. name, "w") h:write(body) h:close()
end

-- fresh session WITHOUT any intervening verb: pure restart semantics
Manager:dropSessionState(VIEW); Manager:dropSessionState(OTHER)
IntentStore.load(true); NativeWriter._resetCaches()
launch()

print("PROBE after restart: parent(opds)=" .. tostring(Manager:getParentMenu(VIEW, "opds"))
    .. " hidden(screensaver)=" .. tostring(Manager:isItemHidden(VIEW, "screensaver"))
    .. " hidden(calibre)=" .. tostring(Manager:isItemHidden(VIEW, "calibre")))
print("PROBE intent gen=" .. tostring(IntentStore.meta().generation)
    .. " fm_gen=" .. tostring(IntentStore.meta().view_generations
        and IntentStore.meta().view_generations.filemanager))
local rec = NativeWriter.getRecord(VIEW)
print("PROBE sidecar intent_gen=" .. tostring(rec and rec.intent_gen))

-- now exercise exactly what the failing test does next: another restart
Manager:dropSessionState(VIEW); IntentStore.load(true); NativeWriter._resetCaches()
launch()
print("PROBE after 2nd restart: parent(opds)=" .. tostring(Manager:getParentMenu(VIEW, "opds"))
    .. " hidden(calibre)=" .. tostring(Manager:isItemHidden(VIEW, "calibre")))

wipe_all()
print("PROBE done")

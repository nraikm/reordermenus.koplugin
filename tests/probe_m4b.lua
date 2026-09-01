-- probe_m4b.lua: call syncView directly to see the classification decision
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
local function dump_state(tag)
    local sec = IntentStore.view(VIEW)
    local h = {}
    for k in pairs(sec.hidden) do h[#h+1] = k end
    local f = io.open(sd .. "/" .. VIEW .. "_menu_order.lua", "r")
    local body = f and f:read("*a") or "(no file)"; if f then f:close() end
    local brief = body:gsub("%s+", " "):sub(1, 150)
    print(tag, "| hidden={" .. table.concat(h, ",") .. "}",
        "| rec_fp=", NativeWriter.getRecord(VIEW) and NativeWriter.getRecord(VIEW).fingerprint or nil,
        "| disk=" .. brief)
end

print("--- phase 1: baseline emission (screensaver hidden) ---")
wipe_all(); launch()
Manager:setItemHidden(VIEW, "screensaver", true, "screen")
Manager:saveOrder(VIEW)
dump_state("P1")

print("--- phase 2: external edit replaces disabled with calibre ---")
KoreaderAdapter.writeNativeOrder(VIEW, { ["KOMenu:disabled"] = { "calibre" } })
Manager:dropSessionState(VIEW); IntentStore.load(true); NativeWriter._resetCaches()
launch()
dump_state("P2")

print("--- phase 3: external edit empties disabled ---")
KoreaderAdapter.writeNativeOrder(VIEW, { ["KOMenu:disabled"] = {} })
dump_state("P3 pre-sync")
Manager:dropSessionState(VIEW); IntentStore.load(true); NativeWriter._resetCaches()
launch()
dump_state("P3 post-sync")
os.exit(0)

-- probe_n5.lua: why does the lagging-bound reader file keep its hide?
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
local function dump(tag)
    local sec = IntentStore.view(OTHER)
    local h = {}
    for k in pairs(sec.hidden) do h[#h+1] = k end
    local rec = NativeWriter.getRecord(OTHER)
    print(tag, "reader hidden={", table.concat(h, ","), "} rec=",
        rec and rec.fingerprint:sub(1,40) or nil, "gen=", rec and rec.intent_gen or nil,
        "canonGen=", IntentStore.generation(OTHER))
end

wipe_all(); launch(OTHER); launch(VIEW)
Manager:setItemHidden(OTHER, "screensaver", true, "screen")
Manager:saveOrder(OTHER)   -- reader emission (gen for reader advances?)
dump("after reader save:")
Manager:setItemHidden(VIEW, "screensaver", true, "screen")
Manager:saveOrder(VIEW)
dump("after FM save:  ")
print("--- now restore OLD reader native bytes over the sidecar's record ---")
os.remove(sd .. "/reorderingmenus_intent.lua")  -- simulate older intent? no - just restart
Manager:dropSessionState(VIEW); Manager:dropSessionState(OTHER)
IntentStore.load(true); NativeWriter._resetCaches()
launch(OTHER); launch(VIEW)
dump("after restart:  ")
os.exit(0)

-- probe_n6b.lua: inspect intent records after consistent rollback
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

wipe_all(); launch(VIEW)
Manager:setItemHidden(VIEW, "screensaver", true, "screen")
Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
Manager:saveOrder(VIEW)
local snap = {}
for _, name in ipairs({ VIEW.."_menu_order.lua", OTHER.."_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
    local f = io.open(sd .. "/" .. name, "r")
    snap[name] = f and f:read("*a"); if f then f:close() end
end
-- snapshot intent contents
do
    local sec = IntentStore.view(VIEW)
    print("SNAP hidden:", next(sec.hidden))
    print("SNAP parent_override.opds:", sec.parent_override.opds and sec.parent_override.opds.parent or nil)
    print("SNAP anchors:", next(IntentStore.meta().ui_state.hidden_anchors[VIEW] or {}))
end

Manager:setItemHidden(VIEW, "calibre", true, "more_tools")
Manager:moveItemToMenu(VIEW, "opds", "tools", "search")
Manager:saveOrder(VIEW)

for name, body in pairs(snap) do
    local h = io.open(sd .. "/" .. name, "w") h:write(body) h:close()
end
Manager:dropSessionState(VIEW); IntentStore.load(true); NativeWriter._resetCaches()
launch(VIEW)
local sec = IntentStore.view(VIEW)
print("POST hidden:")
for k in pairs(sec.hidden) do print("   ", k) end
print("POST anchors:")
for k, v in pairs(IntentStore.meta().ui_state.hidden_anchors[VIEW] or {}) do print("   ", k, v) end
print("POST po.opds:", Manager:getParentMenu(VIEW, "opds"))
print("POST calibre hiddenApplies:", Manager:isItemHidden(VIEW, "calibre"),
      "record:", sec.hidden.calibre ~= nil)
os.exit(0)

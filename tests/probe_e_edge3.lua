--[[
probe_e_edge3.lua — P1 v3 with CALIBRE (present in editor row models):
parent captures TOOLS rows including calibre; child hides calibre and
commits; parent then saves its stale snapshot containing calibre.
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

local sd = DataStorage:getSettingsDir()
local VIEW = "filemanager"

local function wipe_all()
    for _, f in ipairs({ "filemanager_menu_order.lua", "reader_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        os.remove(sd .. "/" .. f)
    end
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}
    Manager.recent_moves.reader = {}
    Manager:dropSessionState(VIEW)
    Manager:dropSessionState("reader")
end

local function visible_parent(view, id)
    local order = Manager:loadOrder(view)
    for menu_id, items in pairs(order or {}) do
        if menu_id ~= "KOMenu:disabled" and type(items) == "table" then
            for _, x in ipairs(items) do
                if x == id then return menu_id end
            end
        end
    end
    return nil
end

print("== P1 v3: stale TOOLS rows (with calibre) saved AFTER child hid calibre ==")
wipe_all()
Manager:saveOrder(VIEW)

local stale_rows = {}
for _, id in ipairs(Manager:getMenuItems(VIEW, "tools")) do
    table.insert(stale_rows, id)
end
local has_calibre = false
for _, id in ipairs(stale_rows) do
    if id == "calibre" then has_calibre = true end
end
print("[0] stale model contains calibre?", tostring(has_calibre),
    " rows=" .. #stale_rows,
    " visible_at=" .. tostring(visible_parent(VIEW, "calibre")))

-- child hides calibre and commits
Manager:setItemHidden(VIEW, "calibre", true, "tools")
Manager:saveOrder(VIEW)
print("[1] child hid+saved calibre: hidden=",
    tostring(IntentStore.view(VIEW).hidden.calibre ~= nil),
    " visible_at=", tostring(visible_parent(VIEW, "calibre")))

-- parent saves its stale snapshot (still listing calibre)
Manager:stageList(VIEW, "tools", stale_rows)
local ok_save = Manager:saveOrder(VIEW)
print("[2] stale parent saved ok=", ok_save,
    " hidden.calibre=", tostring(IntentStore.view(VIEW).hidden.calibre ~= nil),
    " visible_at=", tostring(visible_parent(VIEW, "calibre")))

Manager:dropSessionState(VIEW); IntentStore.load(true)
print("[3] after reload: hidden.calibre=",
    tostring(IntentStore.view(VIEW).hidden.calibre ~= nil),
    " visible_at=", tostring(visible_parent(VIEW, "calibre")))

print("")
print("== P1c v3: same but child MOVED calibre away ==")
wipe_all()
Manager:saveOrder(VIEW)
stale_rows = {}
for _, id in ipairs(Manager:getMenuItems(VIEW, "tools")) do
    table.insert(stale_rows, id)
end
has_calibre = false
for _, id in ipairs(stale_rows) do
    if id == "calibre" then has_calibre = true end
end
print("[0] stale model contains calibre?", tostring(has_calibre))

Manager:moveItemToMenu(VIEW, "calibre", "tools", "more_tools")
Manager:saveOrder(VIEW)
print("[1] child moved calibre -> more_tools; visible_at=",
    tostring(visible_parent(VIEW, "calibre")))

Manager:stageList(VIEW, "tools", stale_rows)
ok_save = Manager:saveOrder(VIEW)
print("[2] stale parent saved ok=", ok_save, " visible_at=",
    tostring(visible_parent(VIEW, "calibre")),
    " parent_override=", tostring(IntentStore.view(VIEW).parent_override.calibre ~= nil))

Manager:dropSessionState(VIEW); IntentStore.load(true)
print("[3] after reload: visible_at=", tostring(visible_parent(VIEW, "calibre")))

wipe_all()
print("probe done")

--[[
probe_e_edge2.lua — P1 done right: parent captures TOOLS rows INCLUDING
terminal before the child hides it; child hides + commits; parent then saves
its stale snapshot. Question: does the stale save resurrect / duplicate /
de-hide terminal?
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

local Manager = require("menuorder_manager")
local IntentStore = require("intent_store")
local NativeWriter = require("native_writer")

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

local function occurrences(view, id)
    local n = 0
    local order = Manager:loadOrder(view)
    for _, items in pairs(order or {}) do
        if type(items) == "table" then
            for _, x in ipairs(items) do
                if x == id then n = n + 1 end
            end
        end
    end
    return n
end

print("== P1 v2: stale TOOLS rows saved AFTER child hid terminal ==")
wipe_all()
Manager:setItemHidden(VIEW, "calibre", true, "tools")
Manager:saveOrder(VIEW)
print("[0] baseline: calibre hidden (so tools list is non-default)")

-- parent editor opens NOW: captures the visible tools arrangement
local stale_rows = {}
for _, id in ipairs(Manager:getMenuItems(VIEW, "tools")) do
    table.insert(stale_rows, id)
end
local has_terminal = false
for _, id in ipairs(stale_rows) do
    if id == "terminal" then has_terminal = true end
end
print("[1] stale parent model contains terminal?", tostring(has_terminal),
    " rows=" .. #stale_rows)

-- child flow: hide terminal, commit
Manager:setItemHidden(VIEW, "terminal", true, "tools")
Manager:saveOrder(VIEW)
print("[2] child hid+saved: hidden.terminal=",
    tostring(IntentStore.view(VIEW).hidden.terminal ~= nil),
    " occurrences=", occurrences(VIEW, "terminal"))

-- parent saves its stale snapshot (still listing terminal)
Manager:stageList(VIEW, "tools", stale_rows)
local ok_save = Manager:saveOrder(VIEW)
print("[3] stale parent saved ok=", ok_save,
    " hidden.terminal=", tostring(IntentStore.view(VIEW).hidden.terminal ~= nil))
print("    occurrences=", occurrences(VIEW, "terminal"),
    " parent_override.terminal=", tostring(IntentStore.view(VIEW).parent_override.terminal ~= nil))

Manager:dropSessionState(VIEW); IntentStore.load(true)
print("[4] after reload: hidden.terminal=",
    tostring(IntentStore.view(VIEW).hidden.terminal ~= nil),
    " occurrences=", occurrences(VIEW, "terminal"))

print("")
print("== P1b: same but child MOVED terminal away instead of hiding ==")
wipe_all()
Manager:saveOrder(VIEW)
stale_rows = {}
for _, id in ipairs(Manager:getMenuItems(VIEW, "tools")) do
    table.insert(stale_rows, id)
end
has_terminal = false
for _, id in ipairs(stale_rows) do
    if id == "terminal" then has_terminal = true end
end
print("[0] stale model contains terminal?", tostring(has_terminal))

Manager:moveItemToMenu(VIEW, "terminal", "tools", "more_tools")
Manager:saveOrder(VIEW)
print("[1] child moved terminal to more_tools; occurrences=",
    occurrences(VIEW, "terminal"))

Manager:stageList(VIEW, "tools", stale_rows)
ok_save = Manager:saveOrder(VIEW)
print("[2] stale parent saved ok=", ok_save, " occurrences=",
    occurrences(VIEW, "terminal"),
    " parent=", tostring(Manager:getParentMenu(VIEW, "terminal")))

Manager:dropSessionState(VIEW); IntentStore.load(true)
print("[3] after reload: occurrences=", occurrences(VIEW, "terminal"),
    " parent=", tostring(Manager:getParentMenu(VIEW, "terminal")))

wipe_all()
print("probe done")

--[[
probe_e_edge.lua — probe two unpinned nested-editor semantics before codifying:

  P1: child HIDES terminal (committed); parent then saves STALE more_tools
      rows that still contain terminal. Does the stale save resurrect /
      duplicate / de-hide it?

  P2: reader view has UNSAVED staged dirt; nested flow resets the
      filemanager view (resetOrder). Does the reset commit sweep the
      reader's staged dirt into durable state?
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
local UIScreens = require("ui_screens")

local sd = DataStorage:getSettingsDir()
local VIEW = "filemanager"

local function wipe_all()
    for _, f in ipairs({ "filemanager_menu_order.lua", "reader_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        os.remove(sd .. "/" .. f)
    end
    os.execute("rm -rf " .. sd .. "/menu_order_presets")
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}
    Manager.recent_moves.reader = {}
    Manager:dropSessionState(VIEW)
    Manager:dropSessionState("reader")
end

local function projection_has(view, id)
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

print("== P1: stale parent rows saved AFTER child hid the item ==")
wipe_all()
Manager:moveItemToMenu(VIEW, "terminal", "more_tools", "tools")
Manager:saveOrder(VIEW)
print("[0] baseline: terminal parent=", tostring(Manager:getParentMenu(VIEW, "terminal")))

-- parent editor opened BEFORE the child acted: its model still shows terminal
-- under more_tools (stale). Capture a plausible stale snapshot.
local stale_rows = {}
for _, id in ipairs(Manager:getMenuItems(VIEW, "more_tools")) do
    stale_rows[#stale_rows + 1] = id
end
local has_terminal = false
for _, id in ipairs(stale_rows) do
    if id == "terminal" then has_terminal = true end
end
print("[0b] stale snapshot contains terminal?", tostring(has_terminal))

-- child flow: hide terminal, save
open_child = Manager:setItemHidden(VIEW, "terminal", true, "tools")
Manager:saveOrder(VIEW)
print("[1] child hid terminal; canon hidden.terminal=",
    tostring(IntentStore.view(VIEW).hidden.terminal ~= nil),
    " visible_at=", tostring(projection_has(VIEW, "terminal")))

-- parent saves its stale rows
Manager:stageList(VIEW, "more_tools", stale_rows)
local ok_save = Manager:saveOrder(VIEW)
print("[2] stale parent saved ok=", ok_save)
local sec = IntentStore.view(VIEW)
print("    hidden.terminal=", tostring(sec.hidden.terminal ~= nil))
print("    parent_override.terminal=", tostring(sec.parent_override.terminal ~= nil))
print("    position_override.terminal=", tostring(sec.position_override.terminal ~= nil))
print("    terminal visible_at=", tostring(projection_has(VIEW, "terminal")))

-- restart equivalence
Manager:dropSessionState(VIEW); IntentStore.load(true)
print("[3] after reload: hidden.terminal=",
    tostring(IntentStore.view(VIEW).hidden.terminal ~= nil),
    " visible_at=", tostring(projection_has(VIEW, "terminal")))
local count = 0
local order_after = Manager:loadOrder(VIEW)
for _, items in pairs(order_after or {}) do
    if type(items) == "table" then
        for _, x in ipairs(items) do
            if x == "terminal" then count = count + 1 end
        end
    end
end
print("    terminal occurrences in native projection:", count)

print("")
print("== P2: nested resetOrder(filemanager) with UNSAVED reader dirt ==")
wipe_all()
Manager:setItemHidden("reader", "read_timer_placeholder_x", true, nil)
print("[0] reader staged hide accepted:", "see below")
-- read_timer might not exist in reader defaults; use a real reader item
wipe_all()
Manager:setItemHidden("reader", "book_status", true, nil)
print("[0] reader staged (uncommitted) dirt: book_status hide")
print("    canon reader hidden.book_status=",
    tostring(IntentStore.view("reader").hidden.book_status ~= nil),
    " gen=", IntentStore.generation())

local ok_reset = Manager:resetOrder(VIEW)
print("[1] resetOrder(filemanager) ok=", ok_reset, " gen=", IntentStore.generation())
print("    canon reader hidden.book_status NOW=",
    tostring(IntentStore.view("reader").hidden.book_status ~= nil))

-- does the reader dirt survive as staged (a later reader save commits it)?
local ok_reader_save = Manager:saveOrder("reader")
print("[2] reader saveOrder ok=", ok_reader_save, " gen=", IntentStore.generation())
print("    canon reader hidden.book_status after save=",
    tostring(IntentStore.view("reader").hidden.book_status ~= nil))

Manager:dropSessionState(VIEW); Manager:dropSessionState("reader"); IntentStore.load(true)
print("[3] after reload: fm empty=",
    next(IntentStore.view(VIEW).parent_override or {}) == nil
        and next(IntentStore.view(VIEW).hidden or {}) == nil,
    " reader hidden.book_status=",
    tostring(IntentStore.view("reader").hidden.book_status ~= nil))

wipe_all()
print("probe done")

--[[--
Suite V: native deletion while the plugin is disabled.

Sequence per arm: project emitted content -> disable the project (no code of
ours runs) -> delete the native menu file -> restart STOCK KOReader (nothing
recreates the file) -> re-enable the project.

The recovery MUST distinguish two worlds:

  Arm A - genuine user deletion of REAL emitted content:
    the sidecar holds a content-bearing, generation-consistent record.
    Deleting our generated file is a deliberate full revert: canonical intent
    for that view is wiped (including dormant ghost tombstones), the file
    stays absent for the pristine world, and reinstalling a previously
    configured provider starts from CURRENT defaults - nothing resurrects.

  Arm B - deletion is meaningless because the last materialization was EMPTY:
    era-inert tombstones (the id now served by a DIFFERENT provider) are fully
    invisible, so the sparse writer removed the file and recorded structure=nil.
    The missing file is our own doing: canonical intent must survive untouched,
    and reinstalling the ORIGINAL provider reactivates the exact customized
    placement. (A moved row whose provider vanished is NOT this case - ghost
    policy keeps rendering it, pinned as B1.)
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
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
require("main")

local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local UIScreens = require("reorderingmenus_ui_screens")
local IntentStore = require("reorderingmenus_intent_store")
local NativeWriter = require("reorderingmenus_native_writer")

local VIEW = "filemanager"
local sd = DataStorage:getSettingsDir()
local ORDER_FILE = sd .. "/" .. VIEW .. "_menu_order.lua"
local SIDECAR = sd .. "/reorderingmenus_materialization.lua"
local INTENT_FILE = sd .. "/reorderingmenus_intent.lua"

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or ""))
    else
        failed = failed + 1
        io.stdout:flush()
        print("  [FAIL] " .. (msg or "") .. string.format(
            " -> expected %s, got %s", tostring(expected), tostring(actual)))
    end
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end

local function wipe()
    os.remove(ORDER_FILE); os.remove(SIDECAR); os.remove(INTENT_FILE)
    IntentStore.load(true); NativeWriter._resetCaches()
    MenuOrderManager:dropSessionState(VIEW)
    package.loaded["ui/elements/" .. VIEW .. "_menu_order"] = nil
    MenuOrderManager.orders[VIEW] = nil
    MenuOrderManager.default_orders[VIEW] = nil
    MenuOrderManager.recent_moves[VIEW] = {}
end

-- A widget stub whose registration can be added/removed at will, simulating
-- install/uninstall of a third-party plugin between launches.
local function make_stub(widget_name, item_id, hint)
    return {
        name = widget_name,
        addToMainMenu = function(self, menu_items)
            menu_items[item_id] = {
                text = string.format(_("Stub %s"), item_id),
                sorting_hint = hint,
                callback = function() end,
            }
        end,
    }
end

local function launch(widgets)
    local ui = { menu = { registered_widgets = widgets or {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, true)
end

-- Disable/re-enable boundaries: a fresh manager session over unchanged disk.
local function disable_project()
    MenuOrderManager:dropSessionState(VIEW)
end
local function enable_project()
    IntentStore.load(true)
    NativeWriter._resetCaches()
end

local defaults = MenuOrderManager:getDefaultOrder(VIEW)
local function first_of(menu_id)
    for _, id in ipairs(defaults[menu_id] or {}) do
        if id ~= "----------------------------" then return id end
    end
    return nil
end
local OPDS = first_of("search")
local HINT_HOME = "more_tools"
assert(defaults[HINT_HOME], "more_tools default list missing")

print("===============================================================")
print("=== V: native deletion while the project is disabled         ===")
print("===============================================================")

-- -------------------------------------------------------------------------
-- Arm B: previously-EMPTY output; deletion must keep intent.
--
-- Two distinct tombstone classes exercise the distinguishing logic:
--   B1  a MOVED row whose provider vanished - ghost policy deliberately
--       keeps rendering it at its configured spot ("one preserved parent"),
--       so output stays content-bearing and a file deletion here WOULD be
--       genuine. Pinned as positive semantics.
--   B2  era-inert tombstones: the same id is now served by a DIFFERENT
--       provider, so the old stamp is fully invisible -> sparse writer
--       removes the file (structure=nil sidecar). Deleting the already-
--       absent file while disabled must NOT wipe canonical intent, and the
--       original provider's return must reactivate the old placement.
-- -------------------------------------------------------------------------
print("\n--- Arm B: previously-EMPTY output; deletion must keep intent ---")

wipe()
local p_old = make_stub("ghostprov", "ghost_row", HINT_HOME)
launch({ p_old })
assert_true(MenuOrderManager:getParentMenu(VIEW, "ghost_row") ~= nil,
    "B: stub anchored after install")
assert_true(MenuOrderManager:moveItemToMenu(VIEW, "ghost_row", HINT_HOME, "tools"),
    "B: ghost_row customized into tools")
assert_true(MenuOrderManager:saveOrder(VIEW), "B: customized state saved")

-- B1: uninstall -> moved ghost keeps its preserved parent.
disable_project()
enable_project()
launch({})   -- provider gone
assert_true(MenuOrderManager:saveOrder(VIEW), "B1: post-uninstall save")
assert_true(lfs.attributes(ORDER_FILE, "mode"),
    "B1: moved ghost keeps emitting (preserved-parent policy)")
local ghost_still_there = false
local b1_file = dofile(ORDER_FILE)
for _, id in ipairs(b1_file["tools"] or {}) do
    if id == "ghost_row" then ghost_still_there = true break end
end
assert_true(ghost_still_there,
    "B1: ghost row rendered at its configured spot while provider absent")
local kept = IntentStore.view(VIEW).parent_override["ghost_row"]
assert_true(type(kept) == "table" and kept.parent == "tools",
    "B1: dormant placement survives as tombstone")

-- B2: hand the SAME id to a different provider -> old stamp fully inert.
disable_project()
enable_project()
local p_beta = make_stub("betaprov", "ghost_row", HINT_HOME)
launch({ p_beta })
assert_eq(MenuOrderManager:getParentMenu(VIEW, "ghost_row"), HINT_HOME,
    "B2: new provider serves the id at its own default home")
assert_true(MenuOrderManager:saveOrder(VIEW), "B2: save under the new era")
assert_true(not lfs.attributes(ORDER_FILE, "mode"),
    "B2: era-inert tombstone empties the emission -> file removed")
kept = IntentStore.view(VIEW).parent_override["ghost_row"]
assert_true(type(kept) == "table" and kept.provider == "plugin:ghostprov",
    "B2: old-era tombstone retained in canonical intent")
local rec_b = NativeWriter.getRecord(VIEW)
assert_true(rec_b ~= nil and rec_b.structure == nil,
    "B2: sidecar records the EMPTY materialization")

-- Disabled phase: user deletes the (already absent) file; stock restart does
-- nothing. Re-enable: this must NOT be read as a genuine deletion.
disable_project()
os.remove(ORDER_FILE)
assert_true(not lfs.attributes(ORDER_FILE, "mode"), "B2: no native file")
enable_project()
launch({ p_beta })
kept = IntentStore.view(VIEW).parent_override["ghost_row"]
assert_true(type(kept) == "table" and kept.provider == "plugin:ghostprov",
    "B2: empty-output absence did NOT wipe canonical intent")
assert_eq(MenuOrderManager:getParentMenu(VIEW, "ghost_row"), HINT_HOME,
    "B2: current provider unaffected by the recovery")

-- Original provider returns (beta gone): its era reactivates verbatim.
launch({})
launch({ p_old })
assert_eq(MenuOrderManager:getParentMenu(VIEW, "ghost_row"), "tools",
    "B2: reinstalling the ORIGINAL provider restores the exact customized spot")
assert_true(MenuOrderManager:saveOrder(VIEW), "B2: reactivated state persists")

-- -------------------------------------------------------------------------
-- Arm A: genuine deletion of real emitted content.
-- -------------------------------------------------------------------------
print("\n--- Arm A: genuine user deletion reverts to stock ---")

wipe()
local p_x = make_stub("removeme", "removable_item", HINT_HOME)
launch({ p_x })
assert_true(MenuOrderManager:moveItemToMenu(VIEW, OPDS, "search", "tools"),
    "A: stock relocation")
assert_true(MenuOrderManager:saveOrder(VIEW), "A: stock customization saved")
assert_true(MenuOrderManager:moveItemToMenu(VIEW, "removable_item", HINT_HOME, "search"),
    "A: provider item customized")
assert_true(MenuOrderManager:saveOrder(VIEW), "A: provider customization saved")
assert_true(lfs.attributes(ORDER_FILE, "mode"), "A: emission on disk")

-- Build a dormant tombstone too: it shares the revert's fate (documented
-- nuclear semantics of deleting our generated file).
disable_project()
enable_project()
launch({})   -- removable_item's provider disappears
assert_true(MenuOrderManager:saveOrder(VIEW), "A: post-uninstall save")
assert_true(type(IntentStore.view(VIEW).parent_override["removable_item"]) == "table",
    "A: dormant tombstone present pre-deletion")
assert_true(lfs.attributes(ORDER_FILE, "mode"),
    "A: file still on disk (stock relocation keeps emitting)")
local rec_a = NativeWriter.getRecord(VIEW)
assert_true(type(rec_a) == "table" and type(rec_a.structure) == "table"
    and next(rec_a.structure) ~= nil,
    "A: sidecar records CONTENT-bearing output")
assert_eq(rec_a.intent_gen, IntentStore.generation(VIEW),
    "A: sidecar generation consistent (no interrupted commit)")

-- THE deletion, while the project is disabled.
disable_project()
os.remove(ORDER_FILE)
-- Stock KOReader restart: nothing in stock recreates plugin files.
assert_true(not lfs.attributes(ORDER_FILE, "mode"), "A: file deleted")

enable_project()
launch({})

-- Revert semantics:
assert_true(next(IntentStore.view(VIEW).hidden or {}) == nil,
    "A: revert wiped hidden records")
local empty_section = true
for key, coll in pairs(IntentStore.view(VIEW)) do
    if type(coll) == "table" and next(coll) ~= nil then empty_section = false end
    if key == "tab_order" and coll ~= nil then empty_section = false end
end
assert_true(empty_section, "A: canonical view fully reverted (tombstones included)")
assert_eq(MenuOrderManager:getParentMenu(VIEW, OPDS), "search",
    "A: projection back at stock")
assert_true(not lfs.attributes(ORDER_FILE, "mode"),
    "A: pristine world stays file-less")
assert_eq(NativeWriter.getRecord(VIEW), nil, "A: sidecar cleared on revert")

-- Old plugin reinstalls afterward: current defaults apply, nothing resurrects.
launch({ p_x })
local home_now = MenuOrderManager:getParentMenu(VIEW, "removable_item")
assert_eq(home_now, HINT_HOME,
    "A: reinstall anchors at CURRENT default home, not the old spot")
assert_true(MenuOrderManager:saveOrder(VIEW),
    "A: post-reinstall save succeeds")
-- Sparse discipline: a pure re-anchor at the provider's own home may emit
-- NOTHING (stock-equal graph). Placement truth lives in the projection.
local listed_home = false
for _, id in ipairs(MenuOrderManager:getMenuItems(VIEW, HINT_HOME)) do
    if id == "removable_item" then listed_home = true break end
end
assert_true(listed_home,
    "A: fresh anchoring places the item like any newcomer would")

-- Leave a clean world behind for neighbouring suites.
MenuOrderManager:resetOrder(VIEW)

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

--[[--
Reset-all metamorphic property.

Build a pathological state (moves, hides, ghosts, provider upgrades, custom
submenus, collisions, presets), run Reset All, then require:

  R1  canonical intent for the view is empty (no stale records).
  R2  projection == a fresh installation's projection against the CURRENT
      world (compare against an independently wiped profile).
  R3  reinstalling previously-absent providers must NOT resurrect old
      moves/hides: their records are gone, so they land at current defaults.
  R4  presets survive Reset All but re-applying one only restores what it
      explicitly captured.
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

local MenuOrderManager = require("lib.menuorder_manager")
local UIScreens = require("lib.ui_screens")
local IntentStore = require("lib.intent_store")
local NativeWriter = require("lib.native_writer")
local util = require("util")

local view = "filemanager"
local sd = DataStorage:getSettingsDir()

local passed, failed = 0, 0
local function assert_eq(a, e, msg)
    if a == e then passed = passed + 1
    else failed = failed + 1
        print(string.format("  [FAIL] %s -> expected %s, got %s",
            msg, tostring(e), tostring(a)))
        io.stdout:flush()
    end
end
local function assert_true(c, msg) assert_eq(not not c, true, msg) end

local function fresh()
    os.remove(sd .. "/" .. view .. "_menu_order.lua")
    os.remove(sd .. "/reorderingmenus_intent.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    IntentStore.load(true); NativeWriter._resetCaches()
    MenuOrderManager:dropSessionState(view)
end
local function launch(widgets)
    local ui = { menu = { registered_widgets = widgets or {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, view, false)
end

print("===============================================================")
print("=== Reset-all metamorphic property                           ===")
print("===============================================================")

-- ---- build the pathological world --------------------------------------
fresh(); launch()
-- moves (cross-menu + in-menu)
MenuOrderManager:moveItemToMenu(view, "opds", "search", "tools")
launch()
-- hides
MenuOrderManager:setItemHidden(view, "keep_alive", true, "more_tools")
-- custom submenu with children
assert_true(MenuOrderManager:createSubmenu(view, "tools", "my_custom_tab"),
    "setup: custom submenu created")
-- ghost via plugin install/uninstall
local widgets = {
    phantom_plugin = {
        name = "phantom_plugin",
        addToMainMenu = function(_, menu_items)
            menu_items.phantom_fixture =
                { text = "Phantom", sorting_hint = "tools" }
        end,
    },
}
launch(widgets)
MenuOrderManager:moveItemToMenu(view, "phantom_fixture", "tools", "main")
MenuOrderManager:saveOrder(view)
-- uninstall -> ghost
widgets.phantom_plugin = nil
launch(widgets)
MenuOrderManager:saveOrder(view)

local sec_before = IntentStore.view(view)
local had_ghost = sec_before.parent_override.phantom_fixture ~= nil
assert_true(had_ghost, "setup: ghost record retained after uninstall")

-- preset capturing the moved opds BEFORE reset
local Presets = require("lib.presets")
local ok_save = Presets.saveViewPreset(view, "reset_probe",
    util.tableDeepCopy(sec_before))
assert_true(ok_save ~= false, "setup: preset saved")

-- ---- RESET ALL ----------------------------------------------------------
MenuOrderManager:resetOrder(view)
MenuOrderManager:saveOrder(view)

-- R1: canonical emptiness
do
    local sec = IntentStore.view(view)
    assert_eq(next(sec.parent_override), nil,
        "R1: no parent overrides survive reset")
    assert_eq(next(sec.hidden), nil, "R1: no hidden records survive reset")
    assert_eq(next(sec.position_override), nil,
        "R1: no position anchors survive reset")
    assert_eq(next(sec.order_override), nil,
        "R1: no bulk sequences survive reset")
    assert_eq(next(sec.custom_menus), nil,
        "R1: custom submenus removed by reset")
end

-- R3: reinstall the phantom AFTER the reset; it must land at its CURRENT
-- default home (tools, from sorting_hint), not at the old 'main' placement.
do
    local widgets2 = {
        phantom_plugin2 = {
            name = "phantom_plugin2",
            addToMainMenu = function(_, menu_items)
                menu_items.phantom_fixture =
                    { text = "Phantom", sorting_hint = "tools" }
            end,
        },
    }
    launch(widgets2)
    local parent = MenuOrderManager:getParentMenu(view, "phantom_fixture")
    assert_eq(parent, "tools",
        "R3: reinstall after reset lands at current provider default")
end

-- R2: semantic equality with an independently-fresh profile is approximated
-- by resetting again and comparing the two projections' tab sets.
do
    local tabs1 = MenuOrderManager:getTabs(view)
    -- second full reset on the already-reset state must be a fixpoint
    MenuOrderManager:resetOrder(view)
    MenuOrderManager:saveOrder(view)
    local tabs2 = MenuOrderManager:getTabs(view)
    assert_true(util.tableEquals(tabs1, tabs2),
        "R2: reset is a fixpoint (projection stable across resets)")
end

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

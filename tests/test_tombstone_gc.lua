--[[--
Tombstone garbage collection ("Forget stale customizations").

  G1  retained ghost -> reinstall restores the old customization.
  G2  forgotten ghost -> reinstall gets the CURRENT provider default.
  G3  a different plugin reusing the same id never inherits the old record
      (provider-era protection) - before AND after GC.
  G4  GC never touches records for ids still served (stock or live plugins).
  G5  countStaleCustomizations is read-only: canonical unchanged.
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
local function phantom_widgets(hint)
    return {
        phantom_plugin = {
            name = "phantom_plugin",
            addToMainMenu = function(_, menu_items)
                menu_items.phantom_fixture =
                    { text = "Phantom", sorting_hint = hint }
            end,
        },
    }
end

print("===============================================================")
print("=== Tombstone garbage collection                             ===")
print("===============================================================")

print("\n--- G1: retained ghost restores customization ---")
do
    fresh(); launch(phantom_widgets("tools"))
    MenuOrderManager:moveItemToMenu(view, "phantom_fixture", "tools", "main")
    MenuOrderManager:saveOrder(view)
    launch()   -- uninstall (no provider)
    MenuOrderManager:saveOrder(view)
    assert_true(IntentStore.view(view).parent_override.phantom_fixture ~= nil,
        "G1: ghost retained after uninstall")
    launch(phantom_widgets("tools"))   -- reinstall
    assert_eq(MenuOrderManager:getParentMenu(view, "phantom_fixture"), "main",
        "G1: reinstall restores the old placement")
end

print("\n--- G2: forgotten ghost -> current defaults ---")
do
    fresh(); launch(phantom_widgets("tools"))
    MenuOrderManager:moveItemToMenu(view, "phantom_fixture", "tools", "setting")
    MenuOrderManager:saveOrder(view)
    launch(); MenuOrderManager:saveOrder(view)   -- uninstall -> ghost

    local stale = MenuOrderManager:countStaleCustomizations(view)
    local found = false
    for _, id in ipairs(stale) do
        if id == "phantom_fixture" then found = true end
    end
    assert_true(found, "G2: stale list contains the ghost")

    MenuOrderManager:forgetStaleCustomizations(view)
    MenuOrderManager:saveOrder(view)
    assert_true(IntentStore.view(view).parent_override.phantom_fixture == nil,
        "G2: ghost record dropped")

    -- reinstall with an UPDATED hint (plugin changed its home too)
    launch({
        phantom_plugin = {
            name = "phantom_plugin",
            addToMainMenu = function(_, menu_items)
                menu_items.phantom_fixture =
                    { text = "Phantom", sorting_hint = "more_tools" }
            end,
        },
    })
    assert_eq(MenuOrderManager:getParentMenu(view, "phantom_fixture"),
        "more_tools", "G2: reinstall follows CURRENT provider default")
end

print("\n--- G3: id reuse across providers never inherits ---")
do
    fresh()
    launch({
        plugin_a = {
            name = "plugin_a",
            addToMainMenu = function(_, menu_items)
                menu_items.shared_id = { text = "A", sorting_hint = "tools" }
            end,
        },
    })
    MenuOrderManager:moveItemToMenu(view, "shared_id", "tools", "search")
    MenuOrderManager:saveOrder(view)
    launch(); MenuOrderManager:saveOrder(view)   -- A gone; ghost stamped 'a'

    -- different provider, same id
    launch({
        plugin_b = {
            name = "plugin_b",
            addToMainMenu = function(_, menu_items)
                menu_items.shared_id = { text = "B", sorting_hint = "setting" }
            end,
        },
    })
    assert_eq(MenuOrderManager:getParentMenu(view, "shared_id"), "setting",
        "G3: new provider's item lands at ITS default, not A's move")
end

print("\n--- G4/G5: GC scope + read-only counting ---")
do
    fresh(); launch()
    MenuOrderManager:moveItemToMenu(view, "opds", "search", "tools")   -- stock id
    MenuOrderManager:setItemHidden(view, "keep_alive", true, "more_tools")
    MenuOrderManager:saveOrder(view)
    launch(phantom_widgets("tools"))
    MenuOrderManager:saveOrder(view)
    launch(); MenuOrderManager:saveOrder(view)   -- ghost again

    local sec_before = util.tableDeepCopy(IntentStore.view(view))
    local stale = MenuOrderManager:countStaleCustomizations(view)   -- must not mutate
    assert_true(util.tableEquals(sec_before, IntentStore.view(view)),
        "G5: counting is read-only")

    MenuOrderManager:forgetStaleCustomizations(view)
    MenuOrderManager:saveOrder(view)
    local sec = IntentStore.view(view)
    assert_eq((sec.parent_override.opds or {}).parent, "tools",
        "G4: stock-id move untouched by GC")
    assert_true(sec.hidden.keep_alive ~= nil,
        "G4: stock-id hide untouched by GC")
    assert_true(sec.parent_override.phantom_fixture == nil,
        "G4: ghost dropped by GC")
end

fresh()
print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

--[[--
Unit and Integration Tests for Preset Management in ReorderingMenus
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"), "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()

local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

-- Deterministic baseline: wipe persisted menu state before this suite runs
-- (fresh process = no in-memory sessions; removing the files is enough).
do
    local _sd = DataStorage:getSettingsDir()
    for _, _name in ipairs({
        "reader_menu_order.lua", "filemanager_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua",
        "reorderingmenus_state.lua",
    }) do
        pcall(os.remove, _sd .. "/" .. _name)
    end
    -- Preset directories: leftover user presets would break count assertions.
    local _lfs = require("libs/libkoreader-lfs")
    local function _rmtree(path)
        if _lfs.attributes(path, "mode") ~= "directory" then return end
        for _entry in _lfs.dir(path) do
            if _entry ~= "." and _entry ~= ".." then
                local _full = path .. "/" .. _entry
                if _lfs.attributes(_full, "mode") == "directory" then
                    _rmtree(_full)
                else
                    pcall(os.remove, _full)
                end
            end
        end
    end
    for _, _view in ipairs({ "reader", "filemanager" }) do
        _rmtree(_sd .. "/menu_order_presets/" .. _view)
        _rmtree(_sd .. "/menu_order_presets/" .. _view .. "/submenus")
    end
end

local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local UIScreens = require("reorderingmenus_ui_screens")
local ReorderingMenus = require("main")
local UIManager = require("ui/uimanager")

local passed = 0
local failed = 0

local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or "assertion"))
    else
        failed = failed + 1
        io.stdout:flush()
        print("  [FAIL] " .. (msg or "assertion") .. " -> Expected: " .. tostring(expected) .. ", Got: " .. tostring(actual))
    end
end

local function assert_true(cond, msg)
    assert_eq(not not cond, true, msg)
end

print("===============================================================")
print("=== Preset Management Test Suite                            ===")
print("===============================================================")

-- 1. Test Built-in Presets
print("\n--- Test 1: Built-in Presets ---")
local reader_builtins = MenuOrderManager:getBuiltinPresets("reader")
assert_true(#reader_builtins >= 4, "Reader has 4+ built-in presets")
assert_eq(reader_builtins[1].id, "builtin_default", "Default preset present")
assert_eq(reader_builtins[2].id, "builtin_reading_focused", "Reading Focused preset present")
assert_eq(reader_builtins[3].id, "builtin_minimalist", "Minimalist Reader preset present")
assert_eq(reader_builtins[4].id, "builtin_power_user", "Power User preset present")

local fm_builtins = MenuOrderManager:getBuiltinPresets("filemanager")
assert_true(#fm_builtins >= 3, "FileManager has 3+ built-in presets")

-- 2. Test Saving User Preset
print("\n--- Test 2: Saving User Preset ---")
local test_preset_name = "Unit_Test_Preset_Alpha"
-- Clean up previous run if any
MenuOrderManager:deletePreset("reader", test_preset_name)

local ok, path = MenuOrderManager:savePreset("reader", test_preset_name)
assert_true(ok, "Preset saved successfully to: " .. tostring(path))
assert_true(lfs.attributes(path) ~= nil, "Preset file exists on filesystem")

-- 3. Test Listing Presets
print("\n--- Test 3: Listing Presets ---")
local user_presets = MenuOrderManager:listUserPresets("reader")
local found = false
for __, p in ipairs(user_presets) do
    if p.name == test_preset_name then
        found = true
        break
    end
end
assert_true(found, "User preset found in listUserPresets")

local all_presets = MenuOrderManager:getAllPresets("reader")
assert_true(#all_presets >= #reader_builtins + 1, "getAllPresets returns built-ins + user presets")

-- 4. Test Loading Built-in Minimalist Preset
print("\n--- Test 4: Loading Built-in Minimalist Preset ---")
local load_ok, err = MenuOrderManager:loadPreset("reader", "builtin_minimalist")
assert_true(load_ok, "Minimalist preset loaded successfully")
local tabs = MenuOrderManager:getTabs("reader")
assert_eq(#tabs, 2, "Minimalist preset has exactly 2 tabs (navi, typeset)")
assert_eq(tabs[1], "navi", "First tab is navi")
assert_eq(tabs[2], "typeset", "Second tab is typeset")

-- 5. Test Loading Built-in Reading Focused Preset
print("\n--- Test 5: Loading Built-in Reading Focused Preset ---")
load_ok, err = MenuOrderManager:loadPreset("reader", "builtin_reading_focused")
assert_true(load_ok, "Reading focused preset loaded successfully")
tabs = MenuOrderManager:getTabs("reader")
assert_eq(#tabs, 4, "Reading focused preset has 4 tabs")
assert_eq(tabs[1], "typeset", "First tab is typeset")
assert_eq(tabs[2], "navi", "Second tab is navi")

-- 6. Test Loading User Preset
print("\n--- Test 6: Loading User Preset ---")
load_ok, err = MenuOrderManager:loadPreset("reader", test_preset_name)
assert_true(load_ok, "User preset loaded successfully")

-- 7. Test Deleting User Preset
print("\n--- Test 7: Deleting User Preset ---")
local del_ok = MenuOrderManager:deletePreset("reader", test_preset_name)
assert_true(del_ok, "User preset deleted successfully")
user_presets = MenuOrderManager:listUserPresets("reader")
found = false
for __, p in ipairs(user_presets) do
    if p.name == test_preset_name then
        found = true
        break
    end
end
assert_eq(found, false, "User preset no longer in list")

-- 8. Test Submenu Presets
print("\n--- Test 8: Submenu Presets ---")
local direct_preset_name = "Unit_Test_Navigation_Direct"
local nested_preset_name = "Unit_Test_Navigation_Nested"
MenuOrderManager:deleteSubmenuPreset("reader", "navi", direct_preset_name)
MenuOrderManager:deleteSubmenuPreset("reader", "navi", nested_preset_name)
MenuOrderManager:resetOrder("reader")

local default_order = MenuOrderManager:getDefaultOrder("reader")
local desired_navi = util.tableDeepCopy(default_order.navi)
local desired_navi_settings = util.tableDeepCopy(default_order.navi_settings)
desired_navi[1], desired_navi[2] = desired_navi[2], desired_navi[1]
desired_navi_settings[1], desired_navi_settings[2] = desired_navi_settings[2], desired_navi_settings[1]

-- Stage the desired arrangement as user intent (architecture 5: editors
-- translate list edits into sparse records; nothing else is stored).
MenuOrderManager:stageList("reader", "navi", util.tableDeepCopy(desired_navi))
MenuOrderManager:stageList("reader", "navi_settings",
    util.tableDeepCopy(desired_navi_settings))

ok, path = MenuOrderManager:saveSubmenuPreset(
    "reader", "navi", "Navigation", direct_preset_name, false
)
assert_true(ok and lfs.attributes(path) ~= nil, "Direct submenu preset saved")
ok, path = MenuOrderManager:saveSubmenuPreset(
    "reader", "navi", "Navigation", nested_preset_name, true
)
assert_true(ok and lfs.attributes(path) ~= nil, "Nested submenu preset saved")

local submenu_presets = MenuOrderManager:listSubmenuPresets("reader", "navi")
local direct_preset
local nested_preset
for _, preset in ipairs(submenu_presets) do
    if preset.name == direct_preset_name then direct_preset = preset end
    if preset.name == nested_preset_name then nested_preset = preset end
end
assert_true(direct_preset ~= nil and not direct_preset.include_submenus, "Direct preset is scoped to one menu")
assert_true(nested_preset ~= nil and nested_preset.include_submenus, "Nested preset records recursive scope")
assert_true(nested_preset and nested_preset.menu_count >= 2, "Nested preset captures child submenu order")

local function restore_stock_with_newcomer()
    local restored_navi = util.tableDeepCopy(default_order.navi)
    table.insert(restored_navi, "new_plugin_navigation_item")
    MenuOrderManager:stageList("reader", "navi", restored_navi)
    MenuOrderManager:stageList("reader", "navi_settings",
        util.tableDeepCopy(default_order.navi_settings))
end

-- The newcomer simulates a freshly installed plugin. Under the
-- membership-gated pipeline (commit c926e96) ids nothing serves are
-- deliberately dropped from staged lists, so the plugin must actually
-- register its item through the live-registrations channel - exactly what
-- a real installation does.
do
    local newcomer_widget = {
        name = "newcomer_plugin",
        addToMainMenu = function(_, m)
            m.new_plugin_navigation_item = {
                text = "New Plugin Navigation",
                sorting_hint = "navi",
            }
        end,
    }
    local captured = {}
    newcomer_widget:addToMainMenu(captured)
    MenuOrderManager:setLiveRegistrations("reader", captured,
        { new_plugin_navigation_item = "newcomer_plugin" })
    -- The manager session was already built (steps 1-7); the registry must
    -- be rebuilt from the new live registrations or the newcomer id stays
    -- unknown and membership-gated staging/preset merges drop it.
    MenuOrderManager:refreshRegistry("reader")
end

restore_stock_with_newcomer()
load_ok, err = MenuOrderManager:loadSubmenuPreset("reader", "navi", direct_preset)
assert_true(load_ok, "Direct submenu preset loaded")
local after_direct_navi = MenuOrderManager:getMenuItems("reader", "navi")
local after_direct_settings = MenuOrderManager:getMenuItems("reader", "navi_settings")
assert_eq(after_direct_navi[1], desired_navi[1], "Direct preset restores root submenu order")
assert_eq(after_direct_settings[1], default_order.navi_settings[1], "Direct preset leaves nested submenu unchanged")
assert_eq(after_direct_navi[#after_direct_navi], "new_plugin_navigation_item", "Direct preset preserves new plugin items")

restore_stock_with_newcomer()
load_ok, err = MenuOrderManager:loadSubmenuPreset("reader", "navi", nested_preset)
assert_true(load_ok, "Nested submenu preset loaded")
local after_nested_navi = MenuOrderManager:getMenuItems("reader", "navi")
local after_nested_settings = MenuOrderManager:getMenuItems("reader", "navi_settings")
assert_eq(after_nested_navi[1], desired_navi[1], "Nested preset restores root submenu order")
assert_eq(after_nested_settings[1], desired_navi_settings[1], "Nested preset restores child submenu order")
assert_eq(after_nested_navi[#after_nested_navi], "new_plugin_navigation_item", "Nested preset preserves new plugin items")

assert_true(MenuOrderManager:deleteSubmenuPreset("reader", "navi", direct_preset), "Direct submenu preset deleted")
assert_true(MenuOrderManager:deleteSubmenuPreset("reader", "navi", nested_preset), "Nested submenu preset deleted")

-- 9. Test Presets UI Screens
print("\n--- Test 9: Presets UI Screens Simulation ---")
local mock_ui = {
    document = { file = "test.epub" },
    doc_settings = { isTrue = function() return false end, makeFalse = function() end, makeTrue = function() end },
    saveSettings = function() end,
    registerTouchZones = function() end,
    onClose = function() end,
    showFileManager = function() end,
    registerModule = function(self, name, mod) self[name] = mod end,
    menu = { registerToMainMenu = function() end },
}
local plugin = ReorderingMenus:new{ ui = mock_ui }

local ui_ok, ui_err = pcall(function()
    UIScreens:showPresetsMenu(plugin, "reader")
    local top_entry = UIManager._window_stack[#UIManager._window_stack]
    local menu = (top_entry and top_entry.widget) or top_entry
    assert_true(menu ~= nil, "Presets menu opened")
    UIManager:close(menu)
end)
assert_true(ui_ok, "showPresetsMenu opened and closed cleanly: " .. tostring(ui_err))

ui_ok, ui_err = pcall(function()
    UIScreens:showLoadPresetMenu(plugin, "reader")
    local top_entry = UIManager._window_stack[#UIManager._window_stack]
    local menu = (top_entry and top_entry.widget) or top_entry
    assert_true(menu ~= nil, "Load Preset menu opened")
    UIManager:close(menu)
end)
assert_true(ui_ok, "showLoadPresetMenu opened and closed cleanly: " .. tostring(ui_err))

ui_ok, ui_err = pcall(function()
    UIScreens:showSubmenuPresetsMenu(plugin, "reader", "tools", "Tools")
    local top_entry = UIManager._window_stack[#UIManager._window_stack]
    local menu = (top_entry and top_entry.widget) or top_entry
    assert_true(menu ~= nil and menu.title == "Presets for Tools", "Submenu preset manager opened for its menu name")
    assert_eq(menu.item_table[1].text, "Save this menu order…", "Direct-only save is the default option")
    assert_eq(menu.item_table[2].text, "Save with nested submenu orders…", "Nested submenu capture is offered separately")
    UIManager:close(menu)
end)
assert_true(ui_ok, "showSubmenuPresetsMenu opened and closed cleanly: " .. tostring(ui_err))

ui_ok, ui_err = pcall(function()
    MenuOrderManager:saveSubmenuPreset("reader", "tools", "Tools", direct_preset_name, false)
    MenuOrderManager:saveSubmenuPreset("reader", "tools", "Tools", nested_preset_name, true)
    UIScreens:showDeleteSubmenuPresetMenu(plugin, "reader", "tools", "Tools")
    local top_entry = UIManager._window_stack[#UIManager._window_stack]
    local menu = (top_entry and top_entry.widget) or top_entry
    local labels = {}
    for _, item in ipairs(menu.item_table or {}) do labels[item.text] = true end
    assert_true(labels["[Direct] " .. direct_preset_name], "Delete list labels direct presets")
    assert_true(labels["[Nested] " .. nested_preset_name], "Delete list labels nested presets")
    UIManager:close(menu)
    MenuOrderManager:deleteSubmenuPreset("reader", "tools", direct_preset_name)
    MenuOrderManager:deleteSubmenuPreset("reader", "tools", nested_preset_name)
end)
assert_true(ui_ok, "Delete submenu preset labels rendered cleanly: " .. tostring(ui_err))

-- Reset to clean defaults
MenuOrderManager:resetOrder("reader")
MenuOrderManager:resetOrder("filemanager")

print(string.format("\n==============================================================="))
print(string.format("=== PRESET TESTS COMPLETED: %d PASSED, %d FAILED             ===", passed, failed))
print("===============================================================")

if failed > 0 then
    os.exit(1)
end

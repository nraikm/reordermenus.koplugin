dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"), "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local MenuSorter = require("ui/menusorter")
local dump = require("dump")
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

local MenuTitles = require("reorderingmenus_menu_titles")
local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local UIScreens = require("reorderingmenus_ui_screens")
local MainPlugin = require("main")

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

local function list_contains(items, expected)
    for _, item in ipairs(items or {}) do
        if item == expected then return true end
    end
    return false
end

local function count_menu_references(order, expected)
    local count = 0
    for menu_id, items in pairs(order or {}) do
        if menu_id ~= "KOMenu:disabled" and type(items) == "table" then
            for _, item in ipairs(items) do
                if item == expected then count = count + 1 end
            end
        end
    end
    return count
end

print("=======================================================")
print("=== KOReader Reordering Menus Plugin - Test Suite   ===")
print("=======================================================")

-- -------------------------------------------------------------
-- Suite 1: Plugin Metadata & Initialization
-- -------------------------------------------------------------
print("\n--- Suite 1: Metadata & Plugin Setup ---")
local meta = dofile(project_dir .. "/_meta.lua")
assert_eq(meta.name, "reorderingmenus", "Meta plugin name")
assert_true(meta.fullname ~= nil and #meta.fullname > 0, "Meta fullname exists")
assert_true(meta.description ~= nil and #meta.description > 0, "Meta description exists")

local plugin_instance = MainPlugin:new{
    ui = {
        menu = {
            registered_widgets = {},
            registerToMainMenu = function(self, w)
                table.insert(self.registered_widgets, w)
            end,
        },
        document = { file = "dummy.epub" },
    }
}
assert_eq(UIScreens.current_view, "reader", "UIScreens view initialized to reader when document is present")
assert_eq(#plugin_instance.ui.menu.registered_widgets, 1, "Plugin registered to main menu")

local mock_menu_items = {}
plugin_instance:addToMainMenu(mock_menu_items)
assert_true(mock_menu_items.reordering_menus ~= nil, "addToMainMenu added reordering_menus")
assert_eq(mock_menu_items.reordering_menus.sorting_hint, "more_tools", "Sorting hint is more_tools")
assert_true(type(mock_menu_items.reordering_menus.callback) == "function", "Main menu uses direct reorder callback")
assert_true(type(plugin_instance.showReorderScreen) == "function", "Plugin exposes its reorder screen opener")

-- Regression: the direct callback must pass the active view. Without it,
-- MenuOrderManager tries to require ui/elements/nil_menu_order and KOReader exits.
local original_show_tab_reorder = UIScreens.showTabReorderDialog
local callback_plugin, callback_view
UIScreens.showTabReorderDialog = function(_, plugin, view)
    callback_plugin = plugin
    callback_view = view
end
local callback_ok = pcall(mock_menu_items.reordering_menus.callback)
UIScreens.showTabReorderDialog = original_show_tab_reorder
assert_true(callback_ok, "Direct reorder callback runs")
assert_eq(callback_plugin, plugin_instance, "Direct reorder callback passes plugin")
assert_eq(callback_view, "reader", "Direct reorder callback passes active view")

-- -------------------------------------------------------------
-- Suite 2: MenuTitles Translations & Icons
-- -------------------------------------------------------------
print("\n--- Suite 2: MenuTitles Lookups ---")
assert_eq(MenuTitles:getTitle("navi"), "Navigation", "Tab title for navi")
assert_eq(MenuTitles:getTitle("typeset"), "Typeset", "Tab title for typeset")
assert_eq(MenuTitles:getTitle("setting"), "Settings", "Tab title for setting")
assert_eq(MenuTitles:getTitle("tools"), "Tools", "Tab title for tools")
assert_eq(MenuTitles:getTitle("search"), "Search", "Tab title for search")
assert_eq(MenuTitles:getTitle("main"), "Main menu", "Tab title for main")
assert_eq(MenuTitles:getTitle("filemanager_settings"), "File browser", "Tab title for filemanager_settings")

assert_eq(MenuTitles:getIcon("navi"), "appbar.navigation", "Icon for navi")
assert_eq(MenuTitles:getIcon("setting"), "appbar.settings", "Icon for setting")
assert_eq(MenuTitles:getIcon("tools"), "appbar.tools", "Icon for tools")

assert_eq(MenuTitles:getTitle("frontlight"), "Frontlight", "Title for frontlight")
assert_eq(MenuTitles:getTitle("bookmarks"), "Bookmarks", "Title for bookmarks")
assert_eq(MenuTitles:getTitle("doc_setting_tweak"), "Document setting tweak", "Title for doc_setting_tweak")
assert_eq(MenuTitles:getTitle("custom_plugin_action"), "Custom Plugin Action", "Humanized title for custom_plugin_action")

-- -------------------------------------------------------------
-- Suite 3: Default Order Loading (Reader & FileManager)
-- -------------------------------------------------------------
print("\n--- Suite 3: Default Order Loading ---")
local reader_default = MenuOrderManager:getDefaultOrder("reader")
assert_true(#reader_default["KOMenu:menu_buttons"] == 7, "Reader has 7 default tabs")
local fm_default = MenuOrderManager:getDefaultOrder("filemanager")
assert_true(#fm_default["KOMenu:menu_buttons"] == 6, "FileManager has 6 default tabs")

-- -------------------------------------------------------------
-- Suite 4: Tab Reordering & Visibility
-- -------------------------------------------------------------
print("\n--- Suite 4: Tab Reordering & Visibility ---")
local initial_tabs = MenuOrderManager:getTabs("reader")
local tab1 = initial_tabs[1]
local tab2 = initial_tabs[2]

-- Reorder tabs
local reordered_tabs = { tab2, tab1, unpack(initial_tabs, 3) }
MenuOrderManager:reorderTabs("reader", reordered_tabs)
local current_tabs = MenuOrderManager:getTabs("reader")
assert_eq(current_tabs[1], tab2, "Tab 2 is now first")
assert_eq(current_tabs[2], tab1, "Tab 1 is now second")

-- Hide a tab
MenuOrderManager:setTabHidden("reader", "search", true)
local tabs_after_hide = MenuOrderManager:getTabs("reader")
local search_present = false
for _, t in ipairs(tabs_after_hide) do
    if t == "search" then search_present = true break end
end
assert_eq(search_present, false, "Search tab removed from active tabs")
assert_true(MenuOrderManager:isItemHidden("reader", "search"), "Search tab is marked as hidden")

-- Unhide the tab
MenuOrderManager:setTabHidden("reader", "search", false)
assert_eq(MenuOrderManager:isItemHidden("reader", "search"), false, "Search tab is unhidden")

-- -------------------------------------------------------------
-- Suite 5: Menu Item Reordering & Cross-Menu Movement
-- -------------------------------------------------------------
print("\n--- Suite 5: Item Movement & Management ---")
local tools_items = MenuOrderManager:getMenuItems("reader", "tools")
local first_item = tools_items[1]
local second_item = tools_items[2]

MenuOrderManager:moveItem("reader", "tools", 1, 2)
assert_eq(MenuOrderManager:getMenuItems("reader", "tools")[1], second_item, "Item moved to position 1")
assert_eq(MenuOrderManager:getMenuItems("reader", "tools")[2], first_item, "Item moved to position 2")

-- Move item to another submenu
local from_menu, from_idx = MenuOrderManager:getParentMenu("reader", "statistics")
assert_eq(from_menu, "tools", "Statistics starts in tools")

MenuOrderManager:moveItemToMenu("reader", "statistics", "tools", "navi", 1)
local target_menu, target_idx = MenuOrderManager:getParentMenu("reader", "statistics")
assert_eq(target_menu, "navi", "Statistics moved to navi")
assert_eq(target_idx, 1, "Statistics inserted at index 1 in navi")

-- Move it back
MenuOrderManager:moveItemToMenu("reader", "statistics", "navi", "tools", 4)
local restored_menu = MenuOrderManager:getParentMenu("reader", "statistics")
assert_eq(restored_menu, "tools", "Statistics restored to tools")

-- Move a complete submenu between top-level menus; its contents must remain intact.
local original_more_tools = MenuOrderManager:getMenuItems("reader", "more_tools")
local moved_submenu = MenuOrderManager:moveItemToMenu("reader", "more_tools", "tools", "setting", 2)
assert_true(moved_submenu, "More tools submenu moved from Tools to Settings")
assert_eq(MenuOrderManager:getParentMenu("reader", "more_tools"), "setting", "Moved submenu has the new parent")
assert_eq(table.concat(MenuOrderManager:getMenuItems("reader", "more_tools"), "\0"),
    table.concat(original_more_tools, "\0"), "Moving a submenu preserves its internal order")
assert_eq(list_contains(MenuOrderManager:getMenuItems("reader", "tools"), "more_tools"), false,
    "Moved submenu is removed from its old parent")

local restored_submenu = MenuOrderManager:moveItemToMenu("reader", "more_tools", "setting", "tools")
assert_true(restored_submenu, "More tools submenu moved back to Tools")

-- Move a submenu into another, unrelated submenu and restore it.
local original_help = MenuOrderManager:getMenuItems("reader", "help")
assert_true(MenuOrderManager:moveItemToMenu("reader", "help", "main", "more_tools", 1),
    "Help submenu moved into More tools")
assert_eq(MenuOrderManager:getParentMenu("reader", "help"), "more_tools", "Nested destination becomes the parent")
assert_eq(table.concat(MenuOrderManager:getMenuItems("reader", "help"), "\0"),
    table.concat(original_help, "\0"), "Nested submenu contents remain intact")
assert_true(MenuOrderManager:moveItemToMenu("reader", "help", "more_tools", "main"),
    "Help submenu restored to Main menu")

-- FileManager maintains an independent order and supports the same moves.
local fm_more_tools = MenuOrderManager:getMenuItems("filemanager", "more_tools")
assert_true(MenuOrderManager:moveItemToMenu("filemanager", "more_tools", "tools", "setting", 1),
    "Normal-view More tools submenu moved to Settings")
assert_eq(MenuOrderManager:getParentMenu("filemanager", "more_tools"), "setting",
    "Normal-view submenu has the new parent")
assert_eq(table.concat(MenuOrderManager:getMenuItems("filemanager", "more_tools"), "\0"),
    table.concat(fm_more_tools, "\0"), "Normal-view submenu contents remain intact")
assert_true(MenuOrderManager:moveItemToMenu("filemanager", "more_tools", "setting", "tools"),
    "Normal-view More tools submenu restored")

-- Reject moves that would corrupt the menu graph or duplicate an item.
local self_move, self_err = MenuOrderManager:moveItemToMenu("reader", "more_tools", "tools", "more_tools")
assert_eq(self_move, false, "A submenu cannot be moved into itself")
assert_true(type(self_err) == "string", "Rejected self move explains the failure")
assert_eq(list_contains(MenuOrderManager:getMenuItems("reader", "more_tools"), "more_tools"), false,
    "Rejected self move does not create a cycle")
assert_true(MenuOrderManager:isMenuDescendant("reader", "setting", "document"),
    "Document is recognized as a descendant of Settings")
local descendant_move = MenuOrderManager:moveItemToMenu(
    "reader", "setting", "KOMenu:menu_buttons", "document"
)
assert_eq(descendant_move, false, "A menu cannot be moved into one of its descendants")
local wrong_source_move = MenuOrderManager:moveItemToMenu("reader", "statistics", "navi", "search")
assert_eq(wrong_source_move, false, "A stale or incorrect source menu is rejected")
assert_eq(MenuOrderManager:getParentMenu("reader", "statistics"), "tools",
    "Rejected wrong-source move leaves the item in place")

local new_plugin_move = MenuOrderManager:moveItemToMenu(
    "reader", "new_plugin_fixture", "tools", "setting", 1
)
assert_true(new_plugin_move, "A newly registered plugin item can acquire its first configured destination")
assert_eq(MenuOrderManager:getParentMenu("reader", "new_plugin_fixture"), "setting",
    "New plugin item is persisted under the selected menu")
assert_true(MenuOrderManager:moveItemToMenu(
    "reader", "new_plugin_fixture", "setting", "tools"
), "Configured new plugin item can be moved again")

-- Architecture 5 makes duplicate parents impossible by construction (the
-- materializer assigns a single parent). What still needs repairing is a
-- hand-edited or legacy dense file containing duplicates: importing it must
-- yield exactly one authoritative parent, keeping the customized destination.
assert_true(MenuOrderManager:saveOrder("reader"),
    "Persist state before simulating a legacy duplicate-parent file")
local legacy_duplicate = MenuOrderManager:loadOrder("reader")
table.insert(legacy_duplicate.search, "statistics")
util.writeToFile(dump(legacy_duplicate, nil, true),
    DataStorage:getSettingsDir() .. "/reader_menu_order.lua", true, true)
MenuOrderManager:reloadFromDisk("reader")
local repaired_import = MenuOrderManager:loadOrder("reader", true)
assert_eq(count_menu_references(repaired_import, "statistics"), 1,
    "Cross-menu move leaves exactly one authoritative parent")
assert_eq(MenuOrderManager:getParentMenu("reader", "statistics"), "search",
    "Duplicate repair keeps the selected destination")
assert_true(MenuOrderManager:moveItemToMenu("reader", "statistics", "search", "tools"),
    "Repaired item can be moved normally afterward")
local statistics_move = MenuOrderManager:getRecentMoves("reader").statistics
assert_eq(statistics_move and statistics_move.to, "tools",
    "Recent move state records the interface's authoritative location")

-- Reproduce the real Battery Statistics failure through the same door: a
-- persisted file listing the item under both More tools and Tools is imported
-- deterministically, keeping the customized non-default destination.
assert_true(MenuOrderManager:saveOrder("reader"), "Persist before Battery Statistics fixture")
local persisted_duplicate = MenuOrderManager:loadOrder("reader")
table.insert(persisted_duplicate.tools, "battery_statistics")
util.writeToFile(dump(persisted_duplicate, nil, true),
    DataStorage:getSettingsDir() .. "/reader_menu_order.lua", true, true)
MenuOrderManager:reloadFromDisk("reader")
local repaired_reload = MenuOrderManager:loadOrder("reader", true)
assert_eq(count_menu_references(repaired_reload, "battery_statistics"), 1,
    "Loading repairs persisted Battery Statistics duplicates")
assert_eq(MenuOrderManager:getParentMenu("reader", "battery_statistics"), "tools",
    "Duplicate repair preserves the customized Tools destination")

-- Resetting More tools must restore stock children from every other parent,
-- not create the same duplicate again.
assert_true(MenuOrderManager:resetSubmenu("reader", "more_tools"),
    "More tools reset succeeds after Battery Statistics move")
assert_eq(count_menu_references(MenuOrderManager:loadOrder("reader"), "battery_statistics"), 1,
    "Reset More tools leaves Battery Statistics under exactly one parent")
assert_eq(MenuOrderManager:getParentMenu("reader", "battery_statistics"), "more_tools",
    "Reset More tools restores Battery Statistics to its stock parent")

-- -------------------------------------------------------------
-- Suite 6: Hiding / Disabling Items
-- -------------------------------------------------------------
print("\n--- Suite 6: Item Hiding & KOMenu:disabled ---")
assert_eq(MenuOrderManager:isItemHidden("reader", "calibre"), false, "calibre is initially visible")
MenuOrderManager:setItemHidden("reader", "calibre", true, "tools")
assert_true(MenuOrderManager:isItemHidden("reader", "calibre"), "calibre is hidden")

local disabled_list = MenuOrderManager:getDisabledItems("reader")
local found_in_disabled = false
for _, id in ipairs(disabled_list) do
    if id == "calibre" then found_in_disabled = true break end
end
assert_true(found_in_disabled, "calibre is in KOMenu:disabled")

-- Unhide
MenuOrderManager:setItemHidden("reader", "calibre", false, "tools")
assert_eq(MenuOrderManager:isItemHidden("reader", "calibre"), false, "calibre is unhidden")

local dynamic_search_item = "annas_archive_fixture"
-- Anchoring is implicit now: the materializer places hinted items without
-- persisting anything, so the reconciliation hook has nothing to do.
assert_eq(MenuOrderManager:reconcileMenuItems("reader", "search", { dynamic_search_item }),
    false, "Anchoring is implicit; the reconciliation hook stays a no-op")
MenuOrderManager:setItemHidden("reader", dynamic_search_item, true, "search")
assert_true(MenuOrderManager:isItemHidden("reader", dynamic_search_item),
    "Dynamic Search plugin is hidden")
assert_eq(MenuOrderManager:getParentMenu("reader", dynamic_search_item), nil,
    "Hidden dynamic plugin is removed from KOReader's active order")
assert_eq(MenuOrderManager:getHiddenItemParent("reader", dynamic_search_item), "search",
    "Hidden dynamic plugin retains its source across reloads")
assert_true(MenuOrderManager:saveOrder("reader"), "Persist hidden state to the intent store")
local persisted_intent = dofile(DataStorage:getSettingsDir() .. "/reorderingmenus_intent.lua")
assert_eq(persisted_intent.views.reader.hidden[dynamic_search_item].origin, "search",
    "Dynamic plugin source is persisted in the canonical intent store")
assert_true(list_contains(UIScreens:_getHiddenForMenu("reader", "search"), dynamic_search_item),
    "Hidden dynamic plugin remains manageable in the Search editor")
assert_true(MenuOrderManager:resetSubmenu("reader", "search"),
    "Reset Search succeeds with a hidden dynamic plugin")
assert_eq(MenuOrderManager:isItemHidden("reader", dynamic_search_item), false,
    "Reset Search unhides the dynamic plugin")
assert_eq(MenuOrderManager:getParentMenu("reader", dynamic_search_item), "search",
    "Reset Search restores the dynamic plugin to Search")
assert_eq(MenuOrderManager:getHiddenItemParent("reader", dynamic_search_item), nil,
    "Reset Search clears the saved hidden origin")

local late_search_item = "late_search_plugin_fixture"
-- Schema v3 / P1B: hinted newcomers are anchored IMPLICITLY - the stock
-- MenuSorter places sorting_hint orphans live at every build, so
-- reconciliation persists NOTHING for a first-contact contribution (a save
-- storm per registration revision is gone). The semantic contract stays
-- placement: the late plugin's sorting_hint is honored by projection.
-- NOTE: this call drives the MANAGER-level API with a partial registration
-- map, so the return value may legitimately be true (a registry diff can
-- tombstone other known ids); the contract under test is the PLACEMENT and
-- the absence of a machine-derived record for THIS id.
MenuOrderManager:reconcileRegisteredItems("reader", {
    [late_search_item] = { sorting_hint = "search" },
})
assert_eq(MenuOrderManager:getParentMenu("reader", late_search_item), "search",
    "Late Search plugin follows its hint instead of remaining a dangerous orphan")
-- No machine-derived record may leak into canonical state for the newcomer.
local MenuSchema = require("reorderingmenus_menu_schema")
local late_section = MenuOrderManager:stagedView("reader")
assert_eq(late_section.parent_override[late_search_item], nil,
    "no anchor record written for a hinted newcomer")

-- -------------------------------------------------------------
-- Suite 7: Separator Operations
-- -------------------------------------------------------------
print("\n--- Suite 7: Separator Insertion & Removal ---")
local before_count = #MenuOrderManager:getMenuItems("reader", "more_tools")
MenuOrderManager:insertSeparator("reader", "more_tools", 1)
assert_eq(#MenuOrderManager:getMenuItems("reader", "more_tools"), before_count + 1, "Separator inserted at index 1")
assert_eq(MenuOrderManager:getMenuItems("reader", "more_tools")[1], MenuOrderManager.SEPARATOR_ID, "Separator ID matched")

MenuOrderManager:removeSeparator("reader", "more_tools", 1)
assert_eq(#MenuOrderManager:getMenuItems("reader", "more_tools"), before_count, "Separator removed")

-- -------------------------------------------------------------
-- Suite 8: Layout Synchronization (Copy Layout)
-- -------------------------------------------------------------
print("\n--- Suite 8: Layout Synchronization ---")
MenuOrderManager:setItemHidden("reader", "qrclipboard", true, "tools")
MenuOrderManager:copyLayout("reader", "filemanager")
assert_true(MenuOrderManager:isItemHidden("filemanager", "qrclipboard"), "Disabled items synced to filemanager")
assert_eq(MenuOrderManager:getHiddenItemParent("filemanager", "qrclipboard"), "tools",
    "Hidden-item source metadata is synced with copied layouts")

-- -------------------------------------------------------------
-- Suite 9: Persistence, Serialization & MenuSorter Compatibility
-- -------------------------------------------------------------
print("\n--- Suite 9: File Persistence & MenuSorter Integration ---")
local save_ok, save_path = MenuOrderManager:saveOrder("reader")
assert_true(save_ok, "Saved reader configuration to: " .. tostring(save_path))
assert_true(MenuOrderManager:isCustomized("reader"), "Reader order is reported as customized")

-- Verify MenuSorter can parse and merge the saved file directly
local user_order = MenuSorter:readMSSettings("reader")
assert_true(type(user_order) == "table", "MenuSorter:readMSSettings returned valid table")
assert_true(#user_order["KOMenu:menu_buttons"] > 0, "MenuSorter read user menu buttons")

-- Test MenuSorter:mergeAndSort with mock item table
local mock_items = {
    ["KOMenu:menu_buttons"] = {},
    navi = { icon = "appbar.navigation" },
    typeset = { icon = "appbar.typeset" },
    setting = { icon = "appbar.settings" },
    tools = { icon = "appbar.tools" },
    search = { icon = "appbar.search" },
    filemanager = { icon = "appbar.filebrowser" },
    main = { icon = "appbar.menu" },
    bookmarks = { text = "Bookmarks" },
    frontlight = { text = "Frontlight" },
    calibre = { text = "Calibre" },
}

local sorted = MenuSorter:mergeAndSort("reader", mock_items, MenuOrderManager:getDefaultOrder("reader"))
assert_true(type(sorted) == "table" and #sorted > 0, "MenuSorter:mergeAndSort produced valid sorted menu table")

-- Reset
MenuOrderManager:resetOrder("reader")
assert_eq(MenuOrderManager:isCustomized("reader"), false, "Reader order reset to default")
MenuOrderManager:resetOrder("filemanager")
assert_eq(MenuOrderManager:isCustomized("filemanager"), false, "FileManager order reset to default")

-- -------------------------------------------------------------
-- Suite 10: Live Reload Cache Invalidation
-- -------------------------------------------------------------
print("\n--- Suite 10: Live Reload Handling ---")
local dummy_ui = {
    document = { file = "test.epub" },
    menu = {
        registered_widgets = {},
        tab_item_table = { "cached_table" },
    },
    registerModule = function(self, name, mod) self[name] = mod end,
}
MenuOrderManager:applyLiveReload(dummy_ui, "reader")
assert_true(dummy_ui.menu ~= nil, "new menu instantiated on live reload")
assert_true(dummy_ui.menu.tab_item_table ~= nil, "tab_item_table rebuilt on live reload")

print(string.format("\n======================================================="))
print(string.format("=== ALL TESTS COMPLETED: %d PASSED, %d FAILED      ===", passed, failed))
print("=======================================================")

if failed > 0 then
    os.exit(1)
end

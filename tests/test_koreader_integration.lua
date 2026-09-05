--[[--
End-to-End Integration Test for ReorderingMenus Plugin with KOReader Menu System
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"), "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")

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

local ReaderMenu = require("apps/reader/modules/readermenu")
local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local MenuOrderManager = require("lib.menuorder_manager")
local MenuSorter = require("ui/menusorter")
local UIScreens = require("lib.ui_screens")
local IntentStore = require("lib.intent_store")
local ReorderingMenus = require("main")

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

local function has_direct_child(menu_tree, menu_id, child_id)
    local menu = MenuSorter:findById(menu_tree, menu_id)
    local children = menu and (menu.sub_item_table or menu)
    for _, item in ipairs(children or {}) do
        if item.id == child_id then return true end
    end
    return false
end

print("===============================================================")
print("=== KOReader Reordering Menus Plugin - Integration Test     ===")
print("===============================================================")

-- -------------------------------------------------------------
-- Test 1: Full ReaderMenu Integration
-- -------------------------------------------------------------
print("\n--- Test 1: ReaderMenu Integration ---")

local mock_ui_reader = {
    document = {
        file = "test.epub",
        configurable = {},
    },
    doc_settings = {
        isTrue = function() return false end,
        makeFalse = function() end,
        makeTrue = function() end,
    },
    saveSettings = function() end,
    registerTouchZones = function() end,
    onClose = function() end,
    showFileManager = function() end,
}

local reader_menu = ReaderMenu:new{
    ui = mock_ui_reader,
}
mock_ui_reader.menu = reader_menu

-- Instantiate and register plugin
local plugin_reader = ReorderingMenus:new{
    ui = mock_ui_reader,
}
reader_menu:registerToMainMenu(plugin_reader)
plugin_reader:addToMainMenu(reader_menu.menu_items)
assert_true(reader_menu.menu_items.reordering_menus ~= nil, "reordering_menus is registered in reader menu_items")

-- Build menu
reader_menu:setUpdateItemTable()

assert_true(reader_menu.tab_item_table ~= nil, "tab_item_table built for reader")
assert_true(#reader_menu.tab_item_table >= 6, "reader tab_item_table contains standard tabs")

local function scan_tab(tbl)
    for _, item in ipairs(tbl) do
        if item.id == "reordering_menus" or item.text == "Reorder menus" then
            return true
        end
        if item.sub_item_table and scan_tab(item.sub_item_table) then
            return true
        end
    end
    return false
end

local found_in_reader = false
for _, tab in ipairs(reader_menu.tab_item_table) do
    if scan_tab(tab) then
        found_in_reader = true
        break
    end
end
assert_true(found_in_reader, "reordering_menus is accessible inside Reader menu hierarchy")

-- -------------------------------------------------------------
-- Test 2: Full FileManagerMenu Integration
-- -------------------------------------------------------------
print("\n--- Test 2: FileManagerMenu Integration ---")

local mock_ui_fm = {
    file_chooser = {
        show_hidden = false,
        show_unsupported = false,
        items_per_page_default = 14,
        collates = {
            filename = { text = "Filename", menu_order = 1 },
        },
        getCollate = function() return nil, "filename" end,
        refreshPath = function() end,
        toggleShowFilesMode = function() end,
    },
    registerTouchZones = function() end,
    onSetSortBy = function() end,
}

local fm_menu = FileManagerMenu:new{
    ui = mock_ui_fm,
}
mock_ui_fm.menu = fm_menu

local plugin_fm = ReorderingMenus:new{
    ui = mock_ui_fm,
}
fm_menu:registerToMainMenu(plugin_fm)
plugin_fm:addToMainMenu(fm_menu.menu_items)
assert_true(fm_menu.menu_items.reordering_menus ~= nil, "reordering_menus is registered in filemanager menu_items")

fm_menu:setUpdateItemTable()

assert_true(fm_menu.tab_item_table ~= nil, "tab_item_table built for filemanager")
assert_true(#fm_menu.tab_item_table >= 5, "filemanager tab_item_table contains standard tabs")

local found_in_fm = false
for _, tab in ipairs(fm_menu.tab_item_table) do
    if scan_tab(tab) then
        found_in_fm = true
        break
    end
end
assert_true(found_in_fm, "reordering_menus is accessible inside FileManager menu hierarchy")

-- -------------------------------------------------------------
-- Test 3: Customization and Live Reload in Reader
-- -------------------------------------------------------------
print("\n--- Test 3: Custom Order Application & Live Reload ---")

-- Modify menu: Put bookmarks before table_of_contents in navi
MenuOrderManager:moveItem("reader", "navi", 1, 2)
-- Hide bookmarks_browsing_mode
MenuOrderManager:setItemHidden("reader", "bookmark_browsing_mode", true, "navi")

-- Save order to disk
local saved_ok = MenuOrderManager:saveOrder("reader")
assert_true(saved_ok, "Saved custom reader menu order to disk")

-- Re-generate ReaderMenu
package.loaded["ui/elements/reader_menu_order"] = nil
local updated_reader_menu = ReaderMenu:new{
    ui = mock_ui_reader,
}
mock_ui_reader.menu = updated_reader_menu
updated_reader_menu:registerToMainMenu(plugin_reader)
updated_reader_menu:setUpdateItemTable()

-- Find navi tab
local navi_tab = updated_reader_menu.tab_item_table[1]
assert_true(navi_tab ~= nil, "Navi tab exists in updated reader menu")

-- Verify bookmark_browsing_mode is hidden (not present in navi tab)
local browsing_mode_found = false
for _, item in ipairs(navi_tab) do
    if item.id == "bookmark_browsing_mode" then
        browsing_mode_found = true
        break
    end
end
assert_eq(browsing_mode_found, false, "Hidden item (bookmark_browsing_mode) is omitted from menu")

-- -------------------------------------------------------------
-- Test 4: Moving Complete Submenus in Live Reader/FileManager Menus
-- -------------------------------------------------------------
print("\n--- Test 4: Live Cross-Menu Submenu Movement ---")

assert_true(MenuOrderManager:moveItemToMenu("reader", "more_tools", "tools", "setting", 1),
    "Reader More tools moved from Tools to Settings")
assert_true(MenuOrderManager:saveOrder("reader"), "Saved moved Reader submenu")
package.loaded["ui/elements/reader_menu_order"] = nil
local moved_reader_menu = ReaderMenu:new{ ui = mock_ui_reader }
mock_ui_reader.menu = moved_reader_menu
moved_reader_menu:registerToMainMenu(plugin_reader)
moved_reader_menu:setUpdateItemTable()
assert_true(has_direct_child(moved_reader_menu.tab_item_table, "setting", "more_tools"),
    "Reader live menu renders More tools under Settings")
assert_eq(has_direct_child(moved_reader_menu.tab_item_table, "tools", "more_tools"), false,
    "Reader live menu removes More tools from its old parent")
assert_true(has_direct_child(moved_reader_menu.tab_item_table, "more_tools", "plugin_management"),
    "Reader moved submenu retains its registered children")

assert_true(MenuOrderManager:moveItemToMenu("filemanager", "more_tools", "tools", "setting", 1),
    "Normal-view More tools moved from Tools to Settings")
assert_true(MenuOrderManager:saveOrder("filemanager"), "Saved moved Normal-view submenu")
package.loaded["ui/elements/filemanager_menu_order"] = nil
local moved_fm_menu = FileManagerMenu:new{ ui = mock_ui_fm }
mock_ui_fm.menu = moved_fm_menu
moved_fm_menu:registerToMainMenu(plugin_fm)
moved_fm_menu:setUpdateItemTable()
assert_true(has_direct_child(moved_fm_menu.tab_item_table, "setting", "more_tools"),
    "Normal live menu renders More tools under Settings")
assert_eq(has_direct_child(moved_fm_menu.tab_item_table, "tools", "more_tools"), false,
    "Normal live menu removes More tools from its old parent")
assert_true(has_direct_child(moved_fm_menu.tab_item_table, "more_tools", "plugin_management"),
    "Normal moved submenu retains its registered children")

-- -------------------------------------------------------------
-- Test 5: Dynamic Search Plugins + Hidden Top Tab
-- -------------------------------------------------------------
print("\n--- Test 5: Hidden Dynamic Plugins and Top-Tab Stability ---")

MenuOrderManager:resetOrder("filemanager")
local anna_fixture = {
    name = "annas_archive_fixture",
    addToMainMenu = function(_, menu_items)
        menu_items.annas_archive_fixture = {
            text = "Anna's Archive fixture",
            sorting_hint = "search",
        }
    end,
}
mock_ui_fm.menu:registerToMainMenu(anna_fixture)
-- Anchoring is implicit now: first-contact hinted items are NEVER pinned
-- (P1B); the item follows its sorting hint live. The reconcile return value
-- may legitimately be true (unrelated removal tombstones from earlier
-- registration revisions in this process), so assert on THIS id's records.
assert_eq(IntentStore.view("filemanager").parent_override.annas_archive_fixture,
    nil, "Hinted plugin needs no persisted anchor (materializer places it)")
UIScreens:reconcileRegisteredItems(plugin_fm, "filemanager", true)
assert_eq(IntentStore.view("filemanager").parent_override.annas_archive_fixture,
    nil, "Reconciliation persisted no anchor for the hinted plugin")
assert_eq(MenuOrderManager:getParentMenu("filemanager", "annas_archive_fixture"),
    "search", "Hinted plugin materializes under its hint target")
MenuOrderManager:setItemHidden("filemanager", "annas_archive_fixture", true, "search")
assert_eq(MenuOrderManager:getHiddenItemParent("filemanager", "annas_archive_fixture"), "search",
    "Hidden dynamic plugin retains Search as its source")
assert_true(MenuOrderManager:resetSubmenu("filemanager", "search"),
    "Reset Search restores the hidden dynamic plugin")
assert_eq(MenuOrderManager:getParentMenu("filemanager", "annas_archive_fixture"), "search",
    "Dynamic plugin is present in Search after reset")

MenuOrderManager:setTabHidden("filemanager", "search", true)
assert_true(MenuOrderManager:saveOrder("filemanager"), "Saved layout with Search hidden")

-- Reproduce installing another Search plugin only after the Search tab has
-- already been hidden. The lifecycle reconciliation must consume this item in
-- Search's stored order before KOReader reaches orphan handling; otherwise its
-- sorting_hint points at a tab that is not in the rendered tree and crashes.
local late_search_fixture = {
    name = "late_search_fixture",
    addToMainMenu = function(_, menu_items)
        menu_items.late_search_fixture = {
            text = "Late Search fixture",
            sorting_hint = "search",
        }
    end,
}
mock_ui_fm.menu:registerToMainMenu(late_search_fixture)
-- P1B: onShowFileManager never existed as a KOReader event (no emitter in
-- the bundled tree); a registration revision is reconciled exactly like the
-- plugin's init/nextTick path does.
UIScreens:reconcileRegisteredItems(plugin_fm, "filemanager", true)
assert_eq(MenuOrderManager:getParentMenu("filemanager", "late_search_fixture"), "search",
    "New plugin installed after Search was hidden is anchored safely")

package.loaded["ui/elements/filemanager_menu_order"] = nil
local hidden_search_menu = FileManagerMenu:new{ ui = mock_ui_fm }
mock_ui_fm.menu = hidden_search_menu
hidden_search_menu:registerToMainMenu(plugin_fm)
hidden_search_menu:registerToMainMenu(anna_fixture)
hidden_search_menu:registerToMainMenu(late_search_fixture)
local hidden_search_ok, hidden_search_err = pcall(hidden_search_menu.setUpdateItemTable, hidden_search_menu)
assert_true(hidden_search_ok, "Top menu still builds with Search hidden: " .. tostring(hidden_search_err))
assert_true(type(hidden_search_menu.tab_item_table) == "table" and #hidden_search_menu.tab_item_table > 0,
    "Other top menus remain available after hiding Search")
assert_eq(MenuSorter:findById(hidden_search_menu.tab_item_table, "search"), nil,
    "Search tab itself is hidden without breaking the menu")

-- Cleanup / reset
MenuOrderManager:resetOrder("reader")
MenuOrderManager:resetOrder("filemanager")
assert_eq(MenuOrderManager:isCustomized("reader"), false, "Cleaned up test settings")

print(string.format("\n==============================================================="))
print(string.format("=== INTEGRATION TESTS COMPLETED: %d PASSED, %d FAILED       ===", passed, failed))
print("===============================================================")

if failed > 0 then
    os.exit(1)
end

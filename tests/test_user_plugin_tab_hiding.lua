--[[--
Regression tests for user-plugin menu items interacting with tab hiding.

Covers the reported failure mode: a user plugin registers an extra menu entry
with a sorting_hint (e.g. Anna's Archive targeting the Search tab). When such an
item is not anchored in the saved order file ("still underlying") and its anchor
tab is hidden, KOReader's MenuSorter used to crash on every launch
(menusorter.lua: indexing a nil sorting_hint_menu), leaving the top menu
permanently unopenable. Also covers the editor losing track of plugin items
that were restored by a reset while the live menu snapshot was stale.
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

local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local UIManager = require("ui/uimanager")
local MenuSorter = require("ui/menusorter")
local _ = require("gettext")

require("main") -- installs the sorting-hint safety guard exactly like a launch

local view = "filemanager"
local settings_dir = DataStorage:getSettingsDir()
local ORDER_FILE = settings_dir .. "/" .. view .. "_menu_order.lua"
local STATE_FILE = settings_dir .. "/reorderingmenus_state.lua"

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or ""))
    else
        failed = failed + 1
        io.stdout:flush()
        print("  [FAIL] " .. (msg or "") ..
            string.format(" -> expected %s, got %s", tostring(expected), tostring(actual)))
    end
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end

local function in_list(list, needle)
    for _, id in ipairs(list or {}) do
        if id == needle then return true end
    end
    return false
end

local function live_children(tree, menu_id)
    local node = MenuSorter:findById(tree, menu_id)
    if not node then return nil end
    local ids = {}
    for _, c in ipairs(node.sub_item_table or node) do
        table.insert(ids, tostring(c.id))
    end
    return ids
end

-- A stand-in for Anna's Archive: registers only where there is no view (the
-- file manager) and anchors itself with a sorting hint.
local function make_stub(item_id, hint)
    local stub = {
        ui = nil,
        addToMainMenu = function(self, menu_items)
            if not self.ui.view then
                menu_items[item_id] = {
                    text = string.format(_("Stub %s"), item_id),
                    sorting_hint = hint,
                    callback = function() end,
                }
            end
        end,
    }
    return stub
end

local function make_mock_ui()
    return {
        file_chooser = {
            show_hidden = false,
            show_unsupported = false,
            items_per_page_default = 14,
            collates = { filename = { text = _("Filename"), menu_order = 1 } },
            getCollate = function() return nil, "filename" end,
            refreshPath = function() end,
            toggleShowFilesMode = function() end,
        },
        registerTouchZones = function() end,
        onSetSortBy = function() end,
        registerModule = function(self, name, mod) self[name] = mod end,
    }
end

local MenuOrderManager = require("lib.menuorder_manager")
local UIScreens = require("lib.ui_screens")

local mock_ui_fm = make_mock_ui()

local function wipe_persisted_state()
    os.remove(ORDER_FILE)
    os.remove(STATE_FILE)
    os.remove(DataStorage:getSettingsDir() .. "/reorderingmenus_intent.lua")
    os.remove(DataStorage:getSettingsDir() .. "/reorderingmenus_materialization.lua")
    pcall(function()
        require("lib.intent_store").load(true)
        require("lib.native_writer")._resetCaches()
    end)
    MenuOrderManager:dropSessionState(view)
end

local function drop_session_caches(manager)
    package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
    manager.orders[view] = nil
    manager.default_orders[view] = nil
    manager.recent_moves[view] = {}
end

-- Simulates a KOReader relaunch: every module-level cache is discarded.
local function simulate_restart()
    package.loaded["lib.menuorder_manager"] = nil
    package.loaded["lib.ui_screens"] = nil
    package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
    collectgarbage("collect")
end

local function new_menu(stubs)
    local menu = FileManagerMenu:new{ ui = mock_ui_fm }
    mock_ui_fm.menu = menu
    for _, stub in ipairs(stubs or {}) do
        stub.ui = mock_ui_fm
        menu.registered_widgets[stub.item_id or "stub"] = stub
    end
    return menu
end

local function rebuild_after_restart(stubs)
    simulate_restart()
    MenuOrderManager = require("lib.menuorder_manager")
    UIScreens = require("lib.ui_screens")
    drop_session_caches(MenuOrderManager)
    return new_menu(stubs)
end

-- Editor row computation, mirroring showItemSortWidget's data assembly.
local function editor_rows(menu_id)
    local configured_items = MenuOrderManager:getMenuItems(view, menu_id)
    local hidden_for_menu = UIScreens:_getHiddenForMenu(view, menu_id)
    local live_ids, _, has_live = UIScreens:_getLiveMenuItems({ ui = mock_ui_fm }, menu_id)
    local merged = UIScreens:_mergeConfiguredAndLiveItems(
        configured_items, hidden_for_menu, live_ids, has_live,
        MenuOrderManager:getRecentMoves(view), menu_id)
    return merged, hidden_for_menu
end

local function close_all_windows()
    while #(UIManager._window_stack or {}) > 0 do
        local entry = UIManager._window_stack[#UIManager._window_stack]
        local w = entry and (entry.widget or entry)
        UIManager:close(w)
    end
end

local function top_sort_widget()
    for i = #UIManager._window_stack, 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w and w.item_table and w._populateItems and w.marked ~= nil then
            return w
        end
    end
end

-- Removes every occurrence of item_id from every list of the working order.
local function strip_from_saved_order(item_id)
    local order = MenuOrderManager:loadOrder(view)
    for __, list in pairs(order) do
        if type(list) == "table" then
            for i = #list, 1, -1 do
                if list[i] == item_id then table.remove(list, i) end
            end
        end
    end
    MenuOrderManager.orders[view] = order
    MenuOrderManager:saveOrder(view)
end

print("===============================================================")
print("=== User plugin items vs. hidden tabs                       ===")
print("===============================================================")

wipe_persisted_state()
drop_session_caches(MenuOrderManager)

local annas = make_stub("zlibrary_main", "search")
do
    print("\n--- Baseline: plugin item is visible under Search ---")
    local fm = new_menu({ annas })
    fm:setUpdateItemTable()
    assert_true(in_list(live_children(fm.tab_item_table, "search"), "zlibrary_main"),
        "Unanchored plugin item renders under its hinted Search tab")
end

-- -------------------------------------------------------------------------
print("\n--- Bug 1: hiding the anchor tab must not break the menu ---")
do
    -- Leftover state from the report: the plugin item is nowhere in the saved
    -- order (it only ever attached itself through its sorting hint).
    strip_from_saved_order("zlibrary_main")
    assert_eq(MenuOrderManager:getParentMenu(view, "zlibrary_main"), nil,
        "Plugin item is absent from the saved order")
    assert_eq(MenuOrderManager:isItemHidden(view, "zlibrary_main"), false,
        "Plugin item is not disabled either")

    MenuOrderManager:setTabHidden(view, "search", true)
    MenuOrderManager:saveOrder(view)

    local fm = rebuild_after_restart({ annas })
    local ok, err = pcall(fm.setUpdateItemTable, fm)
    assert_true(ok, "Top menu builds with Search hidden and an unanchored hint item: "
        .. tostring(err))
    assert_eq(MenuSorter:findById(fm.tab_item_table, "search"), nil,
        "Search tab stays hidden after the restart")
    for _, tab_id in ipairs({ "filemanager_settings", "setting", "tools", "main" }) do
        assert_true(MenuSorter:findById(fm.tab_item_table, tab_id) ~= nil,
            "Tab " .. tab_id .. " survives the hidden Search tab")
    end
    assert_eq(MenuSorter:findById(fm.tab_item_table, "zlibrary_main"), nil,
        "The hinted item does not leak into any visible menu")
    close_all_windows()

    -- Unhiding the tab brings the plugin item back.
    MenuOrderManager:setTabHidden(view, "search", false)
    MenuOrderManager:saveOrder(view)
    fm = rebuild_after_restart({ annas })
    local ok2, err2 = pcall(fm.setUpdateItemTable, fm)
    assert_true(ok2, "Menu builds again after unhiding Search: " .. tostring(err2))
    assert_true(in_list(live_children(fm.tab_item_table, "search"), "zlibrary_main"),
        "Unhidden Search shows the plugin item again")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- Bug 1b: hint to an unknown menu falls back gracefully ---")
do
    wipe_persisted_state()
    drop_session_caches(MenuOrderManager)
    local lost_hint = make_stub("lost_hint_item", "nonexistent_menu_xyz")
    local fm = new_menu({ lost_hint })
    local ok, err = pcall(fm.setUpdateItemTable, fm)
    assert_true(ok, "Unknown sorting_hint target does not crash the build: " .. tostring(err))
    assert_true(MenuSorter:findById(fm.tab_item_table, "lost_hint_item") ~= nil,
        "Item with unknown hint target is still rendered")
    local first_tab_children = {}
    for _, c in ipairs(fm.tab_item_table[1] or {}) do
        table.insert(first_tab_children, tostring(c.id))
    end
    assert_true(in_list(first_tab_children, "lost_hint_item"),
        "Item with unknown hint target lands in the first menu (stock fallback)")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- Bug 1c: anchored plugin item hides together with its tab ---")
do
    wipe_persisted_state()
    drop_session_caches(MenuOrderManager)
    local fm = new_menu({ annas })
    -- Anchor the item the way lifecycle reconciliation does.
    local order = MenuOrderManager:loadOrder(view)
    table.insert(order["search"], "zlibrary_main")
    MenuOrderManager.orders[view] = order
    MenuOrderManager:saveOrder(view)

    MenuOrderManager:setTabHidden(view, "search", true)
    MenuOrderManager:saveOrder(view)
    fm = rebuild_after_restart({ annas })
    local ok, err = pcall(fm.setUpdateItemTable, fm)
    assert_true(ok, "Anchored plugin item keeps the menu buildable: " .. tostring(err))
    assert_eq(MenuSorter:findById(fm.tab_item_table, "zlibrary_main"), nil,
        "Anchored plugin item is hidden along with its tab")
    close_all_windows()

    MenuOrderManager:setTabHidden(view, "search", false)
    MenuOrderManager:saveOrder(view)
    fm = rebuild_after_restart({ annas })
    fm:setUpdateItemTable()
    assert_true(in_list(live_children(fm.tab_item_table, "search"), "zlibrary_main"),
        "Anchored plugin item returns with its tab")
    close_all_windows()

    -- An item hinted at a hidden target but deliberately moved elsewhere must
    -- stay in its new location.
    MenuOrderManager:moveItemToMenu(view, "zlibrary_main", "search", "tools")
    MenuOrderManager:setTabHidden(view, "search", true)
    MenuOrderManager:saveOrder(view)
    fm = rebuild_after_restart({ annas })
    local ok3, err3 = pcall(fm.setUpdateItemTable, fm)
    assert_true(ok3, "Moved-out item plus hidden old tab builds fine: " .. tostring(err3))
    assert_true(in_list(live_children(fm.tab_item_table, "tools"), "zlibrary_main"),
        "Item moved out of Search stays in Tools when Search is hidden")
    close_all_windows()
    MenuOrderManager:setTabHidden(view, "search", false)
end

-- -------------------------------------------------------------------------
print("\n--- Bug 2: reset restores a hidden plugin item to the editor ---")
do
    wipe_persisted_state()
    drop_session_caches(MenuOrderManager)
    local fm = new_menu({ annas })
    fm:setUpdateItemTable()

    -- Hide the plugin item from Search, exactly like the editor checkbox does.
    MenuOrderManager:setItemHidden(view, "zlibrary_main", true, "search")
    MenuOrderManager:saveOrder(view)
    MenuOrderManager:applyLiveReload(mock_ui_fm, view)
    assert_eq(in_list(live_children(mock_ui_fm.menu.tab_item_table, "search"),
        "zlibrary_main"), false, "Hidden plugin item leaves the live menu")

    -- Resetting Search restores the item to the configured order...
    assert_true(MenuOrderManager:resetSubmenu(view, "search"),
        "Reset Search succeeds with a hidden dynamic plugin item")
    assert_eq(MenuOrderManager:getParentMenu(view, "zlibrary_main"), "search",
        "Reset puts the plugin item back into Search")
    assert_eq(MenuOrderManager:isItemHidden(view, "zlibrary_main"), false,
        "Reset clears the hidden state of the plugin item")

    -- ...and the editor must list it again even though the live tree snapshot
    -- predates the reset and does not know the item yet.
    local rows, hidden_rows = editor_rows("search")
    assert_true(in_list(rows, "zlibrary_main"),
        "Editor lists the restored plugin item despite the stale live snapshot")
    assert_eq(in_list(hidden_rows, "zlibrary_main"), false,
        "Restored plugin item is not presented as hidden")

    -- The real editor widget shows the row too.
    UIScreens:showItemSortWidget({ ui = mock_ui_fm }, view, "search")
    local editor = top_sort_widget()
    assert_true(editor ~= nil, "Search editor opens after the reset")
    local found = false
    for _, row in ipairs(editor.item_table) do
        if row.item_id == "zlibrary_main" then found = true end
    end
    assert_true(found, "Opened Search editor shows the plugin item row")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- Editor merge keeps stale-configured items manageable ---")
do
    local merged, unavailable = UIScreens:_mergeConfiguredAndLiveItems(
        { "ghost_item", "known_item" }, {}, { "known_item" }, true, {}, "search")
    assert_true(in_list(merged, "ghost_item"),
        "Configured item missing from the live snapshot remains editable")
    assert_true(in_list(unavailable, "ghost_item"),
        "Missing item is still flagged unavailable so saves preserve it")
    assert_true(in_list(merged, "known_item"), "Live item stays in place")
end

print("\n--- Items moved away do not reappear in the source editor ---")
do
    MenuOrderManager.recent_moves[view] = MenuOrderManager.recent_moves[view] or {}
    MenuOrderManager.recent_moves[view]["moved_item"] = { from = "search", to = "tools" }
    local source_rows = UIScreens:_mergeConfiguredAndLiveItems(
        { "moved_item", "known_item" }, {}, { "known_item" }, true,
        MenuOrderManager:getRecentMoves(view), "search")
    assert_eq(in_list(source_rows, "moved_item"), false,
        "Source editor does not show an item moved elsewhere")
    local dest_rows = UIScreens:_mergeConfiguredAndLiveItems(
        { "moved_item" }, {}, {}, true,
        MenuOrderManager:getRecentMoves(view), "tools")
    assert_true(in_list(dest_rows, "moved_item"),
        "Destination editor gains the moved item via the move record")
    MenuOrderManager.recent_moves[view] = {}
end

-- -------------------------------------------------------------------------
print("\n--- Failed live reload keeps the previous menu usable ---")
do
    local FMClass = require("apps/filemanager/filemanagermenu")
    local original_build = FMClass.setUpdateItemTable
    FMClass.setUpdateItemTable = function()
        error("simulated rebuild failure")
    end
    local menu_before = mock_ui_fm.menu
    local ok, err = pcall(MenuOrderManager.applyLiveReload, MenuOrderManager, mock_ui_fm, view)
    FMClass.setUpdateItemTable = original_build
    assert_true(ok, "applyLiveReload survives a failing rebuild: " .. tostring(err))
    assert_eq(mock_ui_fm.menu, menu_before,
        "Failed rebuild keeps the previous menu object in place")
    assert_true(type(mock_ui_fm.menu.tab_item_table) == "table",
        "Kept menu still owns a usable menu tree")
end

-- -------------------------------------------------------------------------
print("\n--- Full reported scenario, start to finish ---")
do
    wipe_persisted_state()
    drop_session_caches(MenuOrderManager)
    local fm = new_menu({ annas })
    fm:setUpdateItemTable()
    assert_true(in_list(live_children(fm.tab_item_table, "search"), "zlibrary_main"),
        "story: plugin item visible on fresh install")
    close_all_windows()

    -- Hide the item once.
    MenuOrderManager:setItemHidden(view, "zlibrary_main", true, "search")
    MenuOrderManager:saveOrder(view)
    MenuOrderManager:applyLiveReload(mock_ui_fm, view)
    assert_eq(in_list(live_children(mock_ui_fm.menu.tab_item_table, "search"),
        "zlibrary_main"), false, "story: hidden item leaves the menu")

    -- Reset ALL menus, like the reporter tried.
    MenuOrderManager:resetOrder(view)
    MenuOrderManager:applyLiveReload(mock_ui_fm, view)
    local rows = editor_rows("search")
    assert_true(in_list(rows, "zlibrary_main"),
        "story: after Reset all, the editor offers the plugin item again")
    assert_true(in_list(live_children(mock_ui_fm.menu.tab_item_table, "search"),
        "zlibrary_main"), "story: after Reset all, the menu shows the item again")

    -- Now remove the whole Search tab. Nothing re-anchored the item (no save
    -- happened since the reset), mirroring the reporter's leftover state.
    MenuOrderManager:setTabHidden(view, "search", true)
    MenuOrderManager:saveOrder(view)
    fm = rebuild_after_restart({ annas })
    local ok, err = pcall(fm.setUpdateItemTable, fm)
    assert_true(ok, "story: top menu opens after hiding Search: " .. tostring(err))
    assert_eq(MenuSorter:findById(fm.tab_item_table, "search"), nil,
        "story: Search stays hidden across the restart")
    assert_eq(MenuSorter:findById(fm.tab_item_table, "zlibrary_main"), nil,
        "story: plugin item does not leak anywhere")
    close_all_windows()

    -- Recovery without deleting any settings: unhide the tab.
    MenuOrderManager:setTabHidden(view, "search", false)
    MenuOrderManager:saveOrder(view)
    fm = rebuild_after_restart({ annas })
    fm:setUpdateItemTable()
    assert_true(in_list(live_children(fm.tab_item_table, "search"), "zlibrary_main"),
        "story: unhiding Search fully restores the original state")
    close_all_windows()
end

wipe_persisted_state()
close_all_windows()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

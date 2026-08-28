--[[--
Plugin removal lifecycle.

Installing a plugin anchors its menu entry in the saved configuration; removing
(uninstalling or disabling) it must degrade gracefully:

  - The stale entry stays persisted at its configured position, so
    reinstalling restores the item exactly where it was - single parent,
    never duplicated.
  - Removing a plugin never produces "NEW: ..." orphan rows and never breaks
    the top menu build.
  - An item hidden before removal stays hidden with its origin recorded.
  - A moved-before-removal entry keeps its customized parent.
  - Editors no longer list provider-less entries at all (they cannot render);
    after a reinstall they reappear as normal rows.
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

local NEW_PREFIX = _("NEW: ")

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

local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local UIScreens = require("reorderingmenus_ui_screens")

local mock_ui_fm = {
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

local function make_stub(item_id, hint, with_children)
    return {
        ui = nil,
        addToMainMenu = function(self, menu_items)
            if not self.ui.view then
                local entry = {
                    text = string.format(_("Stub %s"), item_id),
                    sorting_hint = hint,
                    callback = function() end,
                }
                if with_children then
                    entry.sub_item_table = {
                        { text = _("Child one"), callback = function() end },
                    }
                end
                menu_items[item_id] = entry
            end
        end,
    }
end

local function wipe_state()
    os.remove(ORDER_FILE)
    os.remove(STATE_FILE)
    -- Round-3 persistence files: without these, leftovers from a previous
    -- suite in this process (or a prior run's quarantines) leak "NEW:"
    -- orphans and stale hides into T1/T2/T3.
    os.remove(DataStorage:getSettingsDir() .. "/reorderingmenus_intent.lua")
    os.remove(DataStorage:getSettingsDir() .. "/reorderingmenus_materialization.lua")
    pcall(function()
        require("reorderingmenus_intent_store").load(true)
        require("reorderingmenus_native_writer")._resetCaches()
    end)
    MenuOrderManager:dropSessionState(view)
    package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
    MenuOrderManager.orders[view] = nil
    MenuOrderManager.default_orders[view] = nil
    MenuOrderManager.recent_moves[view] = {}
end

local function drop_session_caches()
    package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
    MenuOrderManager.orders[view] = nil
    MenuOrderManager.default_orders[view] = nil
    MenuOrderManager.recent_moves[view] = {}
end

local function close_all_windows()
    while #(UIManager._window_stack or {}) > 0 do
        local entry = UIManager._window_stack[#UIManager._window_stack]
        local w = entry and (entry.widget or entry)
        if w and w.onClose then w:onClose() else UIManager:close(w) end
    end
end

-- Launch a session. Stubs listed in `attached` are registered; removed plugins
-- simply stay out of that list.
local function launch(attached)
    local menu = FileManagerMenu:new{ ui = mock_ui_fm }
    mock_ui_fm.menu = menu
    for i, stub in ipairs(attached or {}) do
        stub.ui = mock_ui_fm
        menu.registered_widgets["stub_" .. i .. "_" .. tostring(stub.itemId)] = stub
    end
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, true)
    menu:setUpdateItemTable()
    return menu
end

local function count_new_prefix(tree)
    local n = 0
    local function walk(node)
        for _, entry in ipairs(node) do
            if type(entry) == "table" then
                if type(entry.text) == "string"
                        and entry.text:sub(1, #NEW_PREFIX) == NEW_PREFIX then
                    n = n + 1
                end
                if type(entry.sub_item_table) == "table" then
                    walk(entry.sub_item_table)
                elseif #entry > 0 then
                    walk(entry)
                end
            end
        end
    end
    walk(tree)
    return n
end

local function configured_parents(item_id)
    local order = MenuOrderManager:loadOrder(view)
    local parents = {}
    for menu_id, list in pairs(order) do
        if menu_id ~= "KOMenu:disabled" and type(list) == "table" then
            for _, id in ipairs(list) do
                if id == item_id then table.insert(parents, menu_id) end
            end
        end
    end
    return parents
end

local function live_children(menu, menu_id)
    if type(menu.tab_item_table) ~= "table" then return nil end
    local node = MenuSorter:findById(menu.tab_item_table, menu_id)
    if not node then return nil end
    local ids = {}
    for _, c in ipairs(node.sub_item_table or node) do
        table.insert(ids, tostring(c.id))
    end
    return ids
end

local function open_editor(menu_id)
    UIScreens:showItemSortWidget({ ui = mock_ui_fm }, view, menu_id)
    for i = #UIManager._window_stack, 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w and w.item_table and w._populateItems and w.marked ~= nil then
            return w
        end
    end
end

local function row_for(editor, item_id)
    for _, row in ipairs(editor.item_table) do
        if row.item_id == item_id then return row end
    end
end

print("===============================================================")
print("=== Plugin removal lifecycle                                ===")
print("===============================================================")

-- -------------------------------------------------------------------------
print("\n--- T1: install, configure, remove, restart ---")
do
    wipe_state()
    local stub = make_stub("removable_plain", "more_tools")
    launch({ stub })
    close_all_windows()

    -- Removal: relaunch without re-registering the stub.
    drop_session_caches()
    local menu = launch({})
    assert_eq(MenuOrderManager:getParentMenu(view, "removable_plain"), nil,
        "T1: removed untouched plugin row is dormant/not projected")
    assert_eq(count_new_prefix(menu.tab_item_table), 0,
        "T1: removal produces no NEW: orphans")
    assert_true(type(menu.tab_item_table) == "table" and #menu.tab_item_table > 0,
        "T1: top menu still builds without the provider")

    -- Editor must not list the provider-less entry anymore.
    local editor = open_editor("more_tools")
    local ghost_row = row_for(editor, "removable_plain")
    assert_eq(ghost_row, nil,
        "T1: removed plugin's entry is not offered as a working row")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- T2: reinstalling after removal restores the position ---")
do
    wipe_state()
    local stub = make_stub("removable_plain", "more_tools")
    launch({ stub })
    close_all_windows()
    drop_session_caches()
    launch({}) -- removed
    close_all_windows()

    local menu = launch({ stub }) -- reinstalled
    local children = live_children(menu, "more_tools") or {}
    local found = false
    for _, id in ipairs(children) do
        if id == "removable_plain" then found = true end
    end
    assert_true(found, "T2: reinstall renders the item again under More tools")
    local parents = configured_parents("removable_plain")
    assert_eq(#parents, 1, "T2: reinstall does not duplicate the entry")
    assert_eq(parents[1], "more_tools", "T2: reinstall keeps the previous position")
    assert_eq(count_new_prefix(menu.tab_item_table), 0, "T2: no NEW: rows after reinstall")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- T3: removal of an item that was hidden ---")
do
    wipe_state()
    local stub = make_stub("removed_while_hidden", "search")
    launch({ stub })
    close_all_windows()
    MenuOrderManager:setItemHidden(view, "removed_while_hidden", true, "search")
    MenuOrderManager:saveOrder(view)

    drop_session_caches()
    local menu = launch({}) -- removed while hidden
    assert_true(MenuOrderManager:isItemHidden(view, "removed_while_hidden"),
        "T3: hidden state survives the provider's removal")
    assert_eq(MenuOrderManager:getHiddenItemParent(view, "removed_while_hidden"), "search",
        "T3: origin retained so a later unhide lands correctly")
    assert_eq(count_new_prefix(menu.tab_item_table), 0, "T3: no NEW: orphans")

    -- Reinstall: prior choice respected until the user unhides.
    menu = launch({ stub })
    assert_true(MenuOrderManager:isItemHidden(view, "removed_while_hidden"),
        "T3: reinstalled plugin respects the earlier hide decision")
    MenuOrderManager:setItemHidden(view, "removed_while_hidden", false, "search")
    MenuOrderManager:saveOrder(view)
    drop_session_caches()
    menu = launch({ stub })
    local children = live_children(menu, "search") or {}
    local found = false
    for _, id in ipairs(children) do
        if id == "removed_while_hidden" then found = true end
    end
    assert_true(found, "T3: unhiding after reinstall renders the item under Search")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- T4: removal of an item that was moved to another menu ---")
do
    wipe_state()
    local stub = make_stub("removed_after_move", "tools")
    launch({ stub })
    close_all_windows()
    MenuOrderManager:moveItemToMenu(view, "removed_after_move", "tools", "setting")
    MenuOrderManager:saveOrder(view)

    drop_session_caches()
    local menu = launch({}) -- removed after moving
    -- Regression (suite V): a SAVE while the provider is absent used to
    -- minimize the dormant placement record away (it is graph-invisible),
    -- so a later reinstall lost the moved spot. Dormant intent must survive
    -- arbitrary saves during the absence.
    assert_true(MenuOrderManager:saveOrder(view),
        "T4: save while provider absent succeeds")
    local parents = configured_parents("removed_after_move")
    assert_eq(#parents, 1, "T4: single parent kept after removal")
    assert_eq(parents[1], "setting", "T4: moved location kept in the saved file")
    assert_eq(count_new_prefix(menu.tab_item_table), 0, "T4: no NEW: orphans")

    menu = launch({ stub }) -- reinstalled
    local children = live_children(menu, "setting") or {}
    local found = false
    for _, id in ipairs(children) do
        if id == "removed_after_move" then found = true end
    end
    assert_true(found, "T4: reinstall renders the item at its moved destination")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- T5: removal of a submenu-style plugin ---")
do
    wipe_state()
    local stub = make_stub("removed_submenu_plugin", "more_tools", true)
    launch({ stub })
    close_all_windows()

    drop_session_caches()
    local menu = launch({}) -- removed
    assert_true(type(menu.tab_item_table) == "table" and #menu.tab_item_table > 0,
        "T5: menu builds after removing a submenu-style plugin")
    assert_eq(MenuSorter:findById(menu.tab_item_table, "removed_submenu_plugin"), nil,
        "T5: submenu entry absent from the rebuilt menu")
    assert_eq(count_new_prefix(menu.tab_item_table), 0,
        "T5: submenu removal leaves no orphans")
    assert_eq(MenuOrderManager:getParentMenu(view, "removed_submenu_plugin"), nil,
        "T5: removed untouched plugin row is dormant/not projected")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- T6: removal while the anchor tab is hidden ---")
do
    wipe_state()
    local stub = make_stub("removed_tab_item", "search")
    launch({ stub })
    close_all_windows()
    MenuOrderManager:setTabHidden(view, "search", true)
    MenuOrderManager:saveOrder(view)

    drop_session_caches()
    local menu = launch({}) -- plugin removed AND tab hidden
    assert_true(type(menu.tab_item_table) == "table" and #menu.tab_item_table > 0,
        "T6: menu builds with the anchor tab hidden and plugin gone")
    assert_eq(MenuSorter:findById(menu.tab_item_table, "search"), nil,
        "T6: anchor tab stays hidden")
    assert_eq(count_new_prefix(menu.tab_item_table), 0, "T6: no NEW: leakage")

    -- Unhide the tab: the stale entry is silently skipped, nothing appears.
    MenuOrderManager:setTabHidden(view, "search", false)
    MenuOrderManager:saveOrder(view)
    drop_session_caches()
    menu = launch({})
    local children = live_children(menu, "search") or {}
    local found = false
    for _, id in ipairs(children) do
        if id == "removed_tab_item" then found = true end
    end
    assert_eq(found, false, "T6: stale entry does not render after tab unhide")
    assert_eq(count_new_prefix(menu.tab_item_table), 0, "T6: still no orphans")
    close_all_windows()
end

wipe_state()
close_all_windows()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

--[[--
Extensive lifecycle matrix for menu entries that appear after configuration.

The classic KOReader failure mode this suite locks down: entries added after a
configuration was saved - newly installed plugins AND brand-new core entries
shipped by a KOReader update - fall back to MenuSorter's orphan handling and
surface as "NEW: ..." rows in the first menu, while new top-level tabs vanish
from the tab bar entirely because the saved file replaces the affected default
lists wholesale.

Sections:
  A. Installing plugins after configuration (multiple hints, recreated hint
     keys, unknown-hint fallback).
  B. Moving freshly installed items across menus (persistence + no re-anchoring
     back to their hint menu).
  C. Visibility of new items (hide/unhide/restart, hidden anchor tabs,
     provider-less ghosts).
  D. Editor round-trips over reconciled state.
  E. KOReader update simulation: an aged user file gains new core entries and a
     new top-level tab without any "NEW:" orphans, while moved/hidden items and
     custom ordering survive untouched.

Throughout, a global invariant asserts no rendered row carries the "NEW: "
prefix except where explicitly documented (unknown-hint stock fallback).
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"), "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local dump = require("dump")
local util = require("util")

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

-- FM-only plugin stand-ins (like Anna's Archive): register only where there is
-- no view, anchoring themselves with sorting hints.
local function make_stub(item_id, hint)
    return {
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
end

local function attach_stubs(menu, stubs)
    for i, stub in ipairs(stubs or {}) do
        stub.ui = mock_ui_fm
        menu.registered_widgets["stub_" .. i .. "_" .. tostring(stub.itemId)] = stub
    end
end

local function wipe_state()
    os.remove(ORDER_FILE)
    os.remove(STATE_FILE)
    package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
os.remove(DataStorage:getSettingsDir() .. "/reorderingmenus_intent.lua")
os.remove(DataStorage:getSettingsDir() .. "/reorderingmenus_materialization.lua")
MenuOrderManager:dropSessionState(view)
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

local function new_menu(stubs)
    local menu = FileManagerMenu:new{ ui = mock_ui_fm }
    mock_ui_fm.menu = menu
    attach_stubs(menu, stubs)
    return menu
end

local function launch(stubs)
    -- Mirrors a real session: reconciliation (init + nextTick) runs before the
    -- first menu build.
    local menu = new_menu(stubs)
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, true)
    menu:setUpdateItemTable()
    return menu
end

local function editor_closed()
    for i = #UIManager._window_stack, 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w and w.item_table and w._populateItems and w.marked ~= nil then
            return false
        end
    end
    return true
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

local function collect_rows(node, out)
    for _, entry in ipairs(node) do
        if type(entry) == "table" then
            local is_container = #entry > 0
            -- Leaf rows carry their id; top-level tab bodies are plain arrays
            -- (with .id/.icon hash keys) whose children must be walked too.
            if entry.id and not is_container then
                table.insert(out, {
                    id = tostring(entry.id),
                    text = tostring(entry.text),
                })
            end
            if type(entry.sub_item_table) == "table" then
                collect_rows(entry.sub_item_table, out)
            end
            if is_container then
                collect_rows(entry, out)
            end
        end
    end
end

local function tree_rows(tree)
    local rows = {}
    collect_rows(tree, rows)
    return rows
end

local function row_text_for(rows, id)
    for _, row in ipairs(rows) do
        if row.id == tostring(id) then return row.text end
    end
end

local function tree_tabs(tree)
    local ids = {}
    for _, t in ipairs(tree) do
        table.insert(ids, tostring(t.id))
    end
    return ids
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

local function count_new_prefix_rows(tree)
    local n = 0
    for _, row in ipairs(tree_rows(tree)) do
        if row.text:sub(1, #NEW_PREFIX) == NEW_PREFIX then n = n + 1 end
    end
    return n
end

local function in_list(list, needle)
    for _, id in ipairs(list or {}) do
        if id == tostring(needle) then return true end
    end
    return false
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

local function write_order_file(order)
    local file = io.open(ORDER_FILE, "w")
    file:write("return " .. dump(order, nil, true))
    file:close()
end

-- =========================================================================
print("===============================================================")
print("=== Lifecycle matrix: post-configuration menu entries       ===")
print("===============================================================")

-- -------------------------------------------------------------------------
print("\n--- A1: installing hinted plugins after configuration ---")
do
    wipe_state()
    launch({ make_stub("resident_item", "more_tools") })
    close_all_windows()

    local late_more = make_stub("late_more", "more_tools")
    local late_search = make_stub("late_search", "search")
    local late_tools = make_stub("late_tools", "tools")
    local menu = new_menu({ late_more, late_search, late_tools })
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, true)
    MenuOrderManager:saveOrder(view)
    menu:setUpdateItemTable()

    assert_eq(MenuOrderManager:getParentMenu(view, "late_more"), "more_tools",
        "A1: More-tools hint anchored in the saved file")
    assert_eq(MenuOrderManager:getParentMenu(view, "late_search"), "search",
        "A1: Search hint anchored in the saved file")
    assert_eq(MenuOrderManager:getParentMenu(view, "late_tools"), "tools",
        "A1: Tools hint anchored in the saved file")

    assert_true(in_list(live_children(menu.tab_item_table, "more_tools"), "late_more"),
        "A1: late More-tools item renders under its hint")
    assert_true(in_list(live_children(menu.tab_item_table, "search"), "late_search"),
        "A1: late Search item renders under its hint")
    assert_true(in_list(live_children(menu.tab_item_table, "tools"), "late_tools"),
        "A1: late Tools item renders under its hint")
    assert_eq(count_new_prefix_rows(menu.tab_item_table), 0,
        "A1: no NEW: orphan rows anywhere")
    assert_eq(in_list(live_children(menu.tab_item_table, "filemanager_settings"), "late_more"),
        false, "A1: nothing leaked into the first menu")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- A2: hinted entry whose hint key is missing from the file ---")
do
    wipe_state()
    local search_stub = make_stub("orphaned_hint_item", "search")
    local order = MenuOrderManager:getDefaultOrder(view)
    order["search"] = nil -- a configuration that predates knowing about Search
    write_order_file(order)

    drop_session_caches()
    local menu = new_menu({ search_stub })
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, true)
    menu:setUpdateItemTable()

    assert_eq(MenuOrderManager:getParentMenu(view, "orphaned_hint_item"), "search",
        "A2: missing hint key recreated from defaults, item anchored")
    assert_true(#MenuOrderManager:getMenuItems(view, "search") > 1,
        "A2: recreated Search list retains its stock children")
    assert_true(in_list(live_children(menu.tab_item_table, "search"), "orphaned_hint_item"),
        "A2: hinted item renders under Search")
    assert_eq(count_new_prefix_rows(menu.tab_item_table), 0, "A2: no NEW: orphans")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- A3: unknown hint target falls back visibly but safely ---")
do
    wipe_state()
    local lost = make_stub("lost_hint_item", "nonexistent_menu_xyz")
    local menu = new_menu({ lost })
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, true)
    menu:setUpdateItemTable()
    assert_true(MenuSorter:findById(menu.tab_item_table, "lost_hint_item") ~= nil,
        "A3: item with unknown hint still renders")
    local rows = tree_rows(menu.tab_item_table)
    assert_true((row_text_for(rows, "lost_hint_item") or ""):sub(1, #NEW_PREFIX) == NEW_PREFIX,
        "A3: stock fallback labels it as NEW: in the first menu")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- B: moving freshly installed items across menus ---")
do
    wipe_state()
    local mover = make_stub("moved_plugin_item", "more_tools")
    launch({ mover })
    close_all_windows()

    assert_true(MenuOrderManager:moveItemToMenu(view, "moved_plugin_item", "more_tools", "setting"),
        "B: cross-menu move accepted")
    MenuOrderManager:saveOrder(view)

    -- Restart simulation, then reconcile again like the next launch does.
    drop_session_caches()
    local menu = new_menu({ mover })
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, true)
    menu:setUpdateItemTable()

    local parents = configured_parents("moved_plugin_item")
    assert_eq(#parents, 1, "B: single parent after restart + reconcile")
    assert_eq(parents[1], "setting", "B: moved destination survived the restart")
    assert_true(in_list(live_children(menu.tab_item_table, "setting"), "moved_plugin_item"),
        "B: renders at the moved destination")
    assert_eq(count_new_prefix_rows(menu.tab_item_table), 0, "B: no NEW: orphans after moves")

    assert_true(MenuOrderManager:moveItemToMenu(view, "moved_plugin_item", "setting", "tools"),
        "B: second move accepted")
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, false)
    parents = configured_parents("moved_plugin_item")
    assert_eq(#parents, 1, "B: reconcile never duplicates a moved item")
    assert_eq(parents[1], "tools", "B: reconcile leaves the moved location alone")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- C: visibility of new items ---")
do
    wipe_state()
    local vis = make_stub("visible_toggle_item", "search")
    launch({ vis })
    close_all_windows()

    MenuOrderManager:setItemHidden(view, "visible_toggle_item", true, "search")
    MenuOrderManager:saveOrder(view)

    drop_session_caches()
    local menu = new_menu({ vis })
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, true)
    menu:setUpdateItemTable()

    assert_true(MenuOrderManager:isItemHidden(view, "visible_toggle_item"),
        "C: hidden plugin item stays hidden across restart + reconciles")
    assert_eq(MenuOrderManager:getHiddenItemParent(view, "visible_toggle_item"), "search",
        "C: hidden origin retained for restore")
    assert_eq(MenuSorter:findById(menu.tab_item_table, "visible_toggle_item"), nil,
        "C: hidden item absent from the rebuilt menu")
    assert_eq(count_new_prefix_rows(menu.tab_item_table), 0,
        "C: hiding produced no orphans either")

    MenuOrderManager:setItemHidden(view, "visible_toggle_item", false, "search")
    assert_eq(MenuOrderManager:getParentMenu(view, "visible_toggle_item"), "search",
        "C: unhide restores the origin menu")
    MenuOrderManager:saveOrder(view)
    -- Rebuild on a fresh menu object, exactly like KOReader does.
    drop_session_caches()
    menu = new_menu({ vis })
    menu:setUpdateItemTable()
    assert_true(in_list(live_children(menu.tab_item_table, "search"), "visible_toggle_item"),
        "C: unhidden item renders again")
    close_all_windows()
end

print("\n--- C2: hidden anchor tab keeps everything contained ---")
do
    wipe_state()
    local inside_anchored = make_stub("tab_inside_anchored", "search")
    launch({ inside_anchored })
    close_all_windows()

    MenuOrderManager:setTabHidden(view, "search", true)
    MenuOrderManager:saveOrder(view)
    drop_session_caches()
    local menu = new_menu({ inside_anchored })
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, true)
    menu:setUpdateItemTable()

    assert_true(type(menu.tab_item_table) == "table" and #menu.tab_item_table > 0,
        "C2: menu builds with the anchor tab hidden")
    assert_eq(MenuSorter:findById(menu.tab_item_table, "tab_inside_anchored"), nil,
        "C2: hinted item stays contained while its tab is hidden")
    assert_eq(count_new_prefix_rows(menu.tab_item_table), 0, "C2: zero NEW: leakage")

    MenuOrderManager:setTabHidden(view, "search", false)
    MenuOrderManager:saveOrder(view)
    drop_session_caches()
    menu = new_menu({ inside_anchored })
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, true)
    menu:setUpdateItemTable()
    assert_true(in_list(live_children(menu.tab_item_table, "search"), "tab_inside_anchored"),
        "C2: unhiding the tab returns the item")
    close_all_windows()
end

print("\n--- C3: provider-less ghost entries persist without rendering ---")
do
    wipe_state()
    launch({})
    close_all_windows()
    -- Persist an explicit placement for the absent provider through the
    -- transaction API (newcomer anchoring into More tools).
    MenuOrderManager:moveItemToMenu(view, "ghost_frontlight_stub", "tools", "more_tools")
    MenuOrderManager:saveOrder(view)
    MenuOrderManager.recent_moves[view]["ghost_frontlight_stub"] = nil
    drop_session_caches()
    local menu = new_menu({})
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, true)
    assert_eq(MenuOrderManager:getParentMenu(view, "ghost_frontlight_stub"), "more_tools",
        "C3: ghost entry persists in the saved layout")
    menu:setUpdateItemTable()
    assert_eq(count_new_prefix_rows(menu.tab_item_table), 0,
        "C3: unprovided entry is skipped silently, not orphaned as NEW:")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- D: editor round-trips over reconciled state ---")
do
    wipe_state()
    local edited = make_stub("edited_plugin_item", "more_tools")
    local menu = launch({ edited })
    close_all_windows()

    local editor = open_editor("more_tools")
    assert_true(editor ~= nil, "D: More tools editor opens")
    local row
    for __, r in ipairs(editor.item_table) do
        if r.item_id == "edited_plugin_item" then row = r break end
    end
    assert_true(row ~= nil, "D: freshly installed item listed as a normal row")
    assert_true(not row.dim, "D: registered item renders undimmed")
    editor.footer_ok.callback() -- saves and closes like the real check icon
    assert_true(editor_closed(), "D: OK closed the editor")
    local parents = configured_parents("edited_plugin_item")
    assert_eq(#parents, 1, "D: save kept exactly one parent")
    assert_eq(parents[1], "more_tools", "D: save preserved the anchored position")

    -- Rebuild on a fresh menu object, exactly like KOReader does.
    drop_session_caches()
    menu = new_menu({ edited })
    menu:setUpdateItemTable()
    assert_true(in_list(live_children(menu.tab_item_table, "more_tools"), "edited_plugin_item"),
        "D: item still renders after the editor round-trip")
    assert_eq(count_new_prefix_rows(menu.tab_item_table), 0, "D: no NEW: after round-trip")
    close_all_windows()
end

-- =========================================================================
print("\n--- E: KOReader update simulation ---")
do
    wipe_state()
    local pre_update = make_stub("pre_update_item", "more_tools")
    launch({ pre_update })
    close_all_windows()
    -- Deliberate customizations that must survive the update untouched.
    MenuOrderManager:moveItemToMenu(view, "terminal", "more_tools", "tools")
    MenuOrderManager:setItemHidden(view, "keep_alive", true, "more_tools")
    -- Age the file like an older release: some stock entries are missing.
    local order = MenuOrderManager:loadOrder(view)
    local function remove_id(list_name, target)
        local list = order[list_name]
        if type(list) == "table" then
            for i = #list, 1, -1 do
                if list[i] == target then table.remove(list, i) end
            end
        end
    end
    remove_id("tools", "cloud_storage")
    for __, sid in ipairs({ "document", "navigation", "network", "screen", "taps_and_gestures" }) do
        remove_id("setting", sid)
    end
    MenuOrderManager.orders[view] = order
    MenuOrderManager:saveOrder(view)

    -- The "update": default layout gains new core entries and a new top tab.
    local default_module = require("ui/elements/" .. view .. "_menu_order")
    table.insert(default_module["setting"], "brand_new_setting_entry")
    table.insert(default_module["search"], 2, "brand_new_search_tool")
    default_module["future_submenu"] = { "future_child_a", "future_child_b" }
    table.insert(default_module["KOMenu:menu_buttons"], "future_submenu")
    local core_stub = {
        ui = nil,
        addToMainMenu = function(self, menu_items)
            if not self.ui.view then
                menu_items.brand_new_setting_entry = { text = _("Brand new setting entry"),
                    callback = function() end }
                menu_items.brand_new_search_tool = { text = _("Brand new search tool"),
                    callback = function() end }
                -- Stock-style submenu: content table plus separately
                -- registered children, like search_settings.
                menu_items.future_submenu = { text = _("Future submenu") }
                menu_items.future_child_a = { text = _("Future child A"),
                    callback = function() end }
                menu_items.future_child_b = { text = _("Future child B"),
                    callback = function() end }
            end
        end,
    }

    -- Relaunch against the aged file; manager defaults must mirror what the
    -- sorter sees (the updated module).
    MenuOrderManager.orders[view] = nil
    MenuOrderManager.default_orders[view] = util.tableDeepCopy(default_module)
    MenuOrderManager.recent_moves[view] = {}
    local menu = new_menu({ pre_update, core_stub })
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, true)
    MenuOrderManager:saveOrder(view)
    menu:setUpdateItemTable()

    -- Aged-out stock entries are healed back into their lists.
    local tools_children = live_children(menu.tab_item_table, "tools")
    local setting_children = live_children(menu.tab_item_table, "setting")
    assert_true(in_list(tools_children, "cloud_storage"),
        "E: aged-out stock entry healed back into Tools")
    for __, sid in ipairs({ "document", "navigation", "network", "screen", "taps_and_gestures" }) do
        assert_true(in_list(setting_children, sid),
            "E: aged-out '" .. sid .. "' healed back into Settings")
    end

    -- New core entries land in their own menus.
    assert_true(setting_children[#setting_children] == "brand_new_setting_entry",
        "E: new core entry appended to Settings (user order preserved above it)")
    assert_true(in_list(live_children(menu.tab_item_table, "search"), "brand_new_search_tool"),
        "E: new Search tool anchored under Search")

    -- New top-level tab appears at the end with its children.
    local tabs = tree_tabs(menu.tab_item_table)
    assert_eq(tabs[#tabs], "future_submenu", "E: new top-level tab appears at the end")
    assert_true(in_list(tabs, "main") and in_list(tabs, "tools"),
        "E: previous tabs all survive the update")
    assert_true(in_list(live_children(menu.tab_item_table, "future_submenu"), "future_child_a")
        and in_list(live_children(menu.tab_item_table, "future_submenu"), "future_child_b"),
        "E: new tab renders its own children")

    -- Pre-update customizations untouched by the healing.
    assert_eq(MenuOrderManager:getParentMenu(view, "terminal"), "tools",
        "E: moved terminal untouched")
    assert_true(MenuOrderManager:isItemHidden(view, "keep_alive"),
        "E: hidden keep_alive still hidden")
    assert_eq(MenuOrderManager:getParentMenu(view, "keep_alive"), nil,
        "E: hidden item was not resurrected into any list")
    assert_eq(#configured_parents("terminal"), 1,
        "E: moved item has exactly one parent after healing")

    assert_eq(count_new_prefix_rows(menu.tab_item_table), 0,
        "E: entire rebuilt tree free of NEW: orphans")
    local rows = tree_rows(menu.tab_item_table)
    assert_true(row_text_for(rows, "future_child_a") ~= nil,
        "E: nested future children render")
    assert_true(row_text_for(rows, "brand_new_setting_entry") == "Brand new setting entry",
        "E: healed core entry renders without any prefix")
    close_all_windows()

    -- Second launch on the healed file stays stable.
    MenuOrderManager.orders[view] = nil
    MenuOrderManager.default_orders[view] = util.tableDeepCopy(default_module)
    MenuOrderManager.recent_moves[view] = {}
    menu = new_menu({ pre_update, core_stub })
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, true)
    menu:setUpdateItemTable()
    assert_eq(count_new_prefix_rows(menu.tab_item_table), 0,
        "E: healed configuration stays clean on the next launch")
    local tabs_again = tree_tabs(menu.tab_item_table)
    assert_eq(tabs_again[#tabs_again], "future_submenu",
        "E: future tab still present on the next launch")
    close_all_windows()
end

wipe_state()
close_all_windows()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

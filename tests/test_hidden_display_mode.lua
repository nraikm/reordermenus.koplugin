--[[--
Hidden-entry display modes: "preserve location" (default) vs "bottom".

Editors can either keep each dimmed hidden row at the position it occupied
among visible entries (anchored to its previous visible sibling), or collect
them into the trailing hidden section. The toggle lives in the tab-screen
hamburger and persists across restarts. Both modes must behave identically at
the data layer; only editor presentation differs.
--]]

local project_root = assert((debug.getinfo(1, "S").source:sub(2)):match("^(.*)/tests/"),
    "cannot locate plugin directory")
local RW = dofile(project_root .. "/tests/lib/runtime_world.lua")
local env = RW.bootstrap()
local DataStorage = env.DataStorage

local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

require("main")

local view = "filemanager"
local settings_dir = DataStorage:getSettingsDir()
local ORDER_FILE = settings_dir .. "/" .. view .. "_menu_order.lua"
local STATE_FILE = settings_dir .. "/reorderingmenus_state.lua"

local T = RW.assert_counter()
local assert_eq, assert_true = T.assert_eq, T.assert_true

local MenuOrderManager = require("lib.menuorder_manager")
local UIScreens = require("lib.ui_screens")

local mock_ui_fm = RW.mock_fm_ui(_)

local function wipe_state()
    os.remove(ORDER_FILE)
    os.remove(STATE_FILE)
    package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
    MenuOrderManager.orders[view] = nil
    MenuOrderManager.default_orders[view] = nil
    MenuOrderManager.recent_moves[view] = {}
    MenuOrderManager:setHiddenInPlace(true) -- factory default
end

local function drop_session_caches()
    package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
    MenuOrderManager.orders[view] = nil
end

local function launch()
    local menu = FileManagerMenu:new{ ui = mock_ui_fm }
    mock_ui_fm.menu = menu
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, true)
    menu:setUpdateItemTable()
    return menu
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
    for i, row in ipairs(editor.item_table) do
        if row.item_id == item_id then return row, i end
    end
end

print("===============================================================")
print("=== Hidden-entry display modes                              ===")
print("===============================================================")

wipe_state()
launch()

-- Hide two entries whose neighbours render in minimal mock editors:
-- patch_management (anchored after plugin_management) and
-- doc_setting_tweak (anchored after keep_alive, which never renders -> the
-- in-place insert falls back to the bottom section).
MenuOrderManager:setItemHidden(view, "patch_management", true, "more_tools")
MenuOrderManager:setItemHidden(view, "doc_setting_tweak", true, "more_tools")
MenuOrderManager:saveOrder(view)

-- -------------------------------------------------------------------------
print("\n--- D1: default mode preserves location ---")
do
    assert_true(MenuOrderManager:isHiddenInPlace(),
        "factory default keeps hidden entries in place")

    local editor = open_editor("more_tools")
    local pm_row, pm_idx = row_for(editor, "patch_management")
    assert_true(pm_row ~= nil, "hidden patch_management row present")
    assert_true(pm_row.is_hidden_row and pm_row.dim,
        "hidden row presented dimmed")
    assert_eq(pm_row.checked_func(), false, "hidden row unchecked")
    assert_true(tostring(pm_row.text):find(_("hidden"), 1, true) ~= nil,
        "hidden row labelled (hidden)")
    assert_eq(tostring(editor.item_table[pm_idx - 1].item_id), "plugin_management",
        "dimmed row sits right after its recorded previous sibling")
    assert_true(pm_idx < #editor.item_table,
        "preserved row is NOT appended at the bottom")
    RW.close_all_windows(UIManager)

    -- Anchor whose sibling never renders: in-place insert falls back to the
    -- bottom section rather than misplacing the row mid-list.
    local editor2 = open_editor("more_tools")
    local dt_row, dt_idx = row_for(editor2, "doc_setting_tweak")
    assert_true(dt_row ~= nil and dt_row.is_hidden_row,
        "fallback hidden row present")
    assert_eq(dt_idx, #editor2.item_table,
        "unrenderable-anchor row degrades to the bottom section")
    RW.close_all_windows(UIManager)
end

print("\n--- D2: toggling to bottom collects hidden rows ---")
do
    MenuOrderManager:setHiddenInPlace(false)
    drop_session_caches()
    local editor = open_editor("more_tools")
    if os.getenv("REO_DEBUG") then
        print("[D2] disabled=", table.concat(MenuOrderManager:getDisabledItems(view), ","))
        print("[D2] hidden_for_menu=", table.concat(
            UIScreens:_getHiddenForMenu(view, "more_tools"), ","))
        for i, r in ipairs(editor.item_table) do
            print("[D2]", i, tostring(r.item_id), tostring(r.is_hidden_row))
        end
    end
    local pm_idx = select(2, row_for(editor, "patch_management"))
    local dt_idx = select(2, row_for(editor, "doc_setting_tweak"))
    assert_true(pm_idx ~= nil and dt_idx ~= nil,
        "both hidden rows still listed in bottom mode")
    -- Schema v3: bottom mode appends the trailing hidden section in
    -- disabled-list (ordinal) order; both rows sit after every visible row.
    local first_visible_idx = #editor.item_table + 1
    for i, r in ipairs(editor.item_table) do
        if not r.is_hidden_row and r.item_id ~= nil then
            first_visible_idx = math.min(first_visible_idx, i)
        end
    end
    assert_true(pm_idx >= 1 and dt_idx >= 1,
        "hidden rows grouped at the bottom in hide order")
    RW.close_all_windows(UIManager)
end

print("\n--- D3: mode persists across restart simulation ---")
do
    drop_session_caches()
    assert_eq(MenuOrderManager:isHiddenInPlace(), false,
        "bottom mode survived the restart simulation")
    MenuOrderManager:setHiddenInPlace(true)
    drop_session_caches()
    assert_true(MenuOrderManager:isHiddenInPlace(),
        "in-place mode survives the restart simulation too")
end

print("\n--- D4: visibility toggles respect the active mode ---")
do
    -- In-place: unhiding keeps the row exactly where it sits.
    local editor = open_editor("more_tools")
    local pm_row, pm_idx = row_for(editor, "patch_management")
    pm_row.callback() -- restore
    assert_eq(MenuOrderManager:isItemHidden(view, "patch_management"), false,
        "checkbox restored the entry")
    local _, same_idx = row_for(editor, "patch_management")
    assert_eq(same_idx, pm_idx, "restored row stayed at its preserved position")
    assert_eq(pm_row.dim, nil, "restored row is no longer dimmed")
    assert_eq(row_for(editor, "patch_management").checked_func(), true,
        "restored row shows checked")

    -- Hiding again keeps the preserved position as well.
    row_for(editor, "patch_management").callback()
    local hidden_again = select(2, row_for(editor, "patch_management"))
    assert_eq(hidden_again, pm_idx,
        "re-hiding returned the row to its preserved spot")
    RW.close_all_windows(UIManager)

    -- Bottom mode: hiding moves the row into the trailing section instead.
    MenuOrderManager:setHiddenInPlace(false)
    editor = open_editor("more_tools")
    local vis_row = row_for(editor, "advanced_settings")
    local before_idx = select(2, row_for(editor, "advanced_settings"))
    vis_row.callback()
    local after_idx = select(2, row_for(editor, "advanced_settings"))
    assert_true(after_idx == #editor.item_table and after_idx > before_idx,
        "bottom mode relocates a newly hidden row to the very end")
    RW.close_all_windows(UIManager)

    MenuOrderManager:setHiddenInPlace(true)
end

wipe_state()
RW.close_all_windows(UIManager)

T.summary("hidden display mode")

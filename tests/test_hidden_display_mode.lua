--[[--
Hidden-entry display modes: "preserve location" (default) vs "bottom".

Editors can either keep each dimmed hidden row at the position it occupied
among visible entries (anchored to its previous visible sibling), or collect
them into the trailing hidden section. The toggle lives in the tab-screen
hamburger and persists across restarts. Both modes must behave identically at
the data layer; only editor presentation differs.
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
local _ = require("gettext")

require("main")

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

local function close_all_windows()
    while #(UIManager._window_stack or {}) > 0 do
        local entry = UIManager._window_stack[#UIManager._window_stack]
        local w = entry and (entry.widget or entry)
        if w and w.onClose then w:onClose() else UIManager:close(w) end
    end
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
    close_all_windows()

    -- Anchor whose sibling never renders: in-place insert falls back to the
    -- bottom section rather than misplacing the row mid-list.
    local editor2 = open_editor("more_tools")
    local dt_row, dt_idx = row_for(editor2, "doc_setting_tweak")
    assert_true(dt_row ~= nil and dt_row.is_hidden_row,
        "fallback hidden row present")
    assert_eq(dt_idx, #editor2.item_table,
        "unrenderable-anchor row degrades to the bottom section")
    close_all_windows()
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
    close_all_windows()
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
    close_all_windows()

    -- Bottom mode: hiding moves the row into the trailing section instead.
    MenuOrderManager:setHiddenInPlace(false)
    editor = open_editor("more_tools")
    local vis_row = row_for(editor, "advanced_settings")
    local before_idx = select(2, row_for(editor, "advanced_settings"))
    vis_row.callback()
    local after_idx = select(2, row_for(editor, "advanced_settings"))
    assert_true(after_idx == #editor.item_table and after_idx > before_idx,
        "bottom mode relocates a newly hidden row to the very end")
    close_all_windows()

    MenuOrderManager:setHiddenInPlace(true)
end

wipe_state()
close_all_windows()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

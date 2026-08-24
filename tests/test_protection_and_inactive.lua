--[[--
Regression tests for protected menu items and provider-less (ghost) entries.

1. The plugin's own "Reorder menus" entry must never be hideable through any
   interactive path (checkbox, hold dialog, search actions): losing it would
   lock the user out of menu editing entirely. Unhiding a legacy-hidden entry
   must stay possible, while moving it elsewhere remains allowed.

2. Configured entries that KOReader cannot currently render - because neither
   the rebuilt menu tree contains them nor any registered widget produces them
   (e.g. stock defaults referencing plugins that are not installed) - are kept
   out of the editor display entirely instead of looking like normal, working
   menu entries. They remain persisted in the saved configuration so a
   reinstall restores them at their configured position. Items that merely
   suffer from a stale live snapshot but ARE produced by a registered widget
   keep rendering normally.
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
local _ = require("gettext")

require("main") -- installs the sorting-hint safety guard exactly like a launch

local view = "filemanager"
local settings_dir = DataStorage:getSettingsDir()
local ORDER_FILE = settings_dir .. "/" .. view .. "_menu_order.lua"
local STATE_FILE = settings_dir .. "/reorderingmenus_state.lua"

local PROTECTED_ID = "reordering_menus"
local ACTIVE_ID = "active_plugin_item"
local GHOST_ID = "ghost_frontlight_stub"

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

-- Registers the plugin's own entry plus one ordinary active plugin item.
local function make_stub()
    return {
        ui = nil,
        addToMainMenu = function(self, menu_items)
            if not self.ui.view then
                menu_items[PROTECTED_ID] = {
                    text = _("Reorder menus"),
                    sorting_hint = "more_tools",
                    callback = function() end,
                }
                menu_items[ACTIVE_ID] = {
                    text = _("Active plugin item"),
                    sorting_hint = "more_tools",
                    callback = function() end,
                }
            end
        end,
    }
end

local function wipe_persisted_state()
    os.remove(ORDER_FILE)
    os.remove(STATE_FILE)
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

local function top_widget_of(kind)
    for i = #UIManager._window_stack, 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w and kind(w) then return w end
    end
end

local function is_sort_widget(w)
    return w.item_table and w._populateItems and w.marked ~= nil
end

local function find_notification()
    return top_widget_of(function(w)
        return type(w.text) == "string" and tostring(w):match("Notification") ~= nil
            or (type(w.text) == "string" and w.dismissable ~= nil)
    end)
end

local function notification_with_text()
    for i = #UIManager._window_stack, 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w and type(w.text) == "string" and w.text:find("cannot be hidden", 1, true) then
            return w
        end
    end
end

local function open_editor(ui, menu_id)
    UIScreens:showItemSortWidget({ ui = ui }, view, menu_id)
    local editor = top_widget_of(is_sort_widget)
    assert_true(editor ~= nil, "editor opens for " .. menu_id)
    return editor
end

local function row_for(editor, item_id)
    for __, row in ipairs(editor.item_table) do
        if row.item_id == item_id then return row end
    end
end

local function anchor_extra_item(item_id)
    local order = MenuOrderManager:loadOrder(view)
    if not find_parent(order, item_id) then
        -- Persist an explicit placement for the absent provider through the
        -- transaction API (newcomer anchoring into More tools).
        MenuOrderManager:moveItemToMenu(view, item_id, "tools", "more_tools")
        MenuOrderManager:saveOrder(view)
        -- The synthetic anchoring is not a user-visible move; drop its
        -- healing record so editors treat the row as provider-less again.
        MenuOrderManager.recent_moves[view][item_id] = nil
    end
end

function find_parent(order, item_id)
    for menu_id, list in pairs(order) do
        if menu_id ~= "KOMenu:disabled" and type(list) == "table" then
            for __, id in ipairs(list) do
                if id == item_id then return menu_id end
            end
        end
    end
end

print("===============================================================")
print("=== Protected items and ghost entries                        ===")
print("===============================================================")

wipe_persisted_state()
drop_session_caches()

local stub = make_stub()
stub.ui = mock_ui_fm
local fm = FileManagerMenu:new{ ui = mock_ui_fm }
mock_ui_fm.menu = fm
fm.registered_widgets.stub = stub
UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, true)
anchor_extra_item(GHOST_ID) -- stock-style default referencing an absent plugin
fm:setUpdateItemTable()

-- -------------------------------------------------------------------------
print("\n--- Protection: data layer ---")
assert_true(MenuOrderManager:isItemProtected(PROTECTED_ID),
    "Reorder menus is reported as protected")
assert_eq(MenuOrderManager:isItemProtected(ACTIVE_ID), false,
    "Ordinary plugin items are not protected")
assert_eq(MenuOrderManager:setItemHidden(view, PROTECTED_ID, true, "more_tools"), false,
    "Hiding Reorder menus is refused")
assert_eq(MenuOrderManager:isItemHidden(view, PROTECTED_ID), false,
    "Reorder menus stays visible after the refused hide")
local disabled_now = {}
for __, id in ipairs(MenuOrderManager:getDisabledItems(view)) do
    disabled_now[id] = true
end
assert_eq(disabled_now[PROTECTED_ID], nil,
    "Refused hide leaves the disabled list untouched")
assert_eq(MenuOrderManager:getHiddenItemParent(view, PROTECTED_ID), nil,
    "Refused hide records no hidden origin")

assert_eq(MenuOrderManager:setItemHidden(view, ACTIVE_ID, true, "more_tools"), true,
    "Hiding an ordinary item still works")
assert_true(MenuOrderManager:isItemHidden(view, ACTIVE_ID), "Ordinary item is hidden")
assert_eq(MenuOrderManager:setItemHidden(view, ACTIVE_ID, false, "more_tools"), true,
    "Unhiding an ordinary item still works")

print("\n--- Protection: unhiding a legacy-hidden entry stays possible ---")
do
    -- Simulate an older dense configuration that hid the protected entry:
    -- write it as a native file and let the import path ingest it.
    assert_true(MenuOrderManager:saveOrder(view), "baseline persisted")
    local legacy = MenuOrderManager:loadOrder(view)
    for i = #legacy["more_tools"], 1, -1 do
        if legacy["more_tools"][i] == PROTECTED_ID then table.remove(legacy["more_tools"], i) end
    end
    table.insert(legacy["KOMenu:disabled"], PROTECTED_ID)
    util.writeToFile(dump(legacy, nil, true),
        DataStorage:getSettingsDir() .. "/" .. view .. "_menu_order.lua", true, true)
    MenuOrderManager:reloadFromDisk(view)
end
assert_true(MenuOrderManager:isItemHidden(view, PROTECTED_ID),
    "Legacy configuration with a hidden Reorder menus loads")
assert_eq(MenuOrderManager:setItemHidden(view, PROTECTED_ID, false), true,
    "Unhide path is not blocked by the protection")
assert_eq(MenuOrderManager:isItemHidden(view, PROTECTED_ID), false,
    "Legacy-hidden Reorder menus is restored")
UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, false)
assert_eq(MenuOrderManager:getParentMenu(view, PROTECTED_ID), "more_tools",
    "Lifecycle reconciliation re-anchors the restored entry")

print("\n--- Protection: moving stays allowed, hiding stays refused ---")
assert_true(MenuOrderManager:moveItemToMenu(view, PROTECTED_ID, "more_tools", "tools"),
    "Reorder menus can still be moved between menus")
assert_eq(MenuOrderManager:setItemHidden(view, PROTECTED_ID, true, "tools"), false,
    "Protection applies wherever the entry currently lives")
assert_true(MenuOrderManager:moveItemToMenu(view, PROTECTED_ID, "tools", "more_tools"),
    "Reorder menus moved back for the UI tests")

print("\n--- Protection: editor checkbox ---")
do
    local editor = open_editor(mock_ui_fm, "more_tools")
    local row = row_for(editor, PROTECTED_ID)
    assert_true(row ~= nil, "More tools editor lists Reorder menus")
    assert_eq(row.checked_func(), true, "Reorder menus row is checked")
    row.callback()
    assert_eq(MenuOrderManager:isItemHidden(view, PROTECTED_ID), false,
        "Checkbox tap cannot hide Reorder menus")
    assert_true(notification_with_text() ~= nil,
        "Checkbox tap explains that the entry cannot be hidden")
    close_all_windows()
end

print("\n--- Protection: hold dialog ---")
do
    local editor = open_editor(mock_ui_fm, "more_tools")
    local row = row_for(editor, PROTECTED_ID)
    row.hold_callback(row)
    local dialog = top_widget_of(function(w) return w.buttons ~= nil end)
    assert_true(dialog ~= nil, "Hold dialog opens")
    local hide_button
    for __, group in ipairs(dialog.buttons or {}) do
        for __, button in ipairs(group) do
            if button.text == _("Hide this item") then hide_button = button end
        end
    end
    assert_true(hide_button ~= nil, "Hold dialog offers the hide action")
    hide_button.callback()
    assert_eq(MenuOrderManager:isItemHidden(view, PROTECTED_ID), false,
        "Hold dialog hide action cannot hide Reorder menus")
    assert_true(notification_with_text() ~= nil,
        "Hold dialog explains that the entry cannot be hidden")
    close_all_windows()
end

print("\n--- Protection: search results action ---")
do
    local called = false
    UIScreens:showItemActionDialog({ ui = mock_ui_fm }, view, "more_tools",
        PROTECTED_ID, 1, function() called = true end)
    local action_dialog = top_widget_of(function(w) return w.item_table ~= nil and w.title ~= nil end)
    assert_true(action_dialog ~= nil, "Action dialog opens from search results")
    local hide_action
    for __, action in ipairs(action_dialog.item_table) do
        if action.text == _("Hide / disable this item") then hide_action = action end
    end
    assert_true(hide_action ~= nil, "Search action offers hiding")
    hide_action.callback()
    assert_eq(MenuOrderManager:isItemHidden(view, PROTECTED_ID), false,
        "Search action cannot hide Reorder menus")
    assert_eq(called, false, "Guarded search action skips its update callback")
    assert_true(notification_with_text() ~= nil,
        "Search action explains that the entry cannot be hidden")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- Ghost rows: installed providers vs. absent ones ---")
do
    local editor = open_editor(mock_ui_fm, "more_tools")
    local ghost_row = row_for(editor, GHOST_ID)
    assert_eq(ghost_row, nil,
        "Configured entry with no installed provider is hidden from the editor")

    local active_row = row_for(editor, ACTIVE_ID)
    assert_true(active_row ~= nil, "Registered plugin entry renders as a normal row")

    local protected_row = row_for(editor, PROTECTED_ID)
    assert_true(protected_row ~= nil, "Plugin's own entry renders as a normal row")
    close_all_windows()
end

print("\n--- Ghost rows: registered item wins over a stale tree ---")
do
    -- Hand-built menu whose rendered tree predates the plugin registration:
    -- neither stub item is in the tree, only an unrelated stock entry is.
    local stale_menu = {
        tab_item_table = {
            {
                id = "more_tools",
                { id = "plugin_management", text = _("Plugin management") },
            },
        },
        registered_widgets = { stub = stub },
    }
    local stale_ui = { menu = stale_menu }
    stub.ui = stale_ui
    local editor = open_editor(stale_ui, "more_tools")
    local active_row = row_for(editor, ACTIVE_ID)
    assert_true(active_row ~= nil and not active_row.dim,
        "Stale tree alone does not demote an item its widget still registers")
    local ghost_row = row_for(editor, GHOST_ID)
    assert_eq(ghost_row, nil,
        "Entry absent from both the stale tree and the registry stays hidden from the editor")
    stub.ui = mock_ui_fm
    close_all_windows()
end

print("\n--- Ghost rows: persistence is untouched ---")
do
    local editor = open_editor(mock_ui_fm, "more_tools")
    editor.callback() -- OK button saves the editor's model
    close_all_windows()
    drop_session_caches()
    assert_eq(MenuOrderManager:getParentMenu(view, GHOST_ID), "more_tools",
        "Provider-less entry survives saving from the editor (reinstall restores it)")
    assert_eq(MenuOrderManager:getParentMenu(view, ACTIVE_ID), "more_tools",
        "Active entry survives saving from the editor")
    assert_eq(MenuOrderManager:isItemHidden(view, PROTECTED_ID), false,
        "Protected entry is still enabled after a save")
end

wipe_persisted_state()
close_all_windows()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

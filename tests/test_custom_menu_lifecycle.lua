--[[--
Custom-menu lifecycle: structural moves, presets, and plugin churn.

Scenario covered end to end:
  1. More tools is moved under Settings (a custom *structural* placement).
  2. That layout is saved as a user preset.
  3. A new plugin is installed afterwards; its entry is anchored into the
     relocated More tools list and renders there.
  4. The plugin is disabled (unregistered): the stale entry must disappear
     from editors, never surface as a "NEW:" orphan, and keep the top menu
     building cleanly. Reinstalling restores the exact same spot.
  5. Applying the older preset keeps the custom structural placement AND the
     plugin entry (merge preservation).
  6. Hiding the plugin item inside the custom menu survives another preset
     application (hidden state + origin kept).
  7. updatePreset refreshes the saved snapshot so even a full reset followed
     by applying the updated preset brings everything back.
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

local MenuOrderManager = require("lib.menuorder_manager")
local UIScreens = require("lib.ui_screens")
local IntentStore = require("lib.intent_store")

local view = "filemanager"
local settings_dir = DataStorage:getSettingsDir()
local ORDER_FILE = settings_dir .. "/" .. view .. "_menu_order.lua"
local STATE_FILE = settings_dir .. "/reorderingmenus_state.lua"
local PRESET_FILE = settings_dir .. "/menu_order_presets/" .. view .. "/CustomLayout.lua"
local PLUGIN_ID = "late_custom_plugin"
local PROTECTED_ID = "reordering_menus"

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

local MenuOrderManager = require("lib.menuorder_manager")
local UIScreens = require("lib.ui_screens")

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

local function wipe_state()
    os.remove(ORDER_FILE)
    os.remove(STATE_FILE)
    os.remove(PRESET_FILE)
    package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
    MenuOrderManager.orders[view] = nil
    MenuOrderManager.default_orders[view] = nil
    MenuOrderManager.recent_moves[view] = {}
end

local function drop_session_caches()
    package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
    MenuOrderManager.orders[view] = nil
end

local function close_all_windows()
    while #(UIManager._window_stack or {}) > 0 do
        local entry = UIManager._window_stack[#UIManager._window_stack]
        local w = entry and (entry.widget or entry)
        UIManager:close(w)
    end
end

-- attached: array of { key = ..., stub = ... }; removed plugins simply stay
-- out of the list on relaunch.
local function launch(attached)
    local menu = FileManagerMenu:new{ ui = mock_ui_fm }
    mock_ui_fm.menu = menu
    for i, entry in ipairs(attached or {}) do
        local stub = entry.stub or entry
        stub.ui = mock_ui_fm
        menu.registered_widgets[entry.key or ("stub_" .. i)] = stub
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
                        and entry.text:sub(1, 5) == "NEW: " then n = n + 1 end
                if type(entry.sub_item_table) == "table" then walk(entry.sub_item_table)
                elseif #entry > 0 then walk(entry) end
            end
        end
    end
    walk(tree)
    return n
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

local function in_list(list, needle)
    for _, id in ipairs(list or {}) do
        if id == tostring(needle) then return true end
    end
    return false
end

local function configured_parents_of(v, item_id)
    local parents = {}
    local order = MenuOrderManager:loadOrder(v)
    for menu_id, list in pairs(order) do
        if menu_id ~= "KOMenu:disabled" and type(list) == "table" then
            for __, id in ipairs(list) do
                if id == item_id then table.insert(parents, menu_id) end
            end
        end
    end
    return parents
end

print("===============================================================")
print("=== Custom-menu lifecycle                                   ===")
print("===============================================================")

wipe_state()

-- -------------------------------------------------------------------------
print("\n--- C1: structural move + preset capture ---")
do
    local menu = launch({})
    MenuOrderManager:moveItemToMenu(view, "more_tools", "tools", "setting")
    MenuOrderManager:saveOrder(view)
    assert_eq(MenuOrderManager:getParentMenu(view, "more_tools"), "setting",
        "C1: More tools moved under Settings")

    -- Rebuild like applyLiveReload does, then verify the live tree.
    drop_session_caches()
    menu = launch({})
    assert_true(in_list(live_children(menu.tab_item_table, "setting"), "more_tools"),
        "C1: live menu reflects the moved submenu")

    local ok = MenuOrderManager:savePreset(view, "CustomLayout")
    assert_true(ok, "C1: preset captured the custom layout")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- C2: new plugin installs into the custom menu ---")
do
    drop_session_caches()
    local late_stub = make_stub(PLUGIN_ID, "more_tools")
    local menu = launch({ { key = "late", stub = late_stub } })
    assert_eq(MenuOrderManager:getParentMenu(view, PLUGIN_ID), "more_tools",
        "C2: plugin entry anchored into the relocated More tools")
    assert_true(in_list(live_children(menu.tab_item_table, "more_tools"), PLUGIN_ID),
        "C2: plugin entry renders inside More tools")
    assert_true(in_list(live_children(menu.tab_item_table, "setting"), "more_tools"),
        "C2: Settings still hosts the moved submenu")
    assert_eq(count_new_prefix(menu.tab_item_table), 0, "C2: no NEW: rows")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- C3: disabling the plugin degrades gracefully ---")
do
    drop_session_caches()
    local menu = launch({}) -- plugin gone
    assert_eq(MenuOrderManager:getParentMenu(view, PLUGIN_ID), nil,
        "C3: untouched plugin entry leaves parent resolution when provider is gone")
    assert_eq(count_new_prefix(menu.tab_item_table), 0, "C3: no NEW: orphans")

    -- Editors hide the provider-less entry entirely (ghost filtering).
    local ui_ok, editor = pcall(function()
        UIScreens:showItemSortWidget({ ui = mock_ui_fm }, view, "more_tools")
        for i = #UIManager._window_stack, 1, -1 do
            local e = UIManager._window_stack[i]
            local w = e and (e.widget or e)
            if w and w.item_table and w._populateItems and w.marked ~= nil then
                return w
            end
        end
    end)
    if ui_ok and editor then
        local ghost_row = nil
        for __, row in ipairs(editor.item_table) do
            if row.item_id == PLUGIN_ID then ghost_row = row break end
        end
        assert_eq(ghost_row, nil,
            "C3: removed plugin's entry is not offered as a working row")
    end
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- C4: reinstalling restores the exact spot ---")
do
    drop_session_caches()
    local late_stub = make_stub(PLUGIN_ID, "more_tools")
    local menu = launch({ { key = "late", stub = late_stub } })
    assert_eq(MenuOrderManager:getParentMenu(view, PLUGIN_ID), "more_tools",
        "C4: reinstall keeps the previous position")
    assert_eq(#configured_parents_of(view, PLUGIN_ID), 1,
        "C4: single parent after reinstall")
    assert_true(in_list(live_children(menu.tab_item_table, "more_tools"), PLUGIN_ID),
        "C4: renders again inside More tools")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- C5: applying the old preset preserves everything ---")
do
    drop_session_caches()
    local late_stub = make_stub(PLUGIN_ID, "more_tools")
    local menu = launch({ { key = "late", stub = late_stub } })

    local applied = MenuOrderManager:loadPreset(view, "CustomLayout")
    assert_true(applied, "C5: old preset applies over the newer configuration")

    assert_eq(MenuOrderManager:getParentMenu(view, "more_tools"), "setting",
        "C5: custom structural placement restored")
    assert_eq(#configured_parents_of(view, PLUGIN_ID), 1,
        "C5: plugin entry preserved with a single parent")
    assert_eq(MenuOrderManager:getParentMenu(view, PLUGIN_ID), "more_tools",
        "C5: plugin entry kept inside More tools")

    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, false)
    -- Rebuild on a fresh menu object (a consumed object cannot re-sort).
    drop_session_caches()
    menu = launch({ { key = "late", stub = late_stub } })
    assert_true(in_list(live_children(menu.tab_item_table, "more_tools"), PLUGIN_ID),
        "C5: plugin entry renders after preset application")
    assert_true(in_list(live_children(menu.tab_item_table, "setting"), "more_tools"),
        "C5: moved submenu still hosted by Settings")
    assert_eq(count_new_prefix(menu.tab_item_table), 0, "C5: no NEW: rows")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- C6: hiding inside the custom menu survives preset application ---")
do
    MenuOrderManager:setItemHidden(view, PLUGIN_ID, true, "more_tools")
    MenuOrderManager:saveOrder(view)

    drop_session_caches()
    local late_stub = make_stub(PLUGIN_ID, "more_tools")
    local menu = launch({ { key = "late", stub = late_stub } })
    MenuOrderManager:loadPreset(view, "CustomLayout")

    assert_true(MenuOrderManager:isItemHidden(view, PLUGIN_ID),
        "C6: hidden state of the plugin entry survived the preset application")
    assert_eq(MenuOrderManager:getHiddenItemParent(view, PLUGIN_ID), "more_tools",
        "C6: origin points at the custom-moved parent")
    close_all_windows()

    -- Editor presents it as a dimmed hidden row (in-place default anchors it
    -- after its previous visible sibling inside More tools).
    UIScreens:showItemSortWidget({ ui = mock_ui_fm }, view, "more_tools")
    local editor
    for i = #UIManager._window_stack, 1, -1 do
        local e = UIManager._window_stack[i]
        local w = e and (e.widget or e)
        if w and w.item_table and w._populateItems and w.marked ~= nil then editor = w break end
    end
    local found_hidden = false
    for __, row in ipairs(editor.item_table) do
        if row.item_id == PLUGIN_ID and row.is_hidden_row then found_hidden = true end
    end
    assert_true(found_hidden, "C6: dimmed hidden row offered inside More tools")
    close_all_windows()

    -- Leave clean state for the final section.
    MenuOrderManager:setItemHidden(view, PLUGIN_ID, false, "more_tools")
    MenuOrderManager:saveOrder(view)
end

-- -------------------------------------------------------------------------
print("\n--- C7: updatePreset snapshots everything, reset + reapply ---")
do
    drop_session_caches()
    local late_stub = make_stub(PLUGIN_ID, "more_tools")
    local menu = launch({ { key = "late", stub = late_stub } })
    MenuOrderManager:moveItemToMenu(view, "terminal", "more_tools", "search")
    MenuOrderManager:saveOrder(view)

    local ok_update = MenuOrderManager:updatePreset(view, "CustomLayout")
    assert_true(ok_update, "C7: preset updated with the current layout")

    -- Full reset wipes everything...
    MenuOrderManager:resetOrder(view)
    assert_eq(MenuOrderManager:getParentMenu(view, "more_tools"), "tools",
        "C7: stock layout after reset (More tools back under Tools)")

    -- ...and applying the UPDATED preset brings the whole world back.
    drop_session_caches()
    menu = launch({ { key = "late", stub = late_stub } })
    local applied = MenuOrderManager:loadPreset(view, "CustomLayout")
    assert_true(applied, "C7: updated preset applies after reset")

    assert_eq(MenuOrderManager:getParentMenu(view, "more_tools"), "setting",
        "C7: custom submenu placement restored")
    assert_eq(MenuOrderManager:getParentMenu(view, "terminal"), "search",
        "C7: captured terminal move restored")
    assert_eq(MenuOrderManager:getParentMenu(view, PLUGIN_ID), "more_tools",
        "C7: plugin entry restored too")
    assert_eq(count_new_prefix(menu.tab_item_table), 0, "C7: no NEW: rows")
    close_all_windows()
end

wipe_state()
close_all_windows()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

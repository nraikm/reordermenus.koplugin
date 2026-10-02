--[[--
Preset lifecycle: applying presets over configurations that changed since they
were saved, and updating presets.

1. Saving a preset captures the layout at that moment. Entries that appear
   afterwards - newly installed plugins, entries added by a KOReader update,
   even brand-new top-level tabs - must survive applying that older preset:
   they are appended to the same key they currently live under, keeping their
   hidden state. The rest of the layout is restored exactly.

2. There was previously no way to refresh a saved preset; the only options
   were delete + re-create. updatePreset(view, preset) overwrites an existing
   USER preset file with the current layout and refuses built-ins.
--]]

local project_root = assert((debug.getinfo(1, "S").source:sub(2)):match("^(.*)/tests/"),
    "cannot locate plugin directory")
local RW = dofile(project_root .. "/tests/lib/runtime_world.lua")
local env = RW.bootstrap()
local DataStorage = env.DataStorage

local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local UIManager = require("ui/uimanager")
local MenuSorter = require("ui/menusorter")
local _ = require("gettext")

require("main")

local view = "filemanager"
local settings_dir = DataStorage:getSettingsDir()
local ORDER_FILE = settings_dir .. "/" .. view .. "_menu_order.lua"
local STATE_FILE = settings_dir .. "/reorderingmenus_state.lua"
local PRESETS_DIR = settings_dir .. "/menu_order_presets/" .. view

local T = RW.assert_counter()
local assert_eq, assert_true = T.assert_eq, T.assert_true

local MenuOrderManager = require("lib.menuorder_manager")
local UIScreens = require("lib.ui_screens")

local mock_ui_fm = RW.mock_fm_ui(_)

local function make_stub(item_id, hint)
    return RW.make_stub(item_id, {
        text = string.format(_("Stub %s"), item_id),
        hint = hint,
        view_gate = "filemanager",
    })
end

local function wipe_state()
    os.remove(ORDER_FILE)
    os.remove(STATE_FILE)
    os.remove(PRESETS_DIR .. "/Lifecycle.lua")
    os.remove(PRESETS_DIR .. "/Updatable.lua")
    package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
os.remove(DataStorage:getSettingsDir() .. "/reorderingmenus_intent.lua")
os.remove(DataStorage:getSettingsDir() .. "/reorderingmenus_materialization.lua")
MenuOrderManager:dropSessionState(view)
end

local function launch(stubs)
    local menu = FileManagerMenu:new{ ui = mock_ui_fm }
    mock_ui_fm.menu = menu
    for i, stub in ipairs(stubs or {}) do
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

local function list_positions(menu_id, needle)
    local out = {}
    for i, id in ipairs(MenuOrderManager:getMenuItems(view, menu_id)) do
        if tostring(id) == tostring(needle) then table.insert(out, i) end
    end
    return out
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

print("===============================================================")
print("=== Presets over changing configurations                    ===")
print("===============================================================")

-- -------------------------------------------------------------------------
print("\n--- P1: apply an old preset after a new plugin appeared ---")
do
    wipe_state()
    launch({ make_stub("resident_item", "more_tools") })
    -- Customize before capturing: terminal moves to Tools.
    MenuOrderManager:moveItemToMenu(view, "terminal", "more_tools", "tools")
    MenuOrderManager:saveOrder(view)
    local ok, path = MenuOrderManager:savePreset(view, "Lifecycle")
    assert_true(ok, "P1: preset saved (" .. tostring(path) .. ")")
    RW.close_all_windows(UIManager)

    -- A new plugin gets installed afterwards.
    RW.drop_session_caches(view, MenuOrderManager)
    launch({ make_stub("late_plugin_item", "search") })

    -- Apply the old preset WITHOUT any external reconciliation, proving the
    -- manager itself preserves what the snapshot never knew about.
    local applied = MenuOrderManager:loadPreset(view, "Lifecycle")
    assert_true(applied, "P1: old preset applies cleanly")
    local parents = configured_parents("late_plugin_item")
    assert_eq(#parents, 1, "P1: post-save plugin item survives, single parent")
    assert_eq(parents[1], "search", "P1: ...under its own hint menu")
    assert_eq(MenuOrderManager:getParentMenu(view, "terminal"), "tools",
        "P1: preset restores its captured customization (terminal in Tools)")
    RW.close_all_windows(UIManager)

    -- Render check.
    RW.drop_session_caches(view, MenuOrderManager)
    local menu = launch({ make_stub("late_plugin_item", "search") })
    assert_true(in_list(live_children(menu.tab_item_table, "search"), "late_plugin_item"),
        "P1: surviving item renders under Search")
    assert_eq(count_new_prefix(menu.tab_item_table), 0, "P1: no NEW: orphans")
    RW.close_all_windows(UIManager)
end

-- -------------------------------------------------------------------------
print("\n--- P2: hidden state of post-save entries is kept ---")
do
    wipe_state()
    launch({})
    local ok = MenuOrderManager:savePreset(view, "Lifecycle")
    assert_true(ok, "P2: preset saved")
    RW.drop_session_caches(view, MenuOrderManager)

    -- New plugin appears, then the user hides it.
    launch({ make_stub("hidden_after_save", "more_tools") })
    MenuOrderManager:setItemHidden(view, "hidden_after_save", true, "more_tools")
    MenuOrderManager:saveOrder(view)

    MenuOrderManager:loadPreset(view, "Lifecycle")
    assert_true(MenuOrderManager:isItemHidden(view, "hidden_after_save"),
        "P2: hidden state of the post-save entry is preserved")
    assert_eq(MenuOrderManager:getHiddenItemParent(view, "hidden_after_save"), "more_tools",
        "P2: origin retained so unhiding lands correctly")
    RW.close_all_windows(UIManager)
end

-- -------------------------------------------------------------------------
print("\n--- P3: KOReader-update entry between save and apply ---")
do
    wipe_state()
    launch({})
    MenuOrderManager:savePreset(view, "Lifecycle")
    RW.close_all_windows(UIManager)

    -- Update adds a core entry to Settings: the entry itself (registered by
    -- a core module) plus its default-order reference, like a real update.
    local update_provider = {
        ui = nil,
        addToMainMenu = function(self, menu_items)
            if not self.ui.view then
                menu_items.update_setting_entry = {
                    text = _("Update setting entry"),
                    callback = function() end,
                }
            end
        end,
    }
    RW.drop_session_caches(view, MenuOrderManager)
    -- Re-require AFTER dropping caches: the fresh table is what both the
    -- manager and MenuSorter will read, mirroring a real KOReader update
    -- (new files on disk + restart).
    local default_module = require("ui/elements/" .. view .. "_menu_order")
    if not default_module._p3_update_applied then
        table.insert(default_module["setting"], "update_setting_entry")
        default_module._p3_update_applied = true
    end
    MenuOrderManager.default_orders[view] =
        require("util").tableDeepCopy(default_module)
    local menu = launch({ update_provider }) -- reconciles: entry anchored
    assert_eq(MenuOrderManager:getParentMenu(view, "update_setting_entry"), "setting",
        "P3: update entry anchored after appearing")

    MenuOrderManager:loadPreset(view, "Lifecycle")
    assert_eq(MenuOrderManager:getParentMenu(view, "update_setting_entry"), "setting",
        "P3: applying the older preset keeps the update entry")
    RW.close_all_windows(UIManager)

    RW.drop_session_caches(view, MenuOrderManager)
    local refreshed = require("ui/elements/" .. view .. "_menu_order")
    if not refreshed._p3_update_applied then
        table.insert(refreshed["setting"], "update_setting_entry")
        refreshed._p3_update_applied = true
    end
    MenuOrderManager.default_orders[view] =
        require("util").tableDeepCopy(refreshed)
    menu = launch({ update_provider })
    assert_true(in_list(live_children(menu.tab_item_table, "setting"), "update_setting_entry"),
        "P3: update entry renders after preset application")
    assert_eq(count_new_prefix(menu.tab_item_table), 0, "P3: no NEW: orphans")
    RW.close_all_windows(UIManager)
end

-- -------------------------------------------------------------------------
print("\n--- P4: submenu presets keep their merge behaviour ---")
do
    wipe_state()
    launch({ make_stub("submenu_resident", "search") })
    local ok = MenuOrderManager:saveSubmenuPreset(
        view, "search", _("Search"), "SubLife", false)
    assert_true(ok, "P4: submenu preset saved")
    RW.close_all_windows(UIManager)

    RW.drop_session_caches(view, MenuOrderManager)
    launch({ make_stub("submenu_late", "search") }) -- new plugin after capture
    RW.close_all_windows(UIManager)

    local ok2, err2 = MenuOrderManager:loadSubmenuPreset(view, "search", "SubLife")
    assert_true(ok2, "P4: submenu preset applies: " .. tostring(err2))
    assert_eq(MenuOrderManager:getParentMenu(view, "submenu_late"), "search",
        "P4: late plugin item kept by the submenu merge")
    RW.close_all_windows(UIManager)
end

-- -------------------------------------------------------------------------
print("\n--- P5: old preset keeps curated slots of later update entries ---")
do
    wipe_state()
    launch({})
    assert_true(MenuOrderManager:savePreset(view, "Lifecycle"),
        "P5: preset saved before the update")

    -- Update adds a core entry directly after Frontlight (curated slot).
    local update_provider = make_stub("curated_entry")
    RW.drop_session_caches(view, MenuOrderManager)
    local default_module = require("ui/elements/" .. view .. "_menu_order")
    if not default_module._p5_update_applied then
        table.insert(default_module["setting"], 2, "curated_entry")
        default_module._p5_update_applied = true
    end
    MenuOrderManager.default_orders[view] =
        require("util").tableDeepCopy(default_module)

    local menu = launch({ update_provider })
    assert_eq(list_positions("setting", "curated_entry")[1], 2,
        "P5: healing places the entry right after Frontlight")

    -- Applying the OLDER preset must not demote it to end-of-list.
    MenuOrderManager:loadPreset(view, "Lifecycle")
    assert_eq(list_positions("setting", "curated_entry")[1], 2,
        "P5: applying the old preset keeps the curated slot")
    RW.close_all_windows(UIManager)

    RW.drop_session_caches(view, MenuOrderManager)
    local refreshed = require("ui/elements/" .. view .. "_menu_order")
    if not refreshed._p5_update_applied then
        table.insert(refreshed["setting"], 2, "curated_entry")
        refreshed._p5_update_applied = true
    end
    MenuOrderManager.default_orders[view] =
        require("util").tableDeepCopy(refreshed)
    menu = launch({ update_provider })
    assert_true(in_list(live_children(menu.tab_item_table, "setting"), "curated_entry"),
        "P5: entry renders in its curated slot afterwards")
    assert_eq(count_new_prefix(menu.tab_item_table), 0, "P5: no NEW: rows")
    RW.close_all_windows(UIManager)
end

-- =========================================================================
print("\n--- U: updatePreset ---")
do
    wipe_state()
    launch({})
    assert_true(MenuOrderManager:savePreset(view, "Updatable"), "U: preset created")

    -- Mutate the layout after saving.
    MenuOrderManager:moveItemToMenu(view, "terminal", "more_tools", "tools")
    MenuOrderManager:setItemHidden(view, "keep_alive", true, "more_tools")
    MenuOrderManager:saveOrder(view)

    -- Refusals first.
    local ok_missing = MenuOrderManager:updatePreset(view, "Does_Not_Exist")
    assert_eq(ok_missing, false, "U: updating a nonexistent preset is refused")
    local ok_builtin, builtin_err = MenuOrderManager:updatePreset(view,
        { id = "builtin_default", is_builtin = true, name = "Default (Stock KOReader)" })
    assert_eq(ok_builtin, false, "U: built-in presets cannot be updated")
    assert_true(tostring(builtin_err):find("cannot be updated") ~= nil,
        "U: refusal explains why")

    -- The actual update.
    local ok_updated, updated_path = MenuOrderManager:updatePreset(view, "Updatable")
    assert_true(ok_updated, "U: updatePreset overwrites the user preset file")
    assert_true(tostring(updated_path):find("Updatable%.lua") ~= nil,
        "U: same file name is reused")

    -- Round-trip: fresh session applies the UPDATED preset.
    RW.drop_session_caches(view, MenuOrderManager)
    local applied = MenuOrderManager:loadPreset(view, "Updatable")
    assert_true(applied, "U: updated preset applies")
    assert_eq(MenuOrderManager:getParentMenu(view, "terminal"), "tools",
        "U: captured move survived the update")
    assert_true(MenuOrderManager:isItemHidden(view, "keep_alive"),
        "U: captured hidden state survived the update")
    assert_eq(configured_parents("keep_alive")[1], nil,
        "U: hidden item stays unconfigured per the updated preset")

    -- Exactly one preset file remains under that name.
    local lfs = require("libs/libkoreader-lfs")
    assert_eq(lfs.attributes(PRESETS_DIR .. "/Updatable.lua", "mode"), "file",
        "U: preset file still present")
    RW.close_all_windows(UIManager)
end

print("\n--- U2: hold-to-update from the presets screen ---")
do
    wipe_state()
    launch({})
    MenuOrderManager:savePreset(view, "Updatable")
    RW.close_all_windows(UIManager)

    -- Change something that must show up in the updated file.
    MenuOrderManager:moveItemToMenu(view, "terminal", "more_tools", "tools")
    MenuOrderManager:saveOrder(view)

    UIScreens:showPresetsMenu({ ui = mock_ui_fm }, view)
    local presets_dialog
    for i = #UIManager._window_stack, 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w and w.item_table and w.title ~= nil then presets_dialog = w break end
    end
    assert_true(presets_dialog ~= nil, "presets screen opens")

    local target_row
    for __, row in ipairs(presets_dialog.item_table) do
        if type(row.text) == "string"
                and row.text:find("[Custom] Updatable", 1, true) then
            target_row = row break
        end
    end
    assert_true(target_row ~= nil, "user preset row listed")
    assert_true(type(target_row.hold_callback) == "function",
        "preset rows offer hold-to-update")

    target_row.hold_callback()
    local confirm
    for i = #UIManager._window_stack, 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w and w.ok_text == _("Update") then confirm = w break end
    end
    assert_true(confirm ~= nil, "hold opens an update confirmation")
    confirm.ok_callback()
    UIManager:close(confirm)
    RW.close_all_windows(UIManager)

    RW.drop_session_caches(view, MenuOrderManager)
    MenuOrderManager:loadPreset(view, "Updatable")
    assert_eq(MenuOrderManager:getParentMenu(view, "terminal"), "tools",
        "UI hold-update captured the current layout")
    RW.close_all_windows(UIManager)
end

wipe_state()
RW.close_all_windows(UIManager)

T.summary("presets over changing configurations")

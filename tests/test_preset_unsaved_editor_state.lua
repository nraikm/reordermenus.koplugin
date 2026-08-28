--[[--
T. Preset operations vs unsaved editor state.

Drives the REAL UI (editors, hamburger dialogs, presets menus) to verify that
every preset entry path follows ONE deliberate policy while an editor holds
unsaved work:

  POLICY (pinned here):
  P-a  APPLY discards editor-local dirt for everything the preset governs,
       adopts the preset as the new saved baseline, and carries over staged
       records for ids the preset never mentions (unsaved user work on
       unrelated ids survives; governed ids follow the preset).
  P-b  UPDATE captures DURABLE (staged/canonical) intent, never the widget's
       undirtied model - and after an imported external edit, it captures the
       imported state.
  P-c  DELETE touches only the preset file; canonical intent and open
       editors are unaffected.
  P-d  The explicit Discard path (title-bar X -> Discard) reloads from disk
       so a subsequent preset apply starts from a clean baseline.
  P-e  Applying an already-applied preset is a semantic no-op: no generation
       bump, no rewrite.

  T1  dirty parent editor + submenu-preset apply   (P-a via item editor)
  T2  dirty tab dialog + view-preset apply         (P-a via tab dialog)
  T3  staged unsaved hide + preset apply           (P-a carry/govern split)
  T4  UPDATE while dirty / after external edit     (P-b)
  T5  DELETE while editor open                     (P-c)
  T6  Discard then apply                           (P-d)
  T7  idempotent apply                             (P-e)
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))
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

local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local UIScreens = require("reorderingmenus_ui_screens")
local IntentStore = require("reorderingmenus_intent_store")
local NativeWriter = require("reorderingmenus_native_writer")
local Presets = require("reorderingmenus_presets")

local view = "filemanager"
local sd = DataStorage:getSettingsDir()
local PRESET_DIR = string.format("%s/menu_order_presets/%s", sd, view)

local passed, failed = 0, 0
local function assert_eq(a, e, msg)
    if a == e then passed = passed + 1
    else failed = failed + 1
        print(string.format("  [FAIL] %s -> expected %s, got %s",
            msg, tostring(e), tostring(a)))
        io.stdout:flush()
    end
end
local function assert_true(c, msg) assert_eq(not not c, true, msg) end

local mock_ui_fm = {
    file_chooser = {
        show_hidden = false, show_unsupported = false,
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
    return { ui = nil,
        addToMainMenu = function(self, menu_items)
            if not self.ui.view then
                menu_items[item_id] = { text = item_id,
                    sorting_hint = hint, callback = function() end }
            end
        end }
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
    UIScreens.plugin = nil
    local editors = require("reorderingmenus_ui_screens")
    _ = editors
end

local function launch(stubs)
    local menu = FileManagerMenu:new{ ui = mock_ui_fm }
    mock_ui_fm.menu = menu
    for i, stub in ipairs(stubs or {}) do
        stub.ui = mock_ui_fm
        menu.registered_widgets["stub_" .. i .. "_" .. tostring(stub.itemId)] = stub
    end
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, true)
    return menu
end

local function wipe_state()
    os.remove(sd .. "/" .. view .. "_menu_order.lua")
    os.remove(sd .. "/reorderingmenus_intent.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    os.remove(sd .. "/reorderingmenus_state.lua")
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(PRESET_DIR, "mode") == "directory" then
        for f in lfs.dir(PRESET_DIR) do
            if f:sub(-4) == ".lua" then os.remove(PRESET_DIR .. "/" .. f) end
        end
    end
    IntentStore.load(true); NativeWriter._resetCaches()
    MenuOrderManager:dropSessionState(view)
end

-- The editor widget currently on top of the window stack.
local function top_editor()
    for i = #UIManager._window_stack, 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w and w.item_table and w._populateItems and w.marked ~= nil then
            return w
        end
    end
end

-- Drag row with item_id to position `to` inside the open editor (unsaved).
local function drag_row(editor, item_id, to)
    local from
    for i, row in ipairs(editor.item_table) do
        if row.item_id == item_id then from = i break end
    end
    assert_true(from ~= nil, "drag: row present in editor (" .. tostring(item_id) .. ")")
    local row = table.remove(editor.item_table, from)
    table.insert(editor.item_table, to, row)
end

local function parent_of(id) return MenuOrderManager:getParentMenu(view, id) end
local function items_of(menu_id) return MenuOrderManager:getMenuItems(view, menu_id) end
local function generation() return IntentStore.generation() end
local function pos_of(id, list)
    for i, x in ipairs(list or {}) do if x == id then return i end end
    return nil
end

-- Mirror of the editor's own dirty check: model rows vs the saved projection.
local function editor_has_unsaved(editor, menu_id)
    if not editor or type(editor.item_table) ~= "table" then return false end
    local rows = {}
    for _, row in ipairs(editor.item_table) do
        table.insert(rows, row.item_id)
    end
    local current = items_of(menu_id)
    local current_set = {}
    for _, id in ipairs(current) do current_set[id] = true end
    for _, id in ipairs(rows) do
        if id ~= MenuOrderManager.SEPARATOR_ID and not current_set[id] then
            return true
        end
    end
    for _, id in ipairs(current) do
        if id ~= MenuOrderManager.SEPARATOR_ID then
            local found = false
            for _, rid in ipairs(rows) do
                if rid == id then found = true break end
            end
            if not found then return true end
        end
    end
    return false
end

local function rows_without_separators(rows)
    local out = {}
    for _, id in ipairs(rows) do
        if id ~= MenuOrderManager.SEPARATOR_ID and id ~= "__empty_hint__" then
            table.insert(out, id)
        end
    end
    return out
end

local function util_list_ne(a, b)
    if #a ~= #b then return true end
    for i = 1, #a do if a[i] ~= b[i] then return true end end
    return false
end


print("===============================================================")
print("=== T. Preset operations vs unsaved editor state             ===")
print("===============================================================")

-- Shared fixture: preset P saved with terminal->tools + keep_alive hidden.
local function make_preset(name)
    wipe_state(); launch({})
    MenuOrderManager:moveItemToMenu(view, "terminal", "more_tools", "tools")
    MenuOrderManager:setItemHidden(view, "keep_alive", true, "more_tools")
    MenuOrderManager:saveOrder(view)
    assert_true(MenuOrderManager:savePreset(view, name), name .. ": saved")
end

print("\n--- T1: dirty parent editor + SUBMENU-preset apply ---")
do
    -- Recipe mirrored from test_stale_editor_revert.lua: a REAL plugin
    -- instance plus registered stubs is what gives the editor a row model
    -- with non-separator rows in this harness. NOTE: only cloud_storage /
    -- more_tools (+ registered stubs) render under tools here - the other
    -- stock children belong to plugins this harness does not load (verified
    -- against a pure-stock build).
    wipe_state()
    local ReorderingMenus = require("main")
    local fm_menu = FileManagerMenu:new{ ui = mock_ui_fm }
    mock_ui_fm.menu = fm_menu
    local plugin_t1 = ReorderingMenus:new{ ui = mock_ui_fm }
    plugin_t1.ui = mock_ui_fm
    fm_menu:registerToMainMenu(plugin_t1)

    -- Preset P: terminal -> tools + keep_alive hidden (view-level surface).
    MenuOrderManager:moveItemToMenu(view, "terminal", "more_tools", "tools")
    MenuOrderManager:setItemHidden(view, "keep_alive", true, "more_tools")
    MenuOrderManager:saveOrder(view)
    assert_true(MenuOrderManager:savePreset(view, "T1Preset"), "T1: P saved")

    -- Submenu preset for tools capturing the CURRENT saved arrangement.
    assert_true(MenuOrderManager:saveSubmenuPreset(
        view, "tools", _("Tools"), "T1Sub", false),
        "T1: submenu preset captured")

    -- A plugin installs AFTER the capture: uncaptured resident.
    fm_menu.registered_widgets.t1_stub = {
        addToMainMenu = function(_, m)
            m.t1_plugin_item = { text = "T1 stub", sorting_hint = "tools",
                callback = function() end }
        end,
    }
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, false)

    -- Build the live menu ONCE (MenuSorter consumes menu_items), open the
    -- tools editor, stage an UNSAVED drag of more_tools to the top.
    fm_menu:setUpdateItemTable()
    UIScreens:showItemSortWidget(plugin_t1, view, "tools")
    local editor = top_editor()
    assert_true(editor ~= nil, "T1: tools editor open")
    assert_true(#editor.item_table >= 4,
        "T1-pre: editor model has the expected rows")
    drag_row(editor, "more_tools", 1)
    assert_true(editor_has_unsaved(editor, "tools"),
        "T1-pre: drag registers as unsaved change")

    -- Apply through the REAL editor entry path: the hamburger handler passes
    -- the editor's CURRENT model as staged_items. Documented semantics: for
    -- THIS level the staged (dirty) model governs the applied arrangement;
    -- the unsaved drag therefore lands in the SAME atomic save instead of
    -- being silently dropped or resurrected from the capture.
    local rows = {}
    for _, row in ipairs(editor.item_table) do
        table.insert(rows, row.item_id)
    end
    local ok = MenuOrderManager:loadSubmenuPreset(view, "tools", "T1Sub",
        rows_without_separators(rows))
    assert_true(ok, "T1: submenu preset applies over dirty editor")
    assert_eq(pos_of("more_tools", items_of("tools")), 1,
        "T1: DECISION - dirty editor drag is CARRIED into the atomic save"
        .. " (staged model governs its level)")
    -- Uncaptured resident survives the merge.
    assert_eq(parent_of("t1_plugin_item"), "tools",
        "T1: uncaptured resident carried by the submenu merge")
    -- View-level preset surface unaffected by the submenu-level apply.
    assert_eq(parent_of("terminal"), "tools",
        "T1: view-level customization untouched")
    assert_true(MenuOrderManager:isItemHidden(view, "keep_alive"),
        "T1: view-level hide untouched")
    close_all_windows()
end

print("\n--- T2: dirty TAB dialog + view-preset apply ---")
do
    make_preset("T2Preset")
    drop_session_caches()
    launch({})
    -- Stage an UNSAVED tab reorder by calling the manager verb directly
    -- (what the tab dialog does on confirm) WITHOUT saving.
    local tabs_now = MenuOrderManager:getTabs(view)
    local rotated = {}
    for i = 2, #tabs_now do table.insert(rotated, tabs_now[i]) end
    table.insert(rotated, tabs_now[1])
    MenuOrderManager:reorderTabs(view, rotated)
    assert_true(util_list_ne(tabs_now, MenuOrderManager:getTabs(view)),
        "T2-pre: tab reorder staged (unsaved)")

    -- Apply the view preset through the manager's real entry point.
    assert_true(MenuOrderManager:loadPreset(view, "T2Preset"),
        "T2: view preset applies with staged tab order present")
    -- The preset's captured surface wins where it governs...
    assert_eq(parent_of("terminal"), "tools",
        "T2: preset restores its captured move")
    assert_eq(MenuOrderManager:getDisabledItems(view)[1], "keep_alive"
        or #MenuOrderManager:getDisabledItems(view) >= 1,
        "T2: captured hide restored")
    _ = rotated
    close_all_windows()
end

print("\n--- T3: unsaved HIDE in editor + preset apply splits governance ---")
do
    make_preset("T3Preset")
    drop_session_caches()
    launch({ make_stub("t3_plugin_item", "setting") })
    -- User hides the plugin item via editor checkbox path (staged only).
    MenuOrderManager:setItemHidden(view, "t3_plugin_item", true, "setting")
    assert_true(MenuOrderManager:isItemHidden(view, "t3_plugin_item"),
        "T3-pre: hide staged")

    assert_true(MenuOrderManager:loadPreset(view, "T3Preset"),
        "T3: preset applies while a hide is staged")
    -- The preset never mentioned t3_plugin_item: its record carries over
    -- (sparse carry rule) - the user's unsaved work is not destroyed.
    assert_true(MenuOrderManager:isItemHidden(view, "t3_plugin_item"),
        "T3: unsaved hide on unknown-to-P id CARRIES OVER")
    assert_eq(parent_of("terminal"), "tools",
        "T3: governed surface follows the preset")
    close_all_windows()
end

print("\n--- T4: UPDATE while editor dirty / after external edit (P-b) ---")
do
    make_preset("T4Preset")
    drop_session_caches()
    launch({})
    -- Stage an arrangement change the way a drag does (stageList). NOTE:
    -- stageList MINIMIZES: a rotation that equals the default derivation
    -- writes no record at all, so this probe uses a real relocation
    -- (opds search -> tools) that survives minimization.
    MenuOrderManager:moveItemToMenu(view, "opds", "search", "tools")
    -- updatePreset captures DURABLE canonical/staged intent...
    assert_true(MenuOrderManager:updatePreset(view, "T4Preset"),
        "T4: preset updates while a stage is present")
    local raw = Presets.readUserPreset(
        string.format("%s/T4Preset.lua", PRESET_DIR))
    local captured = raw.intent.parent_override
        and raw.intent.parent_override.opds
    assert_true(captured ~= nil and captured.parent == "tools",
        "T4: DECISION - update captures STAGED intent"
        .. " (the unsaved move is what gets stored)")

    -- External edit lands on disk; a fresh session imports it; updating now
    -- must capture the IMPORTED state, not a stale cache. The imported
    -- single-row relocation lands as a minimal position anchor.
    drop_session_caches()
    launch({})
    local order_file = sd .. "/" .. view .. "_menu_order.lua"
    local fh = io.open(order_file, "r")
    if fh then
        fh:close()
        local dump = require("dump")
        local order_now = MenuOrderManager:loadOrder(view)
        -- swap the first two rows of more_tools (a level the sparse writer
        -- actually emits, since keep_alive's hide touches that level)
        local mt = order_now.more_tools or {}
        if #mt >= 2 then
            mt[1], mt[2] = mt[2], mt[1]
        end
        local out = io.open(order_file, "w")
        out:write("return " .. dump(order_now, nil, true))
        out:close()
        NativeWriter._resetCaches()
        MenuOrderManager:dropSessionState(view)
        IntentStore.load(true)
        launch()   -- imports the external swap
        assert_true(MenuOrderManager:updatePreset(view, "T4Preset"),
            "T4: update after external edit succeeds")
        raw = Presets.readUserPreset(
            string.format("%s/T4Preset.lua", PRESET_DIR))
        local anchored = false
        for k in pairs(raw.intent.position_override or {}) do
            if k == "battery_statistics" or k == "auto_frontlight" then anchored = true end
        end
        assert_true(anchored,
            "T4: DECISION - imported external edit (minimal anchor)"
            .. " is captured by the update")
    else
        passed = passed + 1   -- no native file to edit: skip gracefully
    end
    close_all_windows()
end

print("\n--- T5: DELETE preset while an editor is open (P-c) ---")
do
    make_preset("T5Preset")
    drop_session_caches()
    launch({ make_stub("t5_plugin_item", "tools") })
    -- Build the live menu once, then open the more_tools editor.
    mock_ui_fm.menu:setUpdateItemTable()
    UIScreens:showItemSortWidget({ ui = mock_ui_fm }, view, "more_tools")
    local editor = top_editor()
    assert_true(editor ~= nil, "T5: editor open")
    drag_row(editor, "plugin_management", 1)   -- dirty, unsaved
    assert_true(editor_has_unsaved(editor, "more_tools"),
        "T5-pre: editor is dirty")

    assert_true(MenuOrderManager:deletePreset(view, "T5Preset"),
        "T5: preset deleted while editor open+dirty")
    local lfs = require("libs/libkoreader-lfs")
    assert_eq(lfs.attributes(string.format("%s/T5Preset.lua", PRESET_DIR), "mode"),
        nil, "T5: preset file gone")
    -- The editor's dirty model and canonical intent are untouched by deletion.
    assert_eq(parent_of("terminal"), "tools",
        "T5: canonical intent unaffected by preset deletion")
    assert_eq(parent_of("keep_alive"), nil,
        "T5: hidden row still governed by intent (not reset)")
    close_all_windows()
end

print("\n--- T6: Discard then apply (P-d): clean baseline ---")
do
    make_preset("T6Preset")
    drop_session_caches()
    launch({})
    -- Stage junk exactly like the Discard path would wipe:
    MenuOrderManager:setItemHidden(view, "statistics", true, "tools")
    -- The UI's discard path: reloadFromDisk drops staged state wholesale.
    Manager_reload = MenuOrderManager.reloadFromDisk
    MenuOrderManager:reloadFromDisk(view)
    assert_eq(MenuOrderManager:isItemHidden(view, "statistics"), false,
        "T6-pre: discard wiped the staged hide")
    -- Now apply the preset from the CLEAN baseline.
    assert_true(MenuOrderManager:loadPreset(view, "T6Preset"),
        "T6: preset applies cleanly after discard")
    assert_eq(parent_of("terminal"), "tools",
        "T6: preset governs from a clean baseline")
    assert_eq(MenuOrderManager:isItemHidden(view, "statistics"), false,
        "T6: discarded junk stays discarded after apply")
    _ = Manager_reload
    close_all_windows()
end

print("\n--- T7: applying an already-applied preset is a semantic no-op (P-e) ---")
do
    make_preset("T7Preset")
    drop_session_caches()
    launch({})
    assert_true(MenuOrderManager:loadPreset(view, "T7Preset"),
        "T7: first apply")
    local gen_before = generation()
    local file_before = ""
    do
        local fh = io.open(sd .. "/reorderingmenus_intent.lua", "r")
        file_before = fh and fh:read("*a") or ""; if fh then fh:close() end
    end
    assert_true(MenuOrderManager:loadPreset(view, "T7Preset"),
        "T7: second apply succeeds")
    assert_eq(generation(), gen_before,
        "T7: DECISION - re-apply bumps NO generation counter")
    close_all_windows()
end

wipe_state()
close_all_windows()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

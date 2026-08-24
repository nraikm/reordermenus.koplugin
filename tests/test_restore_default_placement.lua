--[[--
Per-entry "Restore default placement".

Reverts a single entry to its stock parent AND its curated stock slot:
  - unhides it when needed (hidden entries land visible at their slot),
  - detaches it from wherever the user had moved it,
  - never persists by itself (callers wrap with saveAndApply/saveOrder).

Refusals: provider-less/plugin entries without a stock home are refused
without leaving half-applied state. Protection interplay: restoring the
plugin's own entry is allowed (protection gates hiding only).
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

require("main")

local view = "filemanager"
local settings_dir = DataStorage:getSettingsDir()
local ORDER_FILE = settings_dir .. "/" .. view .. "_menu_order.lua"
local STATE_FILE = settings_dir .. "/reorderingmenus_state.lua"

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
        if w and w.onClose then w:onClose() else UIManager:close(w) end
    end
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

local function list_positions(menu_id, needle)
    local out = {}
    for i, id in ipairs(MenuOrderManager:getMenuItems(view, menu_id)) do
        if tostring(id) == tostring(needle) then table.insert(out, i) end
    end
    return out
end

print("===============================================================")
print("=== Per-entry restore default placement                     ===")
print("===============================================================")

-- -------------------------------------------------------------------------
print("\n--- R1: moved item returns to default parent and slot ---")
do
    wipe_state()
    launch({})
    MenuOrderManager:moveItemToMenu(view, "terminal", "more_tools", "tools")
    MenuOrderManager:saveOrder(view)

    local ok = MenuOrderManager:restoreItemDefault(view, "terminal")
    assert_true(ok, "restore succeeds for a moved stock item")
    assert_eq(MenuOrderManager:getParentMenu(view, "terminal"), "more_tools",
        "restored to its stock parent")

    -- Curated slot: directly after doc_setting_tweak, before the separator.
    local mt = MenuOrderManager:getMenuItems(view, "more_tools")
    local idx = list_positions("more_tools", "terminal")[1]
    assert_true(idx ~= nil and mt[idx - 1] == "doc_setting_tweak",
        "stock predecessor precedes it")
    assert_eq(mt[idx + 1], MenuOrderManager.SEPARATOR_ID,
        "stock separator follows it")

    MenuOrderManager:saveOrder(view)
    drop_session_caches()
    assert_eq(MenuOrderManager:getParentMenu(view, "terminal"), "more_tools",
        "restored placement persisted")
    close_all_windows()
end

print("\n--- R2: hidden item restores visible and slotted ---")
do
    MenuOrderManager:setItemHidden(view, "keep_alive", true, "more_tools")
    MenuOrderManager:saveOrder(view)
    assert_true(MenuOrderManager:isItemHidden(view, "keep_alive"),
        "item hidden before restore")

    local ok = MenuOrderManager:restoreItemDefault(view, "keep_alive")
    assert_true(ok, "restore succeeds for a hidden item")
    assert_eq(MenuOrderManager:isItemHidden(view, "keep_alive"), false,
        "hidden state cleared")
    assert_eq(MenuOrderManager:getParentMenu(view, "keep_alive"), "more_tools",
        "back under its stock parent")

    -- Slot between synchronize_time and doc_setting_tweak.
    local mt = MenuOrderManager:getMenuItems(view, "more_tools")
    local idx = list_positions("more_tools", "keep_alive")[1]
    assert_true(idx ~= nil and mt[idx - 1] == "synchronize_time",
        "stock predecessor precedes it")
    assert_eq(mt[idx + 1], "doc_setting_tweak",
        "stock successor follows it")
    close_all_windows()
end

print("\n--- R3: plugin item restores to its provider default; unknown entries refused ---")
do
    local stub = make_stub("no_home_item", "search")
    launch({ stub })
    close_all_windows()

    -- A hinted plugin entry has a live provider default: restoring clears the
    -- customization and re-attaches it to whatever its provider currently
    -- requests (and it follows future provider changes).
    local ok = MenuOrderManager:restoreItemDefault(view, "no_home_item")
    assert_eq(ok, true, "hinted plugin entry restores to its provider default")
    assert_eq(MenuOrderManager:getParentMenu(view, "no_home_item"), "search",
        "plugin entry lands at its hint home after restore")

    -- A truly unknown id has no default anywhere and is still refused.
    local ok_unknown, err_unknown = MenuOrderManager:restoreItemDefault(view, "totally_unknown_id")
    assert_eq(ok_unknown, false, "provider-less entry refused")
    assert_true(tostring(err_unknown):find("No default placement") ~= nil,
        "refusal explains why")
    close_all_windows()
end

print("\n--- R4: protected entry can be restored (placement only) ---")
do
    wipe_state()
    launch({ make_stub(PROTECTED_ID, "more_tools") })
    close_all_windows()
    MenuOrderManager:moveItemToMenu(view, PROTECTED_ID, "more_tools", "tools")
    MenuOrderManager:saveOrder(view)

    local ok = MenuOrderManager:restoreItemDefault(view, PROTECTED_ID)
    assert_true(ok, "restoring the protected entry's placement works")
    assert_eq(MenuOrderManager:getParentMenu(view, PROTECTED_ID), "more_tools",
        "protected entry back under More tools")
    assert_eq(MenuOrderManager:setItemHidden(view, PROTECTED_ID, true, "tools"), false,
        "protection still gates hiding afterwards")
    close_all_windows()
end

print("\n--- R5: search-path action restores and refreshes ---")
do
    wipe_state()
    launch({})
    close_all_windows()
    -- Move a STOCK entry (opds) out of its home, then restore via the
    -- action dialog that search results open.
    MenuOrderManager:moveItemToMenu(view, "opds", "search", "tools")
    MenuOrderManager:saveOrder(view)

    local refreshed = false
    UIScreens:showItemActionDialog({ ui = mock_ui_fm }, view, "tools",
        "opds", 1, function() refreshed = true end)
    local action_dialog
    for i = #UIManager._window_stack, 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w and w.item_table and w.title ~= nil then action_dialog = w break end
    end
    assert_true(action_dialog ~= nil, "action dialog opens from search results")
    local restore_action
    for __, action in ipairs(action_dialog.item_table) do
        if action.text == _("Restore default placement") then restore_action = action end
    end
    assert_true(restore_action ~= nil, "search actions offer restore-default")
    restore_action.callback()
    assert_eq(MenuOrderManager:getParentMenu(view, "opds"), "search",
        "search-path restore returns opds to Search")
    assert_true(refreshed, "update callback invoked after success")
    close_all_windows()
end

print("\n--- R6: editor shows the restored position ---")
do
    wipe_state()
    launch({})
    close_all_windows()
    -- Plugin management is an FM-native entry, so it renders in mock editors;
    -- its stock slot sits between a separator and patch_management.
    MenuOrderManager:moveItemToMenu(view, "plugin_management", "more_tools", "tools")
    MenuOrderManager:saveOrder(view)

    local ok = MenuOrderManager:restoreItemDefault(view, "plugin_management")
    assert_true(ok, "restore succeeds")
    MenuOrderManager:saveOrder(view)

    local editor = open_editor("more_tools")
    local row = row_for(editor, "plugin_management")
    assert_true(row ~= nil, "restored item listed in the editor")
    assert_eq(row.checked_func(), true, "restored item shown as checked")
    local mt = MenuOrderManager:getMenuItems(view, "more_tools")
    local idx = list_positions("more_tools", "plugin_management")[1]
    assert_eq(tostring(mt[idx - 1]), MenuOrderManager.SEPARATOR_ID,
        "editor reflects the curated stock predecessor")
    assert_eq(mt[idx + 1], "patch_management",
        "editor reflects the curated stock successor")
    close_all_windows()
end

wipe_state()
close_all_windows()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

--[[--
Editor visibility-toggle flow: hiding and unhiding must immediately update the
editor model, not just the saved state.

Previously, tapping the checkbox on a dimmed hidden row flipped the flag in
memory while the row itself stayed stuck in the hidden section looking
unchanged - users concluded unhiding was broken (and closing via X could then
discard the "invisible" restore). The same applied in reverse when hiding via
checkbox or hold dialog. These tests lock in that both directions relocate the
row between the visible block and the trailing hidden section, register as
unsaved changes, and persist through save.
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

local ITEM_A = "toggle_item_a"
local ITEM_B = "toggle_item_b"

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

local MenuOrderManager = require("menuorder_manager")
local UIScreens = require("ui_screens")

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
    MenuOrderManager.default_orders[view] = nil
    MenuOrderManager.recent_moves[view] = {}
end

local function close_all_windows()
    while #(UIManager._window_stack or {}) > 0 do
        local entry = UIManager._window_stack[#UIManager._window_stack]
        local w = entry and (entry.widget or entry)
        UIManager:close(w)
    end
end

local stub_a = make_stub(ITEM_A, "more_tools")
local stub_b = make_stub(ITEM_B, "more_tools")

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

local function open_editor()
    UIScreens:showItemSortWidget({ ui = mock_ui_fm }, view, "more_tools")
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

local function first_hidden_row_index(editor)
    for i, row in ipairs(editor.item_table) do
        if row.is_hidden_row then return i end
    end
end

local function find_prompt()
    for i = #UIManager._window_stack, 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w and w.ok_text ~= nil then return w end
    end
end

local function dismiss_prompt(prompt, pick)
    if pick == "save" then prompt.ok_callback()
    elseif pick == "discard" then prompt.other_buttons[1][1].callback() end
    UIManager:close(prompt)
end

print("===============================================================")
print("=== Hide/unhide updates the editor model immediately        ===")
print("===============================================================")

wipe_state()
launch({ stub_a, stub_b })
close_all_windows()

-- -------------------------------------------------------------------------
print("\n--- Unhide via the dimmed row's checkbox ---")
do
    MenuOrderManager:setItemHidden(view, ITEM_A, true, "more_tools")
    MenuOrderManager:setItemHidden(view, ITEM_B, true, "more_tools")
    MenuOrderManager:saveOrder(view)

    local editor = open_editor()
    local row_a = row_for(editor, ITEM_A)
    assert_true(row_a ~= nil and row_a.is_hidden_row,
        "hidden item starts in the hidden section, dimmed")
    assert_true(tostring(row_a.text):find(_("hidden"), 1, true) ~= nil,
        "hidden row is labelled (hidden)")
    row_a.callback()

    assert_eq(MenuOrderManager:isItemHidden(view, ITEM_A), false,
        "checkbox unhide flips the saved-state flag")
    assert_true(row_a.is_hidden_row == nil and not row_a.dim,
        "row leaves the hidden section immediately")
    assert_eq(row_a.checked_func(), true,
        "restored row's checkbox now shows checked")
    assert_true(tostring(row_a.text):find(_("hidden"), 1, true) == nil,
        "restored row no longer says (hidden)")
    local hidden_idx = first_hidden_row_index(editor)
    local row_a_idx
    for i, r in ipairs(editor.item_table) do
        if r == row_a then row_a_idx = i break end
    end
    assert_true(row_a_idx ~= nil and (hidden_idx == nil or row_a_idx < hidden_idx),
        "restored row sits at the end of the visible block")

    -- The restore registers as an unsaved change.
    editor.title_bar.right_button.callback()
    local prompt = find_prompt()
    assert_true(prompt ~= nil, "restore counts as an unsaved change")
    dismiss_prompt(prompt, "save")
    close_all_windows()

    drop_session_caches()
    local menu = launch({ stub_a, stub_b })
    local children = {}
    local node = require("ui/menusorter"):findById(menu.tab_item_table, "more_tools")
    for __, c in ipairs(node and (node.sub_item_table or node) or {}) do
        children[#children + 1] = tostring(c.id)
    end
    local found = false
    for _, id in ipairs(children) do
        if id == ITEM_A then found = true end
    end
    assert_true(found, "restored item persists and renders after restart simulation")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- Hide via the visible row's checkbox ---")
do
    -- Section 1 deliberately left B hidden; restore it so this section can
    -- exercise hiding through the checkbox.
    MenuOrderManager:setItemHidden(view, ITEM_B, false, "more_tools")
    MenuOrderManager:saveOrder(view)
    drop_session_caches()

    local editor = open_editor()
    local row_b = row_for(editor, ITEM_B)
    assert_true(row_b ~= nil and not row_b.is_hidden_row, "item B starts visible")
    row_b.callback()

    assert_true(MenuOrderManager:isItemHidden(view, ITEM_B), "checkbox hides the item")
    assert_true(row_b.is_hidden_row and row_b.dim,
        "row relocates into the hidden section immediately")
    assert_eq(row_b.checked_func(), false,
        "hidden row's checkbox now shows unchecked")
    assert_true(tostring(row_b.text):find(_("hidden"), 1, true) ~= nil,
        "newly hidden row is labelled (hidden)")
    local idx_b
    for i, r in ipairs(editor.item_table) do
        if r == row_b then idx_b = i break end
    end
    assert_eq(idx_b, #editor.item_table,
        "newly hidden row appended after previously hidden rows")

    editor.footer_ok.callback() -- bottom check icon saves and closes
    close_all_windows()
    drop_session_caches()
    local menu = launch({ stub_a, stub_b })
    local node = require("ui/menusorter"):findById(menu.tab_item_table, "more_tools")
    local found = false
    for __, c in ipairs(node and (node.sub_item_table or node) or {}) do
        if tostring(c.id) == ITEM_B then found = true break end
    end
    assert_eq(found, false, "hide persists across restart simulation")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- Hold dialog paths ---")
do
    -- Restore via hold dialog on the hidden B row.
    local editor = open_editor()
    local row_b = row_for(editor, ITEM_B)
    assert_true(row_b ~= nil and row_b.is_hidden_row, "B is offered as hidden")
    row_b.hold_callback(row_b)
    local confirm
    for i = #UIManager._window_stack, 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w and w.ok_text ~= nil then confirm = w break end
    end
    assert_true(confirm ~= nil, "hold dialog offers a restore confirmation")
    confirm.ok_callback()
    UIManager:close(confirm)
    assert_eq(MenuOrderManager:isItemHidden(view, ITEM_B), false,
        "Restore confirmation unhides the item")
    assert_true(row_b.is_hidden_row == nil,
        "Restore moves the row back into the visible block")
    assert_eq(row_b.checked_func(), true,
        "Restore fixes the checkbox state")
    assert_true(tostring(row_b.text):find(_("hidden"), 1, true) == nil,
        "Restore clears the (hidden) label")
    close_all_windows()

    -- Hide via hold dialog on the visible A row.
    editor = open_editor()
    local row_a = row_for(editor, ITEM_A)
    row_a.hold_callback(row_a)
    local dialog
    for i = #UIManager._window_stack, 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w and w.buttons ~= nil then dialog = w break end
    end
    assert_true(dialog ~= nil, "hold dialog opens for a visible row")
    local hide_button
    for __, group in ipairs(dialog.buttons or {}) do
        for __, button in ipairs(group) do
            if button.text == _("Hide this item") then hide_button = button end
        end
    end
    assert_true(hide_button ~= nil, "hold dialog offers hiding")
    hide_button.callback()
    assert_true(MenuOrderManager:isItemHidden(view, ITEM_A), "hold action hides the item")
    assert_true(row_a.is_hidden_row and row_a.dim,
        "hold action relocates the row into the hidden section")
    close_all_windows()

    -- Leave clean state: unhide everything through the data layer.
    MenuOrderManager:setItemHidden(view, ITEM_A, false, "more_tools")
    MenuOrderManager:setItemHidden(view, ITEM_B, false, "more_tools")
    MenuOrderManager:saveOrder(view)
end

-- -------------------------------------------------------------------------
print("\n--- Inherited invisibility is truthful (no misleading restore) ---")
do
    -- Hide a whole submenu level, then unhide a child alone: the child must
    -- report hidden_by_ancestor (not visible) until its path is revealed.
    MenuOrderManager:setItemHidden(view, "more_tools", true, "tools")
    MenuOrderManager:setItemHidden(view, ITEM_A, true, "more_tools")
    MenuOrderManager:saveOrder(view)
    MenuOrderManager:setItemHidden(view, ITEM_A, false, "more_tools")
    MenuOrderManager:saveOrder(view)
    local st = MenuOrderManager:getVisibilityStatus(view, ITEM_A)
    assert_true(type(st) == "table" and st.state == "hidden_by_ancestor",
        "inherited invisibility reports hidden_by_ancestor (got "
        .. tostring(st and st.state) .. ")")
    assert_true(MenuOrderManager:isItemHidden(view, ITEM_A) == false,
        "explicit flag cleared while effectively hidden")
    assert_true(MenuOrderManager:revealHiddenPath(view, ITEM_A),
        "deliberate reveal-path stages ancestors only")
    MenuOrderManager:saveOrder(view)
    local st2 = MenuOrderManager:getVisibilityStatus(view, ITEM_A)
    assert_true(st2.state == "visible", "revealed child reports visible")
    MenuOrderManager:setItemHidden(view, ITEM_A, false, "more_tools")
    MenuOrderManager:setItemHidden(view, "more_tools", false, "tools")
    MenuOrderManager:saveOrder(view)
end

wipe_state()
close_all_windows()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

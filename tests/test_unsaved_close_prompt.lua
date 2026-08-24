--[[--
Regression tests for the unsaved-changes prompt on the editor title-bar X.

Clicking the X of a Reorder menus editor must detect unsaved edits and ask
whether to save or discard them (or cancel and keep editing). The bottom
buttons keep their original behaviour: the check icon saves and closes, the
exit icon closes directly - neither may ever spawn the prompt.

Covered dirty sources: staged reordering/sort/separator model changes, and
visibility toggles, which mutate the working order immediately but are only
persisted on save. Discard reverts both by reloading the working order from
disk, exactly like a restart would.
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

require("main") -- installs the sorting-hint safety guard exactly like a launch

local view = "filemanager"
local settings_dir = DataStorage:getSettingsDir()
local ORDER_FILE = settings_dir .. "/" .. view .. "_menu_order.lua"
local STATE_FILE = settings_dir .. "/reorderingmenus_state.lua"

local ACTIVE_ID = "plugin_item_a"

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

wipe_state = nil
do
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
end

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

local stub = {
    ui = nil,
    addToMainMenu = function(self, menu_items)
        if not self.ui.view then
            menu_items[ACTIVE_ID] = {
                text = _("Plugin A"),
                sorting_hint = "more_tools",
                callback = function() end,
            }
            menu_items.reordering_menus = {
                text = _("Reorder menus"),
                sorting_hint = "more_tools",
                callback = function() end,
            }
        end
    end,
}
stub.ui = mock_ui_fm

local fm = FileManagerMenu:new{ ui = mock_ui_fm }
mock_ui_fm.menu = fm
fm.registered_widgets.stub = stub
fm:setUpdateItemTable()
UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, true)

local function stack_size() return #UIManager._window_stack end

local function close_all_windows()
    while stack_size() > 0 do
        local entry = UIManager._window_stack[stack_size()]
        local w = entry and (entry.widget or entry)
        if w and w.onClose then w:onClose() else UIManager:close(w) end
    end
end

local function find_editor()
    for i = stack_size(), 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w and w.item_table and w._populateItems and w.marked ~= nil then
            return w
        end
    end
end

local function find_prompt()
    for i = stack_size(), 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        -- ConfirmBox carries ok_text; the restart prompt uses different text
        -- and is scheduled through nextTick, which never runs in these tests.
        if w and w.ok_text ~= nil then return w end
    end
end

local function dismiss_prompt(prompt, pick)
    -- Invoke the chosen action the way the button wrapper would...
    if pick == "save" then
        prompt.ok_callback()
    elseif pick == "discard" then
        prompt.other_buttons[1][1].callback()
    elseif pick == "cancel" then
        prompt.cancel_callback()
    end
    -- ...then close the dialog itself, as ConfirmBox's button wrapper does.
    UIManager:close(prompt)
end

local function open_item_editor()
    UIScreens:showItemSortWidget({ ui = mock_ui_fm }, view, "more_tools")
    local editor = find_editor()
    assert_true(editor ~= nil, "item editor opens")
    return editor
end

local function saved_more_tools()
    local out = {}
    for __, id in ipairs(MenuOrderManager:getMenuItems(view, "more_tools")) do
        table.insert(out, tostring(id))
    end
    return table.concat(out, ",")
end

local function swap_first_two(widget)
    widget.item_table[1], widget.item_table[2] = widget.item_table[2], widget.item_table[1]
end

print("===============================================================")
print("=== Unsaved-changes prompt on editor close                  ===")
print("===============================================================")

-- -------------------------------------------------------------------------
print("\n--- Clean close does not prompt ---")
do
    local editor = open_item_editor()
    editor.title_bar.right_button.callback()
    assert_true(find_editor() == nil, "clean X closes the editor")
    assert_true(find_prompt() == nil, "clean X shows no prompt")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- Staged reordering: Cancel keeps everything open ---")
do
    local baseline = saved_more_tools()
    local editor = open_item_editor()
    swap_first_two(editor)
    editor.title_bar.right_button.callback()
    local prompt = find_prompt()
    assert_true(prompt ~= nil, "X with staged reordering asks what to do")
    assert_true(find_editor() ~= nil, "editor stays open while asking")
    dismiss_prompt(prompt, "cancel")
    assert_true(find_prompt() == nil, "Cancel dismisses the prompt")
    assert_true(find_editor() ~= nil, "Cancel keeps the editor open")
    assert_eq(saved_more_tools(), baseline, "Cancel saves nothing")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- Staged reordering: Save persists to memory and disk ---")
do
    local editor = open_item_editor()
    swap_first_two(editor)
    editor.title_bar.right_button.callback()
    local prompt = find_prompt()
    assert_true(prompt ~= nil, "Save prompt shown for staged reordering")
    dismiss_prompt(prompt, "save")
    assert_true(find_editor() == nil, "Save closes the editor")
    assert_true(find_prompt() == nil, "No stray dialogs remain")
    local mem_head = MenuOrderManager:getMenuItems(view, "more_tools")[1]
    drop_session_caches()
    local disk_head = MenuOrderManager:getMenuItems(view, "more_tools")[1]
    assert_eq(disk_head, tostring(mem_head), "Saved ordering survived a restart simulation")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- Staged reordering: Discard reverts ---")
do
    local baseline = saved_more_tools()
    local editor = open_item_editor()
    swap_first_two(editor)
    editor.title_bar.right_button.callback()
    local prompt = find_prompt()
    assert_true(prompt ~= nil, "Discard path shows the prompt")
    dismiss_prompt(prompt, "discard")
    assert_true(find_editor() == nil, "Discard closes the editor")
    assert_eq(saved_more_tools(), baseline, "Discard restored the saved ordering")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- Visibility toggles are tracked too ---")
do
    local editor = open_item_editor()
    local row
    for __, r in ipairs(editor.item_table) do
        if r.item_id == ACTIVE_ID then row = r break end
    end
    assert_true(row ~= nil, "plugin row present in editor")
    row.callback() -- hides immediately in the working order
    assert_true(MenuOrderManager:isItemHidden(view, ACTIVE_ID),
        "toggle hid the item in memory")
    editor.title_bar.right_button.callback()
    local prompt = find_prompt()
    assert_true(prompt ~= nil, "X after an unsaved toggle asks what to do")
    dismiss_prompt(prompt, "discard")
    assert_eq(MenuOrderManager:isItemHidden(view, ACTIVE_ID), false,
        "Discard reverted the visibility toggle")

    editor = open_item_editor()
    for __, r in ipairs(editor.item_table) do
        if r.item_id == ACTIVE_ID then row = r break end
    end
    row.callback()
    editor.title_bar.right_button.callback()
    prompt = find_prompt()
    dismiss_prompt(prompt, "save")
    drop_session_caches()
    assert_true(MenuOrderManager:isItemHidden(view, ACTIVE_ID),
        "Save persisted the toggle across a restart simulation")
    MenuOrderManager:setItemHidden(view, ACTIVE_ID, false, "more_tools")
    MenuOrderManager:saveOrder(view)
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- Bottom buttons keep working without prompting ---")
do
    local baseline = saved_more_tools()
    local editor = open_item_editor()
    swap_first_two(editor)
    editor.footer_cancel.callback()
    assert_true(find_editor() == nil, "bottom exit icon closes directly")
    assert_true(find_prompt() == nil, "bottom exit icon never prompts")
    assert_eq(saved_more_tools(), baseline, "bottom exit icon discards staged edits as before")

    editor = open_item_editor()
    swap_first_two(editor)
    editor.footer_ok.callback()
    assert_true(find_editor() == nil, "bottom check icon saves and closes")
    assert_true(find_prompt() == nil, "bottom check icon never double-prompts")
    assert_true(saved_more_tools() ~= baseline, "bottom check icon applied the edit")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- Tab screen: same prompt behaviour ---")
do
    local original_tabs = {}
    for __, t in ipairs(MenuOrderManager:getTabs(view)) do
        table.insert(original_tabs, tostring(t))
    end
    local baseline = table.concat(original_tabs, ",")

    UIScreens:showTabReorderDialog({ ui = mock_ui_fm }, view)
    local tabs_widget = find_editor()
    assert_true(tabs_widget ~= nil, "tab screen opens")
    swap_first_two(tabs_widget)
    tabs_widget.title_bar.right_button.callback()
    local prompt = find_prompt()
    assert_true(prompt ~= nil, "tab screen X asks about unsaved changes")
    assert_true(find_editor() ~= nil, "tab screen stays open while asking")
    dismiss_prompt(prompt, "cancel")
    assert_true(find_editor() ~= nil, "Cancel keeps the tab screen open")

    tabs_widget.title_bar.right_button.callback()
    prompt = find_prompt()
    dismiss_prompt(prompt, "discard")
    assert_true(find_editor() == nil, "Discard closes the tab screen")
    local tabs_now = {}
    for __, t in ipairs(MenuOrderManager:getTabs(view)) do
        table.insert(tabs_now, tostring(t))
    end
    assert_eq(table.concat(tabs_now, ","), baseline, "Discard restored the tab order")

    UIScreens:showTabReorderDialog({ ui = mock_ui_fm }, view)
    tabs_widget = find_editor()
    swap_first_two(tabs_widget)
    tabs_widget.title_bar.right_button.callback()
    prompt = find_prompt()
    dismiss_prompt(prompt, "save")
    tabs_now = {}
    for __, t in ipairs(MenuOrderManager:getTabs(view)) do
        table.insert(tabs_now, tostring(t))
    end
    assert_true(table.concat(tabs_now, ",") ~= baseline,
        "tab-screen Save applied the new order")
    close_all_windows()
end

wipe_state = nil
os.remove(ORDER_FILE)
os.remove(STATE_FILE)
close_all_windows()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

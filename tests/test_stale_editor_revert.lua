--[[--
Regression test for the stale-stacked-editor move revert.

Drill-down keeps the destination editor (e.g. Tools) alive underneath the
source editor (e.g. More tools). Moving an item up to Tools used to be
silently reverted when the stale Tools editor was confirmed afterwards: its
outdated rows were saved over the configuration, the item became orphaned,
and reconciliation re-anchored it to its stock parent (more_tools).

The test drives the real UI: both editors, the hold dialog, the destination
chooser, and the stale editor's OK callback.
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
local MenuOrderManager = require("lib.menuorder_manager")
local UIScreens = require("lib.ui_screens")
local ReorderingMenus = require("main")

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or ""))
    else
        failed = failed + 1
        io.stdout:flush()
        print("  [FAIL] " .. (msg or "") .. string.format(" -> expected %s, got %s",
            tostring(expected), tostring(actual)))
    end
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end

local mock_ui_fm = {
    file_chooser = {
        show_hidden = false,
        show_unsupported = false,
        items_per_page_default = 14,
        collates = { filename = { text = "Filename", menu_order = 1 } },
        getCollate = function() return nil, "filename" end,
        refreshPath = function() end,
        toggleShowFilesMode = function() end,
    },
    registerTouchZones = function() end,
    onSetSortBy = function() end,
    registerModule = function(self, name, mod) self[name] = mod end,
}
local view = "filemanager"
-- Reset persisted + cached state BEFORE anything is built, so leftover
-- files from previous runs cannot leak into this session.
os.remove(DataStorage:getSettingsDir() .. "/" .. view .. "_menu_order.lua")
os.remove(DataStorage:getSettingsDir() .. "/reorderingmenus_state.lua")
package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
MenuOrderManager.orders[view] = nil
MenuOrderManager.default_orders[view] = nil
MenuOrderManager.recent_moves[view] = {}

local fm_menu = FileManagerMenu:new{ ui = mock_ui_fm }
mock_ui_fm.menu = fm_menu
local plugin = ReorderingMenus:new{ ui = mock_ui_fm }
plugin.ui = mock_ui_fm
-- Stub the stock plugins that own the items this test moves, then build the
-- live menu once (a second build would crash: MenuSorter consumes menu_items).
fm_menu.registered_widgets.terminal_stub = {
    addToMainMenu = function(self, menu_items)
        menu_items.terminal = { text = _("Terminal"), sorting_hint = "more_tools",
            callback = function() end }
    end,
}
fm_menu.registered_widgets.batterystat_stub = {
    addToMainMenu = function(self, menu_items)
        menu_items.battery_statistics = { text = _("Battery statistics"),
            sorting_hint = "more_tools", callback = function() end }
    end,
}
fm_menu:registerToMainMenu(plugin)
fm_menu:setUpdateItemTable()

local function parent_of(item) return MenuOrderManager:getParentMenu(view, item) end
local function top_widget()
    for i = #UIManager._window_stack, 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w and w.item_table and w._populateItems and w.marked ~= nil then
            return w
        end
    end
end
local function close_top_widgets_until(n)
    while #UIManager._window_stack > n do
        local entry = UIManager._window_stack[#UIManager._window_stack]
        local w = entry and (entry.widget or entry)
        UIManager:close(w)
    end
end

local function run_move_via_real_dialogs(from_editor, item_id)
    -- Long-press equivalent: open the row's action dialog.
    from_editor.marked = 0
    local found_row
    for _, row in ipairs(from_editor.item_table) do
        if row.item_id == item_id then found_row = row break end
    end
    if not found_row then
        error("row not found in editor: " .. item_id)
    end
    found_row.hold_callback(found_row, function() from_editor:_populateItems() end)
    local action_dialog
    for i = #UIManager._window_stack, 1, -1 do
        local candidate = UIManager._window_stack[i].widget or UIManager._window_stack[i]
        if candidate and candidate.buttontable then action_dialog = candidate break end
    end
    assert_true(action_dialog ~= nil, "hold dialog opened for " .. item_id)
    for _, row in ipairs(action_dialog.buttontable.buttons) do
        for _, button in ipairs(row) do
            if button.text == "Move to another menu…" then
                button.callback()
            end
        end
    end
    local chooser
    for i = #UIManager._window_stack, 1, -1 do
        local candidate = UIManager._window_stack[i].widget or UIManager._window_stack[i]
        if candidate and candidate.item_table and candidate.title
                and tostring(candidate.title):find("Move", 1, true) then
            chooser = candidate
            break
        end
    end
    assert_true(chooser ~= nil, "destination chooser opened")
    local chosen = false
    for _, entry in ipairs(chooser.item_table) do
        if entry.text == "[Tab] Tools" then
            entry.callback()
            chosen = true
            break
        end
    end
    assert_true(chosen, "Tools listed as a destination")
    close_top_widgets_until(1)
end

print("===============================================================")
print("=== Stale Stacked Editor Move Revert Regression             ===")
print("===============================================================")

assert_eq(parent_of("terminal"), "more_tools", "terminal starts in More tools")

-- 1. Destination editor opened first (drill-down parent), holding pre-move rows.
UIScreens:showItemSortWidget(plugin, view, "tools")
local tools_editor = top_widget()
assert_true(tools_editor ~= nil, "Tools editor open")

-- 2. Source editor stacked on top of it.
UIScreens:showItemSortWidget(plugin, view, "more_tools")
local more_tools_editor = top_widget()
assert_true(more_tools_editor ~= nil and more_tools_editor ~= tools_editor,
    "More tools editor stacked above Tools editor")

-- 3. Move terminal to Tools through the real dialogs.
run_move_via_real_dialogs(more_tools_editor, "terminal")
assert_eq(parent_of("terminal"), "tools", "terminal configured under Tools after move")
assert_true(#UIManager._window_stack >= 1, "Tools editor still open below")

-- 4. Confirm the stale Tools editor (what a user naturally does next).
tools_editor:onReturn()

assert_eq(parent_of("terminal"), "tools",
    "stale Tools editor confirmation keeps terminal in Tools")
assert_eq(parent_of("reordering_menus"), "more_tools",
    "other items unaffected")

-- 5. Symmetric case: a stale SOURCE editor must not resurrect a moved-away item.
UIScreens:showItemSortWidget(plugin, view, "more_tools")
local second_more_tools_editor = top_widget()
UIScreens:showDestinationMenuChooser(plugin, view, "battery_statistics", "more_tools",
    function() end, nil)
local chooser2
for i = #UIManager._window_stack, 1, -1 do
    local candidate = UIManager._window_stack[i].widget or UIManager._window_stack[i]
    if candidate and candidate.item_table and candidate.title
            and tostring(candidate.title):find("Move", 1, true) then
        chooser2 = candidate
        break
    end
end
if chooser2 then
    for _, entry in ipairs(chooser2.item_table) do
        if entry.text == "[Tab] Tools" then entry.callback() break end
    end
    close_top_widgets_until(0)
    assert_eq(parent_of("battery_statistics"), "tools", "second move succeeds")
    second_more_tools_editor:onReturn()
    assert_eq(parent_of("battery_statistics"), "tools",
        "stale source editor does not resurrect moved item")
else
    close_top_widgets_until(0)
end

-- Cleanup
close_top_widgets_until(0)
os.remove(DataStorage:getSettingsDir() .. "/" .. view .. "_menu_order.lua")

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

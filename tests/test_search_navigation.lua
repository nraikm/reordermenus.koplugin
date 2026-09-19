-- Search results navigate by stable ID without selecting rows for movement.
dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir()
    .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()

local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local Blitbuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")

require("main")

local ReaderMenu = require("apps/reader/modules/readermenu")
local MenuOrderManager = require("lib.menuorder_manager")
local UIScreens = require("lib.ui_screens")
local ReorderingMenus = require("main")

local passed, failed = 0, 0
local function note(cond, msg)
    if cond then passed = passed + 1
    else failed = failed + 1; print("  [FAIL] " .. tostring(msg)); io.stdout:flush() end
end

local mock_ui_reader = {
    document = { file = "/tmp/arrow_nav_probe.epub", configurable = {} },
    doc_settings = {
        isTrue = function() return false end,
        makeFalse = function() end,
        makeTrue = function() end,
    },
    saveSettings = function() end,
    registerTouchZones = function() end,
    onClose = function() end,
    showFileManager = function() end,
    registerModule = function(self, name, mod) self[name] = mod end,
}

local reader_menu = ReaderMenu:new{ ui = mock_ui_reader }
mock_ui_reader.menu = reader_menu
local plugin = ReorderingMenus:new{ ui = mock_ui_reader }
reader_menu:registerToMainMenu(plugin)

local VIEW = "reader"

local function wipe()
    for _, f in ipairs({ "reader_menu_order.lua", "filemanager_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        pcall(os.remove, DataStorage:getSettingsDir() .. "/" .. f)
    end
    MenuOrderManager:dropSessionState("reader")
    MenuOrderManager:dropSessionState("filemanager")
end

local function close_all()
    while #UIManager._window_stack > 0 do
        local entry = UIManager._window_stack[#UIManager._window_stack]
        local w = entry and (entry.widget or entry)
        if w then UIManager:close(w) else break end
    end
end

local function top_editor()
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget
            or UIManager._window_stack[i]
        if w and w.item_table and w._populateItems and w.marked ~= nil then
            return w
        end
    end
end

local function paint(editor)
    local bb = Blitbuffer.new(Screen:getWidth(), Screen:getHeight())
    editor:paintTo(bb, 0, 0)
    bb:free()
end

local function row_widget(editor, item_id)
    for _, entry in ipairs(editor.layout or {}) do
        local row = entry and entry[1]
        if row and row.item and row.item.item_id == item_id
                and row.show_parent == editor then
            return row
        end
    end
end

local IntentStore = require("lib.intent_store")
local util = require("util")
local function top()
    local entry = UIManager._window_stack[#UIManager._window_stack]
    return entry and (entry.widget or entry)
end
local function search(id)
    UIScreens:showSearchResults(plugin, VIEW, id)
    local results = top()
    assert(results and results.item_table and #results.item_table == 1,
        "expected exactly one search result for " .. id)
    return results
end
local function check_focus(ed, id)
    assert(ed and ed.marked ~= nil, "editor opened")
    local index
    for i, row in ipairs(ed.item_table) do
        if row.item_id == id then index = i break end
    end
    assert(index, "target is in editor")
    note(ed.show_page == math.ceil(index / ed.items_per_page), "target page shown")
    note(ed.selected.y == index - (ed.show_page - 1) * ed.items_per_page,
        "focus points at target row")
    local row = row_widget(ed, id)
    note(row and row[1]._focused == true, "target has a visible focus border")
    note(ed.marked == 0, "navigation does not mark target for moving")
    paint(ed)
    return index
end

wipe()
MenuOrderManager:resetOrder(VIEW)
close_all()
-- Custom submenus are renderable stable IDs, including duplicate labels.
local ids = {}
for i = 1, 45 do
    local ok, id = MenuOrderManager:createSubmenu(VIEW, "tools", "Search navigation row", nil)
    assert(ok)
    ids[i] = id
end
assert(MenuOrderManager:saveOrder(VIEW))
local target = ids[#ids]
local before = util.tableDeepCopy(IntentStore.view(VIEW))
local before_order = MenuOrderManager:loadOrder(VIEW)
local results = search(target)
local draft_before = util.tableDeepCopy(MenuOrderManager:peekTransaction():view(VIEW))
-- Force the touch-only case: focus must still be visible without a D-pad.
local original_has_dpad = Device.hasDPad
Device.hasDPad = function() return false end
results.item_table[1].callback()
local ed = top_editor()
local index = check_focus(ed, target)
Device.hasDPad = original_has_dpad
note(ed.show_page > 1, "late result opens beyond first page")
note(row_widget(ed, target).item.is_submenu, "submenu result opens its host, not its contents")
local rows_before = {}
for i, row in ipairs(ed.item_table) do rows_before[i] = row.item_id end
ed:onPrevPage()
ed:onNextPage()
local rows_after = {}
for i, row in ipairs(ed.item_table) do rows_after[i] = row.item_id end
note(util.tableEquals(rows_before, rows_after), "paging after navigation does not reorder rows")
UIManager:close(ed)
note(top() == results, "closing editor returns to same results without a save prompt")
note(util.tableEquals(before, IntentStore.view(VIEW)), "navigation leaves canonical intent unchanged")
note(util.tableEquals(draft_before, MenuOrderManager:peekTransaction():view(VIEW)),
    "navigation leaves staged intent unchanged")
note(util.tableEquals(before_order, MenuOrderManager:loadOrder(VIEW)), "navigation leaves projection unchanged")
close_all()

-- Ordinary rows use the same focus path without executing their callback.
results = search("plugin_management")
results.item_table[1].callback()
ed = top_editor()
check_focus(ed, "plugin_management")
note(not row_widget(ed, "plugin_management").item.is_submenu, "ordinary item opens in its host")
close_all()

-- Resolve current host at click time, even with stale results.
results = search(target)
assert(MenuOrderManager:moveItemToMenu(VIEW, target, "tools", "more_tools"))
assert(MenuOrderManager:saveOrder(VIEW))
results.item_table[1].callback()
ed = top_editor()
check_focus(ed, target)
note(not ed.item_table[index] or ed.item_table[index].item_id ~= target,
    "stale search index is not reused")
note(MenuOrderManager:getParentMenu(VIEW, target) == "more_tools", "result follows moved item")
close_all()

-- Hidden results navigate without unhiding or saving, in either display mode.
assert(MenuOrderManager:setItemHidden(VIEW, target, true, "more_tools"))
assert(MenuOrderManager:saveOrder(VIEW))
for _, in_place in ipairs({true, false}) do
    MenuOrderManager:setHiddenInPlace(in_place)
    before = util.tableDeepCopy(IntentStore.view(VIEW))
    results = search(target)
    results.item_table[1].callback()
    ed = top_editor()
    check_focus(ed, target)
    note(MenuOrderManager:isItemHidden(VIEW, target), "search does not unhide target")
    note(util.tableEquals(before, IntentStore.view(VIEW)), "hidden navigation does not save")
    close_all()
end

-- Removed result: notice only, no empty editor or leaked compatibility hook.
local removed = ids[1]
results = search(removed)
assert(MenuOrderManager:deleteCustomSubmenu(VIEW, removed))
assert(MenuOrderManager:saveOrder(VIEW))
results.item_table[1].callback()
note(top_editor() == nil, "deleted result does not open an editor")
note(top().text and top().text:find("no longer available", 1, true), "deleted result reports stale location")
close_all()

-- A stale/unrenderable ID must fail before opening or registering an editor.
UIScreens:showItemSortWidget(plugin, VIEW, "tools", nil, nil, "missing_search_target")
note(top_editor() == nil, "missing display row does not open an empty editor")
close_all()
UIScreens:showTabReorderDialog(plugin, VIEW, nil, "missing_search_target")
note(top_editor() == nil, "missing tab row does not open an empty editor")
close_all()

-- Hidden tabs use the tab editor and remain hidden.
assert(MenuOrderManager:setTabHidden(VIEW, "search", true))
assert(MenuOrderManager:saveOrder(VIEW))
UIScreens:showSearchResults(plugin, VIEW, "search")
results = top()
local hidden_tab_result
for _, row in ipairs(results.item_table) do
    if row.text:find("[Hidden] " .. UIScreens:getDisplayTitle(VIEW, "search") .. " [", 1, true) then hidden_tab_result = row break end
end
assert(hidden_tab_result, "hidden tab search result")
hidden_tab_result.callback()
ed = top_editor()
check_focus(ed, "search")
note(MenuOrderManager:isItemHidden(VIEW, "search"), "tab navigation keeps tab hidden")
close_all()

print(string.format("Search navigation: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end

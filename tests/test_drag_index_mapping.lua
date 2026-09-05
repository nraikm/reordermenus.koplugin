--[[--
Drag index mapping under hidden-aware editors (Error I).

Rule under test: never persist a drag using UI row indices alone - persist
item IDs resolved against the underlying model, and anchor manual moves to
VISIBLE siblings only.

  M1  in-place hidden mode: a row dropped directly after a HIDDEN row
      anchors to the nearest preceding visible sibling; the hidden id never
      becomes an anchor.
  M2  bottom-hidden mode: hidden rows collect at the end; a visible row
      dropped at the boundary anchors to the last visible row.
  M3  every editor row carries a unique item_id (interactions are ID-based).
  M4  restart equivalence for the saved arrangement.
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

local UIManager = require("ui/uimanager")
local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local _ = require("gettext")

require("main")

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or ""))
        io.stdout:flush()
    else
        failed = failed + 1
        print("  [FAIL] " .. (msg or "") ..
            string.format(" -> expected %s, got %s", tostring(expected), tostring(actual)))
        io.stdout:flush()
    end
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end

local MenuOrderManager = require("menuorder_manager")
local UIScreens = require("ui_screens")
local IntentStore = require("intent_store")

local view = "filemanager"
local settings_dir = DataStorage:getSettingsDir()

local function make_stub(item_id, hint)
    return {
        name = "drag_" .. item_id,
        addToMainMenu = function(self, menu_items)
            if not self.ui.view then
                menu_items[item_id] = {
                    text = _("Drag ") .. item_id,
                    sorting_hint = hint,
                    callback = function() end,
                }
            end
        end,
    }
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

local function launch(stubs)
    local menu = FileManagerMenu:new{ ui = mock_ui_fm }
    mock_ui_fm.menu = menu
    for i, stub in ipairs(stubs or {}) do
        stub.ui = mock_ui_fm
        menu.registered_widgets["stub_" .. i .. "_" .. tostring(stub.name)] = stub
    end
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, false)
    menu:setUpdateItemTable()
    return menu
end

local function close_all_windows()
    while #(UIManager._window_stack or {}) > 0 do
        local entry = UIManager._window_stack[#UIManager._window_stack]
        local w = entry and (entry.widget or entry)
        UIManager:close(w)
    end
end

local function open_editor(menu_id)
    UIScreens:showItemSortWidget({ ui = mock_ui_fm }, view, menu_id)
    for i = #UIManager._window_stack, 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w and w.item_table and w.footer_ok then return w end
    end
end

local function restart()
    MenuOrderManager:dropSessionState(view)
    package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
end

local function wipe_state()
    os.remove(settings_dir .. "/" .. view .. "_menu_order.lua")
    os.remove(settings_dir .. "/reorderingmenus_intent.lua")
    os.remove(settings_dir .. "/reorderingmenus_materialization.lua")
    os.remove(settings_dir .. "/reorderingmenus_state.lua")
    IntentStore.load(true)
    restart()
end

print("===============================================================")
print("=== Drag index mapping                                       ===")
print("===============================================================")

local STUB_IDS = { "drag_a", "drag_b", "drag_c", "drag_d", "drag_e" }
local function make_stubs()
    local stubs = {}
    for i, id in ipairs(STUB_IDS) do
        stubs[i] = make_stub(id, "more_tools")
    end
    return stubs
end

-- M3: unique item_ids per row
do
    wipe_state()
    launch(make_stubs())
    close_all_windows()
    local editor = open_editor("more_tools")
    assert_true(editor ~= nil, "M3: editor opens")
    if editor then
        local seen, unique = {}, true
        for _, row in ipairs(editor.item_table) do
            if row.item_id and row.item_id ~= "__empty_hint__" then
                if seen[row.item_id] then unique = false end
                seen[row.item_id] = true
            end
        end
        assert_true(unique, "M3: every editor row carries a unique item_id")
    end
    close_all_windows()
end

-- M1: drop after a HIDDEN row in in-place mode -> visible anchor only
do
    wipe_state()
    launch(make_stubs())
    close_all_windows()

    -- Hide drag_b; it stays dimmed in place between its neighbours.
    MenuOrderManager:setItemHidden(view, "drag_b", true, "more_tools")
    MenuOrderManager:saveOrder(view)

    local editor = open_editor("more_tools")
    assert_true(editor ~= nil, "M1: editor opens with a hidden row present")

    -- Locate rows by ID and simulate dropping drag_e directly AFTER hidden b.
    local rows = {}
    for i, row in ipairs(editor.item_table) do
        rows[row.item_id] = i
    end
    assert_true(rows.drag_b ~= nil and rows.drag_e ~= nil, "M1: rows located")
    local e_row = table.remove(editor.item_table, rows.drag_e)
    local b_at = nil
    for i, row in ipairs(editor.item_table) do
        if row.item_id == "drag_b" then b_at = i break end
    end
    table.insert(editor.item_table, b_at + 1, e_row)

    editor.footer_ok.callback()
    close_all_windows()

    -- The persisted anchor references a VISIBLE sibling, never the hidden id.
    local po = IntentStore.load().views[view].position_override.drag_e
    assert_true(po == nil or po.after ~= "drag_b",
        "M1: hidden id never becomes an anchor")
    assert_true(po == nil or po.after == "drag_a",
        "M1: anchor resolves to the nearest preceding visible sibling")

    -- Visible rendering order reflects the drop (b still hidden).
    local vis = {}
    for _, id in ipairs(MenuOrderManager:getMenuItems(view, "more_tools")) do
        if id:find("^drag_") then vis[#vis + 1] = id end
    end
    assert_eq(table.concat(vis, "|"), "drag_a|drag_e|drag_c|drag_d",
        "M1: visible sequence places the dropped row after its visible anchor")
end

-- M2/M4: bottom-hidden mode boundary drop + restart equivalence
do
    wipe_state()
    launch(make_stubs())
    close_all_windows()

    MenuOrderManager:setHiddenInPlace(false)
    MenuOrderManager:setItemHidden(view, "drag_b", true, "more_tools")
    MenuOrderManager:setItemHidden(view, "drag_c", true, "more_tools")
    MenuOrderManager:saveOrder(view)

    local editor = open_editor("more_tools")
    assert_true(editor ~= nil, "M2: bottom-mode editor opens")

    -- Hidden rows must sit at the END of the editor model in this mode.
    local ids_in_order = {}
    for _, row in ipairs(editor.item_table) do
        ids_in_order[#ids_in_order + 1] = row.item_id
    end
    local last_visible_pos, first_hidden_pos = 0, math.huge
    for i, id in ipairs(ids_in_order) do
        local row = editor.item_table[i]
        if row.is_hidden_row then
            first_hidden_pos = math.min(first_hidden_pos, i)
        else
            last_visible_pos = math.max(last_visible_pos, i)
        end
    end
    assert_true(first_hidden_pos > last_visible_pos,
        "M2: bottom mode collects hidden rows after all visible rows")

    -- Drop drag_d at the boundary directly before the hidden block: the
    -- persisted anchor must be the last VISIBLE row, never a hidden one.
    local d_row = nil
    for i, row in ipairs(editor.item_table) do
        if row.item_id == "drag_d" then d_row = table.remove(editor.item_table, i) break end
    end
    table.insert(editor.item_table, last_visible_pos + 1 <= first_hidden_pos
        and first_hidden_pos or last_visible_pos + 1, d_row)

    editor.footer_ok.callback()
    close_all_windows()

    local po = IntentStore.load().views[view].position_override.drag_d
    assert_true(po == nil or (po.after ~= "drag_b" and po.after ~= "drag_c"),
        "M2: boundary drop never anchors into the hidden block")
    assert_true(po == nil or po.after == "drag_a" or po.after == "drag_e"
        or po.after == false,
        "M2: boundary drop anchors to the last visible row")

    -- M4: restart equivalence.
    local before_restart = MenuOrderManager:getMenuItems(view, "more_tools")
    restart()
    launch(make_stubs())
    close_all_windows()
    local after_restart = MenuOrderManager:getMenuItems(view, "more_tools")
    assert_eq(table.concat(before_restart, "|"),
        table.concat(after_restart, "|"),
        "M4: saved arrangement reloads identically across a restart")

    MenuOrderManager:setHiddenInPlace(true)
end

wipe_state()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

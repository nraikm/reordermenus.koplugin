--[[--
User-created submenus: creation UI, persistence, KOReader rendering,
destination-chooser prioritization, deletion, and reset behaviour.
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

-- Deterministic baseline: wipe persisted menu state before this suite runs
-- (fresh process = no in-memory sessions; removing the files is enough).
do
    local _sd = DataStorage:getSettingsDir()
    for _, _name in ipairs({
        "reader_menu_order.lua", "filemanager_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua",
        "reorderingmenus_state.lua",
    }) do
        pcall(os.remove, _sd .. "/" .. _name)
    end
    -- Preset directories: leftover user presets would break count assertions.
    local _lfs = require("libs/libkoreader-lfs")
    local function _rmtree(path)
        if _lfs.attributes(path, "mode") ~= "directory" then return end
        for _entry in _lfs.dir(path) do
            if _entry ~= "." and _entry ~= ".." then
                local _full = path .. "/" .. _entry
                if _lfs.attributes(_full, "mode") == "directory" then
                    _rmtree(_full)
                else
                    pcall(os.remove, _full)
                end
            end
        end
    end
    for _, _view in ipairs({ "reader", "filemanager" }) do
        _rmtree(_sd .. "/menu_order_presets/" .. _view)
        _rmtree(_sd .. "/menu_order_presets/" .. _view .. "/submenus")
    end
end

local ReaderMenu = require("apps/reader/modules/readermenu")
local MenuSorter = require("ui/menusorter")
local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local UIScreens = require("reorderingmenus_ui_screens")
local ReorderingMenus = require("main")
local UIManager = require("ui/uimanager")
local MenuSchema = require("reorderingmenus_menu_schema")
local IntentStore = require("reorderingmenus_intent_store")

local passed = 0
local failed = 0

local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or "assertion"))
    else
        failed = failed + 1
        io.stdout:flush()
        print("  [FAIL] " .. (msg or "assertion") ..
            " -> Expected: " .. tostring(expected) .. ", Got: " .. tostring(actual))
    end
end

local function assert_true(cond, msg)
    assert_eq(not not cond, true, msg)
end

print("===============================================================")
print("=== User-Created Submenus Test                              ===")
print("===============================================================")

local mock_ui_reader = {
    document = {
        file = "/Users/Shared/minimal.epub",
        configurable = {},
    },
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

MenuOrderManager:resetOrder("reader")

local function top_widget()
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget or UIManager._window_stack[i]
        if type(w) == "table" then return w end
    end
end

local function top_button_dialog()
    for i = #UIManager._window_stack, 1, -1 do
        local candidate = UIManager._window_stack[i].widget or UIManager._window_stack[i]
        if candidate and (candidate.buttontable or candidate.button_table) then
            return candidate
        end
    end
end

local function dialog_buttons(dialog)
    if not dialog then return nil end
    if dialog.buttontable then return dialog.buttontable.buttons end
    if dialog.button_table then return dialog.button_table.buttons end
    return nil
end

local function find_button(dialog, text)
    for _, row in ipairs(dialog_buttons(dialog) or {}) do
        for _, button in ipairs(row) do
            if button.text == text then return button end
        end
    end
end

local function find_button_by_match(dialog, matcher)
    for _, row in ipairs(dialog_buttons(dialog) or {}) do
        for _, button in ipairs(row) do
            if type(button.text) == "string" and matcher(button.text) then
                return button
            end
        end
    end
end

local function close_top_widgets_until(n)
    while #UIManager._window_stack > n do
        local entry = UIManager._window_stack[#UIManager._window_stack]
        local w = entry and (entry.widget or entry)
        if w and w.onClose then w:onClose() else UIManager:close(w) end
    end
end

local function open_editor(menu_id)
    UIScreens:showItemSortWidget(plugin, "reader", menu_id)
    local editor
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget or UIManager._window_stack[i]
        if w and w.item_table and w.marked ~= nil
                and type(w._populateItems) == "function" then
            editor = w
            break
        end
    end
    assert_true(editor ~= nil, "editor opened for " .. menu_id)
    return editor
end

local function find_row(editor, item_id)
    for _, row in ipairs(editor.item_table) do
        if row.item_id == item_id then return row end
    end
end

local function top_chooser()
    for i = #UIManager._window_stack, 1, -1 do
        local candidate = UIManager._window_stack[i].widget or UIManager._window_stack[i]
        if candidate and candidate.item_table and candidate.title
                and tostring(candidate.title):find("Move", 1, true) then
            return candidate
        end
    end
end

local function live_find(menu_id)
    local menu = mock_ui_reader.menu
    if not menu or type(menu.tab_item_table) ~= "table" then return nil end
    return MenuSorter:findById(menu.tab_item_table, menu_id)
end

local function live_children_ids(menu_id)
    local node = live_find(menu_id)
    if not node then return nil end
    local ids = {}
    for _, c in ipairs(node.sub_item_table or {}) do
        table.insert(ids, tostring(c.id))
    end
    return ids
end

-- =========================================================================
print("\n--- 1. Manager API: create, register, unique ids ---")
-- =========================================================================
local ok, first_id = MenuOrderManager:createSubmenu("reader", "tools", "My Tools", 1)
assert_true(ok, "createSubmenu succeeds")
assert_true(type(first_id) == "string"
    and (first_id:match("^custom_submenu_%d+$")
        or first_id:match("^reorderingmenus:user:%x+$")),
    "created id uses a collision-safe custom scheme: " .. tostring(first_id))
assert_eq(MenuOrderManager:getMenuItems("reader", "tools")[1], first_id,
    "new submenu is inserted at the requested position")
assert_true(type(MenuOrderManager:loadOrder("reader")[first_id]) == "table",
    "content list exists for the new submenu")
assert_eq(#MenuOrderManager:loadOrder("reader")[first_id], 0,
    "new submenu starts empty")
assert_eq(MenuOrderManager:getCustomSubmenuTitle("reader", first_id), "My Tools",
    "registered display title round-trips")
assert_true(MenuOrderManager:isSubmenu("reader", first_id),
    "created submenu counts as an editable submenu")
assert_true(MenuOrderManager:isCustomSubmenu("reader", first_id),
    "created submenu is flagged as user-created")

local __, second_id = MenuOrderManager:createSubmenu("reader", "tools", "My Tools", 99)
assert_true(second_id ~= first_id, "repeated creation generates a distinct id")
assert_eq(MenuOrderManager:getMenuItems("reader", "tools")[#MenuOrderManager:getMenuItems("reader", "tools")],
    second_id, "out-of-range index clamps to bottom")

local bad_ok = MenuOrderManager:createSubmenu("reader", "tools", "   ")
assert_eq(bad_ok, false, "blank names are rejected")
local bad_parent, err_no_menu = MenuOrderManager:createSubmenu("reader", "no_such_menu", "X")
assert_eq(bad_parent, false, "unavailable parent menus are rejected")
assert_true(type(err_no_menu) == "string", "rejection carries a message")

-- =========================================================================
print("\n--- 2. Registry survives save/reload cycle ---")
-- =========================================================================
assert_eq(MenuOrderManager:getCustomSubmenuTitle("reader", first_id), "My Tools",
    "custom title is available before save")
assert_true(MenuOrderManager:saveOrder("reader"), "order saves")
MenuOrderManager.orders["reader"] = nil
assert_eq(MenuOrderManager:getCustomSubmenuTitle("reader", first_id), "My Tools",
    "titles survive a disk reload (simulated restart)")

-- =========================================================================
print("\n--- 3. Deletion rules for created submenus ---")
-- =========================================================================
do
    -- Stage a row into the created submenu through the transaction API;
    -- projections are read-only views of derived state.
    MenuOrderManager:stageList("reader", first_id, { "go_to" })
end
local del_busy, busy_err = MenuOrderManager:deleteCustomSubmenu("reader", first_id)
assert_eq(del_busy, false, "non-empty created submenu cannot be deleted")
assert_true(type(busy_err) == "string", "non-empty refusal explains why")
-- Undo the staging surgically: restoring go_to clears every record that
-- made the submenu non-empty, without discarding unrelated staged work.
MenuOrderManager:restoreItemDefault("reader", "go_to")

local del_stock, stock_err = MenuOrderManager:deleteCustomSubmenu("reader", "navi_settings")
assert_eq(del_stock, false, "stock submenus cannot be deleted via the custom path")
assert_true(type(stock_err) == "string", "stock refusal carries a message")

local order = MenuOrderManager:loadOrder("reader")
for i = #order[first_id], 1, -1 do table.remove(order[first_id], i) end
local del_ok = MenuOrderManager:deleteCustomSubmenu("reader", first_id)
assert_true(del_ok, "empty created submenu deletes cleanly")
assert_true(MenuOrderManager:getMenuItems("reader", "tools")[1] ~= first_id,
    "deleted submenu removed from its parent list")
assert_eq(MenuOrderManager:loadOrder("reader")[first_id], nil,
    "deleted submenu content list removed")
assert_eq(MenuOrderManager:getCustomSubmenuTitle("reader", first_id), nil,
    "deleted submenu unregistered")
local __, fresh_id = MenuOrderManager:createSubmenu("reader", "tools", "Reused", 1)
assert_true(fresh_id ~= first_id and fresh_id ~= second_id,
    "deleted ids are never reused")
assert_true(MenuOrderManager:deleteCustomSubmenu("reader", fresh_id),
    "cleanup deletion succeeds")

-- A hidden container is absent from the projected menu tree, but canonical
-- custom-menu membership still identifies it as deletable. Separator-only
-- content is empty for safety purposes and all related records must cascade.
local hidden_ok, hidden_id = MenuOrderManager:createSubmenu(
    "reader", "tools", "Hidden Empty", 1)
assert_true(hidden_ok, "hidden-empty custom submenu created")
MenuOrderManager:stageList("reader", hidden_id, { MenuSchema.SEPARATOR_ID })
MenuOrderManager:setItemHidden("reader", hidden_id, true, "tools")
local hidden_txn = MenuOrderManager:peekTransaction()
hidden_txn:setSeparator("reader", "delete_anchor_ref", {
    parent = "tools", after = hidden_id,
})
hidden_txn:setPositionOverride("reader", "go_to", {
    after = hidden_id, provider = "stock",
})
assert_true(MenuOrderManager:deleteCustomSubmenu("reader", hidden_id),
    "hidden separator-only custom submenu deletes cleanly")
local hidden_section = MenuOrderManager:stagedView("reader")
assert_eq(hidden_section.custom_menus[hidden_id], nil,
    "hidden custom record removed")
assert_eq(hidden_section.hidden[hidden_id], nil,
    "hidden-container tombstone removed")
assert_eq(hidden_section.parent_override[hidden_id], nil,
    "hidden-container parent record removed")
local hidden_sep_residue = false
for _, sep in pairs(hidden_section.separators or {}) do
    if sep.parent == hidden_id or sep.after == hidden_id then
        hidden_sep_residue = true
    end
end
assert_eq(hidden_sep_residue, false,
    "hidden custom divider records removed")
assert_eq(hidden_section.position_override.go_to, nil,
    "anchors targeting the deleted custom container are removed")
-- Production deletion paths persist immediately (hold-dialog delete runs
-- saveAndApply); mirror that here so later suites read a consistent disk
-- state and rebuilt live trees no longer offer the deleted submenus.
assert_true(MenuOrderManager:saveOrder("reader"), "post-deletion save")
MenuOrderManager:applyLiveReload(mock_ui_reader, "reader")
MenuOrderManager:dropSessionState("reader")
IntentStore.load(true)
assert_eq(IntentStore.view("reader").custom_menus[hidden_id], nil,
    "hidden custom deletion survives restart")

-- =========================================================================
print("\n--- 4. Hamburger exposes Add/Insert submenu below the separator ---")
-- =========================================================================
close_top_widgets_until(0)
do
    local editor = open_editor("tools")
    editor.marked = 0
    editor:onShowWidgetMenu()
    local dialog = top_button_dialog()
    local sep_index, submenu_index
    local index = 0
    for _, row in ipairs(dialog.buttontable.buttons) do
        for _, button in ipairs(row) do
            index = index + 1
            if button.text == "Add separator at bottom" then sep_index = index end
            if button.text == "Add submenu at bottom" then submenu_index = index end
        end
    end
    assert_true(sep_index ~= nil, "separator action still present")
    assert_true(submenu_index ~= nil, "add-submenu action present when nothing is selected")
    assert_eq(submenu_index, sep_index + 1, "submenu action sits right below the separator action")
    UIManager:close(dialog)

    editor.marked = 2
    editor:onShowWidgetMenu()
    dialog = top_button_dialog()
    local insert_submenu = find_button_by_match(dialog, function(text)
        return text:find("Insert submenu after selection", 1, true) ~= nil
    end)
    assert_true(insert_submenu ~= nil,
        "selection switches the action to inserting below the element")
    UIManager:close(dialog)
    close_top_widgets_until(0)
end

-- =========================================================================
print("\n--- 5. Creation through the real dialogs stages pending edits ---")
-- =========================================================================
do
    -- A deterministic renderable regular row: stock items are not provided by
    -- any widget in this lightweight fixture, so register one like a plugin.
    mock_ui_reader.menu:registerToMainMenu({
        name = "custom_submenu_anchor_fixture",
        addToMainMenu = function(_, menu_items)
            menu_items.anchor_fixture_item = {
                text = "Anchor fixture",
                sorting_hint = "tools",
            }
        end,
    })
    UIScreens:reconcileRegisteredItems(plugin, "reader", false)
    local editor = open_editor("tools")
    -- Pending unsaved separator must be included in the same atomic save.
    editor.marked = 0
    editor:onShowWidgetMenu()
    local add_sep = find_button(top_button_dialog(), "Add separator at bottom")
    add_sep.callback()

    editor.marked = 0
    editor:onShowWidgetMenu()
    local add_submenu = find_button(top_button_dialog(), "Add submenu at bottom")
    add_submenu.callback()

    local input_dialog
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget or UIManager._window_stack[i]
        if w and type(w.getInputText) == "function" then input_dialog = w break end
    end
    assert_true(input_dialog ~= nil, "name prompt opens")
    input_dialog:setInputText("Reading Extras")
    local create_button = find_button(input_dialog, "Create")
    assert_true(create_button ~= nil, "prompt offers Create")
    local rows_before = #editor.item_table
    create_button.callback()

    local created_row
    for _, row in ipairs(editor.item_table) do
        if row.is_submenu and row.text == "[+] Reading Extras" then created_row = row break end
    end
    assert_true(created_row ~= nil, "editor gains the created submenu row with its title")
    assert_eq(#editor.item_table, rows_before + 1, "exactly one row was added")
    assert_true(find_row(editor, created_row.item_id) ~= nil, "row carries the generated id")

    local saved_items = MenuOrderManager:getMenuItems("reader", "tools")
    assert_true(MenuOrderManager:isCustomSubmenu("reader", created_row.item_id),
        "creation persisted immediately")
    assert_eq(MenuOrderManager:getCustomSubmenuTitle("reader", created_row.item_id),
        "Reading Extras", "persisted title matches the entered name")
    local seps = 0
    for _, iid in ipairs(saved_items) do
        if iid == MenuOrderManager.SEPARATOR_ID then seps = seps + 1 end
    end
    assert_true(seps > 0, "pending unsaved separator traveled with the same save")

    -- Creating below a selected element lands right after it.
    local anchor_id, anchor_pos
    for i, row in ipairs(editor.item_table) do
        if row.item_id ~= MenuOrderManager.SEPARATOR_ID
                and row.item_id ~= "__empty_hint__"
                and not row.is_submenu and not row.is_hidden_row then
            anchor_id = row.item_id
            anchor_pos = i
            break
        end
    end
    assert_true(anchor_pos ~= nil, "an anchor row is selectable")
    editor.marked = anchor_pos
    editor:onShowWidgetMenu()
    local insert_submenu = find_button_by_match(top_button_dialog(),
        function(text) return text:find("Insert submenu after selection", 1, true) end)
    insert_submenu.callback()
    input_dialog = nil
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget or UIManager._window_stack[i]
        if w and type(w.getInputText) == "function" then input_dialog = w break end
    end
    input_dialog:setInputText("Calibre Tools")
    find_button(input_dialog, "Create").callback()

    saved_items = MenuOrderManager:getMenuItems("reader", "tools")
    local anchor_saved, created_saved
    for i, iid in ipairs(saved_items) do
        if iid == anchor_id then anchor_saved = i end
        if iid == created_row.item_id then created_saved = i end
    end
    assert_true(anchor_saved ~= nil and created_saved ~= nil, "both entries persist")
    local below_anchor
    for _, row in ipairs(editor.item_table) do
        if row.is_submenu and row.text == "[+] Calibre Tools" then below_anchor = row break end
    end
    assert_true(below_anchor ~= nil, "second submenu created below the selection")
    local below_anchor_saved
    for i, iid in ipairs(saved_items) do
        if iid == below_anchor.item_id then below_anchor_saved = i end
    end
    assert_eq(below_anchor_saved, anchor_saved + 1,
        "created submenu lands directly below the selected item in the saved order")

    -- Entering the created submenu must title the editor with its name, never
    -- the raw generated id.
    local stack_depth = #UIManager._window_stack
    below_anchor.onSubmenuTap()
    local nested_editor
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget or UIManager._window_stack[i]
        if w and w.item_table and w.marked ~= nil then nested_editor = w break end
    end
    assert_true(nested_editor ~= nil, "created submenu opens its own editor")
    assert_true(tostring(nested_editor.title):find("Calibre Tools", 1, true) ~= nil,
        "drill-down editor is titled with the submenu name: " .. tostring(nested_editor.title))
    assert_true(tostring(nested_editor.title):find("custom_submenu", 1, true) == nil,
        "drill-down editor never shows the raw id")
    close_top_widgets_until(stack_depth)

    -- Hiding and restoring a created submenu must never relabel its row with
    -- the raw generated id.
    below_anchor.callback() -- checkbox hides
    local hidden_label
    for _, row in ipairs(editor.item_table) do
        if row.item_id == below_anchor.item_id then hidden_label = row.text end
    end
    assert_true(type(hidden_label) == "string"
            and hidden_label:find("Calibre Tools", 1, true) ~= nil,
        "hidden created submenu keeps its name: " .. tostring(hidden_label))
    assert_true(hidden_label:find("custom_submenu", 1, true) == nil,
        "hidden row never shows the raw id")
    below_anchor.callback() -- checkbox restores
    local restored_label
    for _, row in ipairs(editor.item_table) do
        if row.item_id == below_anchor.item_id then restored_label = row.text end
    end
    assert_true(type(restored_label) == "string"
            and restored_label == "[+] Calibre Tools",
        "restored row label keeps the given name: " .. tostring(restored_label))

    close_top_widgets_until(0)
end

-- =========================================================================
print("\n--- 6. Created submenus render in KOReader's rebuilt menus ---")
-- =========================================================================
do
    local extras_id
    for _, iid in ipairs(MenuOrderManager:getMenuItems("reader", "tools")) do
        if MenuOrderManager:getCustomSubmenuTitle("reader", iid) == "Reading Extras" then
            extras_id = iid break
        end
    end
    assert_true(extras_id ~= nil, "fixture submenu present")

    -- Move a regular item into it through the prioritized chooser.
    local editor = open_editor("tools")
    local row = find_row(editor, "anchor_fixture_item")
    assert_true(row ~= nil, "source row available")
    row.hold_callback(row, function() editor:_populateItems() end)
    local action_dialog = top_button_dialog()
    assert_true(action_dialog ~= nil, "hold dialog opened")
    local move_button = find_button(action_dialog, "Move to another menu…")
    assert_true(move_button ~= nil, "move action offered")
    move_button.callback()
    local chooser = top_chooser()
    assert_true(chooser ~= nil, "chooser opened")
    local extras_choice_index, first_tab_index
    for i, choice in ipairs(chooser.item_table) do
        if choice.text:find("Reading Extras", 1, true) then
            if not extras_choice_index then extras_choice_index = i end
        elseif first_tab_index == nil and choice.text:find("[Tab]", 1, true) then
            first_tab_index = i
        end
    end
    assert_true(extras_choice_index ~= nil, "created submenu offered as destination")
    assert_true(first_tab_index == nil or extras_choice_index < first_tab_index,
        "same-menu submenus rank ahead of unrelated tabs")
    local chosen
    for _, choice in ipairs(chooser.item_table) do
        if choice.text:find("Reading Extras", 1, true) then choice.callback() chosen = true break end
    end
    assert_true(chosen, "created submenu selected as destination")
    assert_eq(MenuOrderManager:getParentMenu("reader", "anchor_fixture_item"), extras_id,
        "item moved into the created submenu")

    MenuOrderManager:applyLiveReload(mock_ui_reader, "reader")
    local node = live_find(extras_id)
    assert_true(node ~= nil, "created submenu appears in the rebuilt live tree")
    assert_eq(node.text, "Reading Extras", "live submenu renders the registered title")
    local children = live_children_ids(extras_id) or {}
    local has_moved = false
    for _, cid in ipairs(children) do
        if cid == "anchor_fixture_item" then has_moved = true end
    end
    assert_true(has_moved, "moved item renders inside the created submenu")
    close_top_widgets_until(0)

    -- A simulated restart (working order reloaded from disk) must keep the
    -- friendly editor title for the created submenu.
    MenuOrderManager.orders["reader"] = nil
    local restarted_editor = open_editor(extras_id)
    assert_true(tostring(restarted_editor.title):find("Reading Extras", 1, true) ~= nil,
        "editor title uses the registered name after a disk reload: "
            .. tostring(restarted_editor.title))
    close_top_widgets_until(0)
end

-- =========================================================================
print("\n--- 7. Chooser prioritizes same-menu submenus and parents ---")
-- =========================================================================
MenuOrderManager:resetOrder("reader")
MenuOrderManager:createSubmenu("reader", "navi", "Nav Group", 1)
-- Manager-level creation bypasses the UI's immediate save/reload; mirror the
-- UI flow so editors and choosers see the new level.
assert_true(MenuOrderManager:saveOrder("reader"), "navi fixture save")
MenuOrderManager:applyLiveReload(mock_ui_reader, "reader")
UIScreens:showDestinationMenuChooser(plugin, "reader", "table_of_contents", "navi")
do
    local chooser = top_chooser()
    assert_true(chooser ~= nil, "chooser opened for Navigation item")
    assert_true(chooser.item_table[1].text:find("[Menu]", 1, true) ~= nil
        and chooser.item_table[1].text:find("Nav Group", 1, true) ~= nil,
        "sibling submenu listed first: " .. tostring(chooser.item_table[1].text))
    UIManager:close(chooser)
end

-- Nested case: editing inside more_tools prioritizes the parent chain.
do
    local chooser_opened = false
    UIScreens:showDestinationMenuChooser(plugin, "reader", "terminal", "more_tools")
    local chooser = top_chooser()
    assert_true(chooser ~= nil, "chooser opened for nested item")
    assert_eq(chooser.item_table[1].text, "[Tab] Tools",
        "parent menu outranks unrelated tabs")
    for _, choice in ipairs(chooser.item_table) do
        assert_true(choice.text ~= "[Tab] More tools",
            "submenu never offers itself as destination")
    end
    chooser_opened = chooser ~= nil
    assert_true(chooser_opened, "nested chooser sanity")
    UIManager:close(chooser)
end

-- =========================================================================
print("\n--- 8. Hold-dialog delete option for created submenus ---")
-- =========================================================================
do
    -- A KOReader-style (non-created) submenu: it owns an order level but no
    -- custom registry entry, and a widget provides it so the row renders.
    mock_ui_reader.menu:registerToMainMenu({
        name = "plain_submenu_fixture",
        addToMainMenu = function(_, menu_items)
            menu_items.plain_stock_submenu = {
                text = "Plain stock submenu",
                sorting_hint = "navi",
                sub_item_table = {
                    { text = "Fixture child", callback = function() end },
                },
            }
        end,
    })
    -- Refresh the registry so the fixture's hinted entry is anchored, and
    -- give it an explicit (empty) level through raw staging.
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_reader }, "reader", false)
    MenuOrderManager:stageRawLevel("reader", "plain_stock_submenu", {})
    MenuOrderManager:saveOrder("reader")

    local nav_group_id
    for _, iid in ipairs(MenuOrderManager:getMenuItems("reader", "navi")) do
        if MenuOrderManager:getCustomSubmenuTitle("reader", iid) == "Nav Group" then
            nav_group_id = iid break
        end
    end
    local editor = open_editor("navi")
    local custom_row = find_row(editor, nav_group_id)
    assert_true(custom_row ~= nil, "created submenu row shown in parent editor")
    assert_true(custom_row.text:find("[+] Nav Group", 1, true) ~= nil,
        "created submenu displays its registered title with [+] marker")
    local stock_row = find_row(editor, "plain_stock_submenu")
    assert_true(stock_row ~= nil, "stock submenu row present for contrast")

    custom_row.hold_callback(custom_row, function() editor:_populateItems() end)
    local dialog = top_button_dialog()
    assert_true(find_button(dialog, "Delete this submenu…") ~= nil,
        "delete action offered for created submenus")
    UIManager:close(dialog)

    stock_row.hold_callback(stock_row, function() editor:_populateItems() end)
    dialog = top_button_dialog()
    assert_true(find_button(dialog, "Delete this submenu…") == nil,
        "stock submenus get no delete action")
    UIManager:close(dialog)

    custom_row.hold_callback(custom_row, function() editor:_populateItems() end)
    dialog = top_button_dialog()
    find_button(dialog, "Delete this submenu…").callback()
    local confirm = top_widget()
    local confirmed = false
    if confirm and confirm.ok_callback then confirm.ok_callback() confirmed = true end
    assert_true(confirmed, "deletion asks for confirmation")
    assert_true(find_row(editor, nav_group_id) == nil,
        "confirmed deletion removes the row immediately")
    assert_eq(MenuOrderManager:getParentMenu("reader", nav_group_id), nil,
        "deleted submenu loses its configured parent")
    assert_eq(MenuOrderManager:getCustomSubmenuTitle("reader", nav_group_id), nil,
        "deleted submenu leaves the registry")
    close_top_widgets_until(0)
end

-- =========================================================================
print("\n--- 9. Resets keep or clear created submenus correctly ---")
-- =========================================================================
do
    local __, keep_id = MenuOrderManager:createSubmenu("reader", "navi", "Persistent Group", 3)
    local ok_reset = MenuOrderManager:resetSubmenu("reader", "navi")
    assert_true(ok_reset, "parent submenu reset works")
    local retained = false
    for _, iid in ipairs(MenuOrderManager:getMenuItems("reader", "navi")) do
        if iid == keep_id then retained = true end
    end
    assert_true(retained, "resetting the parent keeps the created submenu")
    assert_eq(MenuOrderManager:getCustomSubmenuTitle("reader", keep_id),
        "Persistent Group", "retained submenu keeps its title")

    MenuOrderManager:resetOrder("reader")
    assert_eq(MenuOrderManager:getCustomSubmenuTitle("reader", keep_id), nil,
        "full reset clears the created submenu registry")
    assert_eq(MenuOrderManager:isSubmenu("reader", keep_id), false,
        "full reset removes the created submenu level")
    MenuOrderManager:applyLiveReload(mock_ui_reader, "reader")
    assert_true(live_find(keep_id) == nil,
        "rebuilt live menu no longer shows the deleted submenu")
end

-- =========================================================================
print("\n--- 10. Presets applied after creation keep the given names ---")
-- =========================================================================
do
    MenuOrderManager:resetOrder("reader")

    -- Snapshot a layout that predates the submenu.
    local ok_saved = MenuOrderManager:savePreset("reader", "Before Hello")
    assert_true(ok_saved, "preset snapshot saved")

    -- Create "hello" afterwards, persisted like the UI flow does.
    local ok_create, hello_id = MenuOrderManager:createSubmenu("reader", "tools", "hello", 1)
    assert_true(ok_create, "submenu created after the snapshot")
    assert_true(MenuOrderManager:saveOrder("reader"), "creation persisted")

    -- Apply the older preset: it keeps the unknown entry but must also keep
    -- its registered name instead of degrading to the raw id.
    local ok_load, load_err = MenuOrderManager:loadPreset("reader", "Before Hello")
    assert_true(ok_load, "older preset applies cleanly: " .. tostring(load_err))
    -- The UI always rebuilds live menus after applying a preset.
    MenuOrderManager:applyLiveReload(mock_ui_reader, "reader")
    assert_true(MenuOrderManager:isSubmenu("reader", hello_id),
        "created submenu survives applying an older preset")
    assert_eq(MenuOrderManager:getCustomSubmenuTitle("reader", hello_id), "hello",
        "registered name survives applying an older preset")

    -- The editor surfaces (title and row label) show the given name.
    local editor = open_editor("tools")
    local row = find_row(editor, hello_id)
    assert_true(row ~= nil, "created submenu still listed after preset load")
    assert_eq(row.text, "[+] hello",
        "row label uses the given name after preset load: " .. tostring(row.text))
    close_top_widgets_until(0)

    -- A user preset saved WITH the submenu restores both list entry and name,
    -- even over an intermediate configuration that renamed nothing.
    assert_true(MenuOrderManager:savePreset("reader", "With Hello"), "snapshot with submenu saved")
    MenuOrderManager:deleteCustomSubmenu("reader", hello_id)
    assert_true(MenuOrderManager:saveOrder("reader"), "deletion persisted")
    assert_true(MenuOrderManager:loadPreset("reader", "With Hello"), "with-submenu preset applies")
    assert_eq(MenuOrderManager:getCustomSubmenuTitle("reader", hello_id), "hello",
        "preset-carried registry restores the given name")
end

print(string.format("\n==============================================================="))
print(string.format("=== CUSTOM SUBMENU TESTS COMPLETED: %d PASSED, %d FAILED  ===", passed, failed))
print("===============================================================")

-- The suite drives real UIManager widgets; without an explicit quit the
-- event loop keeps the process alive after a fully passing run.
pcall(function() require("ui/uimanager"):quit() end)
if failed > 0 then
    os.exit(1)
end

--[[--
End-to-end UI tests for cross-menu moves, hide/show, and dynamic plugin pickup.

Drives the real plugin widgets (SortWidget editors, hold dialogs, destination
chooser) against a real FileManagerMenu, then verifies both the persisted
configuration and KOReader's rebuilt live menu tree after every operation.
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
local MenuOrderManager = require("menuorder_manager")
local UIScreens = require("ui_screens")
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

-- ---------------------------------------------------------------- setup ---
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
os.remove(DataStorage:getSettingsDir() .. "/reorderingmenus_intent.lua")
os.remove(DataStorage:getSettingsDir() .. "/reorderingmenus_materialization.lua")
MenuOrderManager:dropSessionState(view)

local fm_menu = FileManagerMenu:new{ ui = mock_ui_fm }
mock_ui_fm.menu = fm_menu

-- Stub the stock plugins that own the items these tests move around. Params
-- must not be named "_" (that would shadow gettext).
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
fm_menu.registered_widgets.keepalive_stub = {
    addToMainMenu = function(self, menu_items)
        menu_items.keep_alive = { text = _("Keep alive"), sorting_hint = "more_tools",
            callback = function() end }
    end,
}

local plugin = ReorderingMenus:new{ ui = mock_ui_fm }
plugin.ui = mock_ui_fm
fm_menu:registerToMainMenu(plugin)
fm_menu:setUpdateItemTable()

-- -------------------------------------------------------------- helpers ---
local function parent_of(item_id)
    return MenuOrderManager:getParentMenu(view, item_id)
end

local function count_refs(item_id)
    local order = MenuOrderManager:loadOrder(view)
    local n = 0
    for menu_id, list in pairs(order) do
        if menu_id ~= "KOMenu:disabled" and type(list) == "table" then
            for _, id in ipairs(list) do
                if id == item_id then n = n + 1 end
            end
        end
    end
    return n
end

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
        if w and w.onClose then w:onClose() else UIManager:close(w) end
    end
end

local function open_editor(menu_id)
    local before = #UIManager._window_stack
    UIScreens:showItemSortWidget(plugin, view, menu_id)
    local editor = top_widget()
    assert_true(editor ~= nil, "editor opened for " .. menu_id)
    return editor
end

local function find_row(editor, item_id)
    for _, row in ipairs(editor.item_table) do
        if row.item_id == item_id then return row end
    end
end

local function press_ok(editor)
    editor.marked = 0
    editor:onReturn()
end

local function find_button(dialog, text)
    for _, row in ipairs(dialog.buttontable.buttons) do
        for _, button in ipairs(row) do
            if button.text == text then return button end
        end
    end
end

local function top_button_dialog()
    for i = #UIManager._window_stack, 1, -1 do
        local candidate = UIManager._window_stack[i].widget or UIManager._window_stack[i]
        if candidate and candidate.buttontable then return candidate end
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

--- Moves item_id from from_editor through hold dialog -> chooser -> dest_label.
--- With keep_open_editors, leaves all SortWidgets open (only the chooser is
--- closed) so callers can assert on stacked editor interfaces afterwards.
local function move_via_dialogs(from_editor, item_id, dest_label, keep_open_editors)
    from_editor.marked = 0
    local row = find_row(from_editor, item_id)
    assert_true(row ~= nil, "row present in source editor: " .. item_id)
    row.hold_callback(row, function() from_editor:_populateItems() end)
    local action_dialog = top_button_dialog()
    assert_true(action_dialog ~= nil, "hold dialog opened")
    local move_button = find_button(action_dialog, "Move to another menu…")
    assert_true(move_button ~= nil, "move action offered")
    move_button.callback()
    local chooser = top_chooser()
    assert_true(chooser ~= nil, "destination chooser opened")
    local chosen = false
    for _, entry in ipairs(chooser.item_table) do
        if entry.text == dest_label then
            entry.callback()
            chosen = true
            break
        end
    end
    assert_true(chosen, "destination listed: " .. dest_label)
    if chosen then
        -- A completed move must exit the chooser pane by itself, leaving only
        -- the confirmation notification.
        assert_true(top_chooser() == nil,
            "move chooser closes after completed move")
        if top_chooser() then UIManager:close(top_chooser()) end

        local moved_to_text, saved_toast
        for i = #UIManager._window_stack, 1, -1 do
            local w = UIManager._window_stack[i].widget or UIManager._window_stack[i]
            if type(w) == "table" and type(w.text) == "string" then
                if w.text:find("Moved to", 1, true) then moved_to_text = w.text end
                if w.text:find("menu order saved", 1, true) then saved_toast = true end
            end
        end
        assert_true(moved_to_text ~= nil, "single move confirmation shown")
        assert_true(not saved_toast, "no extra 'menu order saved' toast")
    end
    if not keep_open_editors then
        close_top_widgets_until(1)
    end
end

--- Walks the CURRENT live menu tree and returns direct children ids of menu_id.
local function live_children(menu_id)
    local menu = mock_ui_fm.menu
    if not menu or type(menu.tab_item_table) ~= "table" then return nil end
    local items = {}
    for _, v in pairs(menu.tab_item_table) do
        if v ~= "KOMenu:menu_buttons" then table.insert(items, v) end
    end
    local k = next(items)
    while k do
        local v = items[k]
        local sub = v.sub_item_table or (type(v) == "table" and v)
        if v.id == menu_id then
            local ids = {}
            for _, c in ipairs(v.sub_item_table or v) do
                table.insert(ids, tostring(c.id))
            end
            return ids
        elseif sub then
            for _, item in pairs(sub) do
                if type(item) == "table" and item.id then table.insert(items, item) end
            end
        end
        k = next(items, k)
    end
end

local function contains(list, needle)
    for _, id in ipairs(list or {}) do
        if id == needle then return true end
    end
    return false
end

print("===============================================================")
print("=== Move / Hide / Show / Plugin-Pickup UI Flows             ===")
print("===============================================================")

assert_eq(parent_of("terminal"), "more_tools", "terminal starts in More tools")

-- =========================================================================
print("\n--- 1. Move an item up to its parent menu (drill-down) ---")
-- =========================================================================
do
    local tools_editor = open_editor("tools")          -- parent, stays open below
    local more_tools_editor = open_editor("more_tools") -- child, stacked above
    move_via_dialogs(more_tools_editor, "terminal", "[Tab] Tools", true)
    assert_eq(parent_of("terminal"), "tools", "terminal moved to parent Tools")
    assert_eq(count_refs("terminal"), 1, "exactly one configured parent after move")

    -- The moved item must show up in the still-open parent interface at once.
    local parent_row = find_row(tools_editor, "terminal")
    assert_true(parent_row ~= nil,
        "moved item appears in the open parent (Tools) editor")
    assert_true(parent_row.checked_func and parent_row.checked_func(),
        "parent editor row is visible/checked")
    assert_true(not parent_row.dim, "parent editor row is not a hidden entry")
    assert_true(find_row(more_tools_editor, "terminal") == nil,
        "source editor interface drops the moved item")

    -- Confirming both editors keeps everything consistent.
    press_ok(more_tools_editor)
    press_ok(tools_editor)
    assert_eq(parent_of("terminal"), "tools",
        "parent editor confirmation preserves the move")
    assert_eq(count_refs("terminal"), 1, "still exactly one parent after saves")
    assert_true(contains(live_children("tools"), "terminal"),
        "rebuilt live Tools menu shows terminal")
    assert_eq(contains(live_children("more_tools"), "terminal"), false,
        "live More tools menu no longer shows terminal")
end

close_top_widgets_until(0)
MenuOrderManager:moveItemToMenu(view, "terminal", "tools", "more_tools")
MenuOrderManager:saveOrder(view)

-- =========================================================================
print("\n--- 2. Move an item between unrelated menus ---")
-- =========================================================================
do
    local editor = open_editor("more_tools")
    move_via_dialogs(editor, "battery_statistics", "[Tab] Search")
    assert_eq(parent_of("battery_statistics"), "search",
        "battery_statistics moved from More tools to Search")
    assert_eq(count_refs("battery_statistics"), 1, "no duplicate parents")
    close_top_widgets_until(0)

    -- and onward to a third menu in the same session
    local search_editor = open_editor("search")
    move_via_dialogs(search_editor, "battery_statistics", "[Tab] Tools")
    assert_eq(parent_of("battery_statistics"), "tools",
        "battery_statistics moved from Search to Tools")
    assert_eq(count_refs("battery_statistics"), 1, "still exactly one parent")
    close_top_widgets_until(0)
    assert_true(contains(live_children("tools"), "battery_statistics"),
        "live Tools menu reflects the second hop")
end

MenuOrderManager:moveItemToMenu(view, "battery_statistics", "tools", "more_tools")
MenuOrderManager:saveOrder(view)

-- =========================================================================
print("\n--- 3. Hide an item and show it again ---")
-- =========================================================================
do
    local editor = open_editor("more_tools")
    local row = find_row(editor, "terminal")
    assert_true(row ~= nil and row.checked_func(), "terminal visible and checked")
    row.callback() -- checkbox tap hides immediately (persisted on OK)
    assert_true(MenuOrderManager:isItemHidden(view, "terminal"),
        "hidden flag set by checkbox")
    assert_eq(MenuOrderManager:getHiddenItemParent(view, "terminal"), "more_tools",
        "hidden origin recorded")
    press_ok(editor)
    assert_eq(count_refs("terminal"), 0, "hidden item removed from configuration")
    assert_true(contains(MenuOrderManager:getDisabledItems(view), "terminal"),
        "disabled list persists the hidden item")
    assert_eq(contains(live_children("more_tools"), "terminal"), false,
        "live More tools menu no longer shows the hidden item")
end

close_top_widgets_until(0)

do
    local editor = open_editor("more_tools")
    local row = find_row(editor, "terminal")
    assert_true(row ~= nil, "hidden terminal listed in its origin editor")
    assert_true(row.checked_func() == false, "hidden row renders unchecked")
    row.callback() -- un-hide
    assert_eq(MenuOrderManager:isItemHidden(view, "terminal"), false,
        "show clears the hidden flag")
    press_ok(editor)
    assert_eq(parent_of("terminal"), "more_tools", "shown item restored to origin menu")
    assert_true(contains(live_children("more_tools"), "terminal"),
        "live More tools menu shows the restored item")
    close_top_widgets_until(0)
end

-- =========================================================================
print("\n--- 4. Hide and show a whole submenu ---")
-- =========================================================================
do
    local editor = open_editor("tools")
    local row = find_row(editor, "more_tools")
    assert_true(row ~= nil, "More tools submenu listed in Tools editor")
    row.callback()
    press_ok(editor)
    assert_true(MenuOrderManager:isItemHidden(view, "more_tools"),
        "submenu hidden")
    assert_eq(contains(live_children("tools"), "more_tools"), false,
        "live Tools menu no longer shows More tools")
    close_top_widgets_until(0)

    local editor2 = open_editor("tools")
    local hidden_row = find_row(editor2, "more_tools")
    assert_true(hidden_row ~= nil, "hidden submenu still manageable in editor")
    hidden_row.callback()
    press_ok(editor2)
    assert_eq(MenuOrderManager:isItemHidden(view, "more_tools"), false,
        "submenu shown again")
    assert_true(contains(live_children("tools"), "more_tools"),
        "live Tools menu shows More tools again")
    close_top_widgets_until(0)
end

-- =========================================================================
print("\n--- 5. Hide via the hold dialog ---")
-- =========================================================================
do
    local editor = open_editor("more_tools")
    local row = find_row(editor, "keep_alive")
    assert_true(row ~= nil, "keep_alive row present in editor")
    row.hold_callback(row, function() editor:_populateItems() end)
    local dialog = top_button_dialog()
    local hide_button = find_button(dialog, "Hide this item")
    assert_true(hide_button ~= nil, "hold dialog offers hide action")
    hide_button.callback()
    press_ok(editor)
    assert_true(MenuOrderManager:isItemHidden(view, "keep_alive"),
        "item hidden via hold dialog")
    close_top_widgets_until(0)

    -- restore for cleanliness
    local editor2 = open_editor("more_tools")
    local hidden_row = find_row(editor2, "keep_alive")
    assert_true(hidden_row ~= nil, "hidden keep_alive listed in origin editor")
    hidden_row.callback()
    press_ok(editor2)
    assert_eq(MenuOrderManager:isItemHidden(view, "keep_alive"), false,
        "keep_alive shown again")
    close_top_widgets_until(0)
end

-- =========================================================================
print("\n--- 6. Newly installed plugin appears everywhere ---")
-- =========================================================================
do
    -- A brand-new plugin registers after the last full build, like a fresh install.
    mock_ui_fm.menu.registered_widgets.fresh_plugin_stub = {
        addToMainMenu = function(self, menu_items)
            menu_items.fresh_plugin_item = {
                text = _("Freshly installed plugin"),
                sorting_hint = "tools",
                callback = function() end,
            }
        end,
    }
    -- Same reconciliation the plugin runs on init / ReaderReady / ShowFileManager.
    UIScreens:reconcileRegisteredItems(plugin, view, true)
    assert_eq(parent_of("fresh_plugin_item"), "tools",
        "new plugin item anchored to its sorting_hint menu")
    assert_true(contains(MenuOrderManager:getMenuItems(view, "tools"), "fresh_plugin_item"),
        "configured Tools list gained the new item")

    -- Rebuild the live menu like a settings change would.
    MenuOrderManager:applyLiveReload(mock_ui_fm, view)
    assert_true(contains(live_children("tools"), "fresh_plugin_item"),
        "rebuilt live Tools menu shows the new plugin item")

    -- And the editor offers it right away.
    local editor = open_editor("tools")
    assert_true(find_row(editor, "fresh_plugin_item") ~= nil,
        "Tools editor lists the new plugin item")
    close_top_widgets_until(0)

    -- Saving some other editor must not drop the newcomer.
    local other = open_editor("search")
    press_ok(other)
    assert_eq(parent_of("fresh_plugin_item"), "tools",
        "unrelated editor save keeps the new plugin item")
    close_top_widgets_until(0)
end

-- =========================================================================
print("\n--- 7. New plugin item can be moved and stays put ---")
-- =========================================================================
do
    local editor = open_editor("tools")
    move_via_dialogs(editor, "fresh_plugin_item", "[Tab] Search")
    assert_eq(parent_of("fresh_plugin_item"), "search",
        "new plugin item moved to Search")
    assert_eq(count_refs("fresh_plugin_item"), 1, "single parent after move")
    close_top_widgets_until(0)
    assert_true(contains(live_children("search"), "fresh_plugin_item"),
        "live Search menu shows the moved plugin item")
end

-- =========================================================================
print("\n--- 8. The Tools tab cannot be hidden ---")
-- =========================================================================
local function top_notification_text()
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget or UIManager._window_stack[i]
        if w and type(w.text) == "string" and w.text:find("cannot be hidden") then
            return w.text
        end
    end
end

do
    -- Checkbox path via the tab reorder dialog.
    UIScreens:showTabReorderDialog(plugin, view)
    local tabs_editor = top_widget()
    assert_true(tabs_editor ~= nil, "tab reorder dialog opens")
    local tools_row = find_row(tabs_editor, "tools")
    assert_true(tools_row ~= nil, "Tools tab listed")
    assert_true(tools_row.checked_func(), "Tools tab starts visible")

    tools_row.callback()
    assert_eq(MenuOrderManager:isItemHidden(view, "tools"), false,
        "checkbox cannot hide the Tools tab")
    assert_true(top_notification_text() ~= nil,
        "protection notification shown for Tools")

    -- Hold-dialog path.
    local hold_row = find_row(tabs_editor, "tools")
    hold_row.hold_callback(hold_row, function() tabs_editor:_populateItems() end)
    local hide_button = find_button(top_button_dialog(), "Hide this tab")
    assert_true(hide_button ~= nil, "hold dialog offers Hide this tab")
    hide_button.callback()
    assert_eq(MenuOrderManager:isItemHidden(view, "tools"), false,
        "hold dialog cannot hide the Tools tab")
    assert_true(top_notification_text() ~= nil,
        "protection notification shown again")
    close_top_widgets_until(0)

    -- Manager-level guard.
    local ok = MenuOrderManager:setTabHidden(view, "tools", true)
    assert_eq(ok, false, "manager refuses setTabHidden(tools, true)")
    assert_eq(MenuOrderManager:isItemHidden(view, "tools"), false,
        "Tools still visible after manager refusal")

    -- Other tabs keep working both ways.
    MenuOrderManager:setTabHidden(view, "search", true)
    assert_eq(MenuOrderManager:isItemHidden(view, "search"), true,
        "non-protected tab hides normally")
    MenuOrderManager:setTabHidden(view, "search", false)
    assert_eq(MenuOrderManager:isItemHidden(view, "search"), false,
        "search shown again")
end

-- =========================================================================
print("\n--- 9. Resetting a source menu pulls moved items back for good ---")
-- =========================================================================
do
    -- Drill-down: Tools editor stays open underneath while we work in More tools.
    local tools_editor = open_editor("tools")
    local more_tools_editor = open_editor("more_tools")

    -- Move terminal up to Tools through the real dialogs.
    move_via_dialogs(more_tools_editor, "terminal", "[Tab] Tools", true)
    assert_eq(parent_of("terminal"), "tools", "terminal moved to Tools first")

    -- Reset More tools from within its (child) editor: the reset must pull
    -- terminal back out of Tools.
    local reset_ok, pulled_back =
        MenuOrderManager:resetSubmenu(view, "more_tools")
    assert_eq(reset_ok, true, "More tools reset succeeds")
    assert_true(pulled_back and pulled_back.terminal == "tools",
        "reset records terminal as pulled back from Tools")
    assert_eq(parent_of("terminal"), "more_tools",
        "reset moves terminal back to More tools")
    assert_eq(count_refs("terminal"), 1,
        "no duplicate parents right after reset")

    -- The still-open Tools editor is stale (it shows terminal). Confirming it
    -- used to resurrect the item under Tools until a restart repaired it.
    press_ok(tools_editor)
    assert_eq(parent_of("terminal"), "more_tools",
        "stale Tools editor save does not resurrect terminal")
    assert_eq(count_refs("terminal"), 1, "still exactly one parent after stale save")

    -- Interfaces stay in sync: the editor must remain USABLE after the
    -- reset + stale save (its row model may legitimately still list the
    -- stale snapshot's rows; what must not happen is a crash or a dead
    -- widget - that is the sync contract this scenario can pin without
    -- freezing era-policy behavior).
    local model_ok = pcall(function()
        assert(type(tools_editor.item_table) == "table")
        for _ in ipairs(tools_editor.item_table) do end
    end)
    assert_true(model_ok, "stale editor model stays accessible after saves")

    -- Live menu reflects the final state.
    MenuOrderManager:applyLiveReload(mock_ui_fm, view)
    assert_true(contains(live_children("more_tools"), "terminal"),
        "live More tools menu shows terminal after reset + stale save")
    assert_eq(contains(live_children("tools"), "terminal"), false,
        "live Tools menu no longer shows terminal")
    close_top_widgets_until(0)

    -- The item keeps working normally afterwards.
    local editor = open_editor("more_tools")
    move_via_dialogs(editor, "terminal", "[Tab] Tools")
    assert_eq(parent_of("terminal"), "tools",
        "item can be moved again after reset")
    close_top_widgets_until(0)
end

-- =========================================================================
print("\n--- 10. Order files and live menus reject nil-titled entries ---")
-- =========================================================================
do
    -- Garbage ids must not persist: saveOrder sanitizes the whole order.
    local order = MenuOrderManager:loadOrder(view)
    table.insert(order.tools, 42)                -- number
    table.insert(order.tools, true)              -- boolean
    table.insert(order.tools, { text = "row" })  -- leaked row table
    table.insert(order.tools, "cloud_storage")   -- duplicate
    -- NOTE: the empty-hint placeholder is now a structural sentinel object in
    -- editor row models; the string id "__empty_hint__" is NOT reserved and
    -- would persist as a normal provider id, so it is no longer inserted here.
    assert_true(MenuOrderManager:saveOrder(view), "save with garbage succeeds")

    MenuOrderManager.orders[view] = nil
    local reloaded = MenuOrderManager:loadOrder(view)
    local seen_cloud, found_garbage = 0, false
    for _, id in ipairs(reloaded.tools) do
        if type(id) ~= "string" then found_garbage = true end
        if id == "cloud_storage" then seen_cloud = seen_cloud + 1 end
    end
    assert_true(not found_garbage, "non-string ids stripped on save")
    assert_eq(seen_cloud, 1, "duplicate ids collapsed on save")

    -- A submenu row that lost its title (dynamic-only registration relocated
    -- by a layout) must get a usable title instead of rendering as "nil".
    local rebuilt = mock_ui_fm.menu
    local tools_node
    local function find_tools(node)
        if type(node) ~= "table" or tools_node then return end
        if node.id == "tools" then tools_node = node return end
        for _, v in pairs(node) do
            if type(v) == "table" then find_tools(v) end
        end
    end
    find_tools(rebuilt.tab_item_table)
    assert_true(tools_node ~= nil, "live Tools subtree located")
    local phantom = {
        id = "mystery_plugin_submenu",
        sub_item_table = { { text = "Inside", callback = function() end } },
    }
    table.insert(tools_node, phantom)
    UIScreens:sanitizeLiveMenuTree(rebuilt.tab_item_table)
    assert_eq(phantom.text, "Mystery Plugin Submenu",
        "title-less submenu gets a humanized title")
    assert_true(phantom.text ~= "nil" and phantom.text ~= "",
        "title is never the string 'nil'")

    -- Regular rows without titles are covered too.
    local orphan_row = { id = "some_unnamed_row", callback = function() end }
    table.insert(tools_node, orphan_row)
    UIScreens:sanitizeLiveMenuTree(rebuilt.tab_item_table)
    assert_true(type(orphan_row.text) == "string" and orphan_row.text ~= "nil",
        "title-less regular rows get fallback titles")

    -- applyLiveReload runs the sanitizer automatically.
    MenuOrderManager:applyLiveReload(mock_ui_fm, view)
    local fresh_tools
    local function find_tools2(node)
        if type(node) ~= "table" or fresh_tools then return end
        if node.id == "tools" then fresh_tools = node return end
        for _, v in pairs(node) do
            if type(v) == "table" then find_tools2(v) end
        end
    end
    find_tools2(mock_ui_fm.menu.tab_item_table)
    local all_titled = true
    for _, c in ipairs(fresh_tools or {}) do
        if type(c) == "table" and type(c.text) ~= "string"
                and type(c.text_func) ~= "function" and c.separator ~= true then
            all_titled = false
        end
    end
    assert_true(all_titled, "rebuilt live menu has no untitled rows")
    close_top_widgets_until(0)
end

close_top_widgets_until(0)
os.remove(DataStorage:getSettingsDir() .. "/" .. view .. "_menu_order.lua")

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

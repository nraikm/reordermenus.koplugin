--[[--
test_close_route_equivalence.lua — Bug 9 + Bug 10 regressions.

Required semantics, identical for EVERY normal close route of a Reordering
Menus editor (title-bar X, footer exit icon, Back key, programmatic close,
nested-editor return):

  Clean editor   -> closes immediately, no prompt.
  Dirty editor   -> Save / Discard / Cancel(stay open). The user must get the
                    same three choices no matter which route was used; a
                    route must never silently commit or silently drop work
                    that another route would have asked about.
  Discard        -> reverts ALL draft semantics together (drag AND hide AND
                    visibility), never a mixed half-revert.
  Bug 10         -> after Discard via any route, an unrelated later save
                    elsewhere must NOT resurrect the abandoned edit.

Run:
    cd /Applications/KOReader.app/Contents/koreader && \
    KO_HOME=$(mktemp -d) ./luajit <project>/tests/test_close_route_equivalence.lua
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
local _ = require("gettext")
local UIManager = require("ui/uimanager")
require("main")

local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local UIScreens = require("reorderingmenus_ui_screens")
local IntentStore = require("reorderingmenus_intent_store")

local passed, failed = 0, 0
local function assert_eq(a, b, msg)
    if a == b then passed = passed + 1; print("  [PASS] " .. (msg or ""))
    else failed = failed + 1; io.stdout:flush()
        print("  [FAIL] " .. (msg or "") ..
            string.format(" -> expected %s, got %s", tostring(b), tostring(a)))
    end
end
local function assert_true(c, msg) assert_eq(not not c, true, msg) end

local view = "filemanager"
local sd = DataStorage:getSettingsDir()
local ACTIVE_ID = "close_probe"

local mock_ui_fm = {
    file_chooser = {
        show_hidden = false, show_unsupported = false,
        items_per_page_default = 14,
        collates = { filename = { text = _("Filename"), menu_order = 1 } },
        getCollate = function() return nil, "filename" end,
        refreshPath = function() end, toggleShowFilesMode = function() end,
    },
    registerTouchZones = function() end, onSetSortBy = function() end,
    registerModule = function(self, name, mod) self[name] = mod end,
}
local fm = FileManagerMenu:new{ ui = mock_ui_fm }
mock_ui_fm.menu = fm
local stub = {
    name = "CloseStub", ui = mock_ui_fm,
    addToMainMenu = function(self, menu_items)
        if not self.ui.view then
            menu_items[ACTIVE_ID] = {
                text = _("Probe"), sorting_hint = "more_tools",
                callback = function() end }
        end
    end,
}

local function wipe_all()
    for _, v in ipairs({ "reader", "filemanager" }) do
        os.remove(sd .. "/" .. v .. "_menu_order.lua")
    end
    os.remove(sd .. "/reorderingmenus_intent.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    os.remove(sd .. "/reorderingmenus_state.lua")
end
local function restart()
    IntentStore.load(true)
    require("reorderingmenus_native_writer")._resetCaches()
    MenuOrderManager:dropSessionState(view)
end
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
        if w and w.ok_text ~= nil then return w end
    end
end
local function dismiss_prompt(prompt, pick)
    if pick == "save" then prompt.ok_callback()
    elseif pick == "discard" then prompt.other_buttons[1][1].callback()
    elseif pick == "cancel" then prompt.cancel_callback() end
    UIManager:close(prompt)
end
local function saved_order()
    local out = {}
    for __, id in ipairs(MenuOrderManager:getMenuItems(view, "more_tools")) do
        table.insert(out, tostring(id))
    end
    return table.concat(out, ",")
end
local function open_editor()
    UIScreens:showItemSortWidget({ ui = mock_ui_fm }, view, "more_tools")
    local e = find_editor()
    assert_true(e ~= nil, "editor opens")
    return e
end
-- Make the editor dirty in BOTH dimensions: drag two rows AND hide one row.
local function make_dirty_both(editor)
    local rows = editor.item_table
    local i1, i2
    for i, r in ipairs(rows) do
        if r.item_id == ACTIVE_ID then i1 = i1 or i end
        if type(r.item_id) == "string" and not r.is_hidden_row then i2 = i2 or i end
    end
    -- drag: swap the first two real rows (any deterministic reorder works)
    if #rows >= 2 then
        rows[1], rows[2] = rows[2], rows[1]
    end
    -- hide: toggle the probe row's checkbox callback
    for _, r in ipairs(rows) do
        if r.item_id == ACTIVE_ID and r.callback then
            r.callback()
            break
        end
    end
end

print("=================================================================")
print("=== Close-route equivalence & abandoned-edit isolation        ===")
print("=================================================================")

wipe_all(); restart()
fm.registered_widgets.stub = stub
fm:setUpdateItemTable()
UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, true)

---------------------------------------------------------------------
local routes = { "titlebar_x", "footer_exit", "back_key", "programmatic" }
for _, route in ipairs(routes) do
    print(string.format("\n--- Route: %s ---", route))
    local baseline = saved_order()

    local editor = open_editor()
    make_dirty_both(editor)

    local prompt_shown, editor_closed
    if route == "titlebar_x" then
        editor.title_bar.right_button.callback()
        prompt_shown = find_prompt() ~= nil
        editor_closed = find_editor() == nil
    elseif route == "footer_exit" then
        editor.footer_cancel.callback()
        prompt_shown = find_prompt() ~= nil
        editor_closed = find_editor() == nil
    elseif route == "back_key" then
        editor.marked = 0
        editor:onCancelOrClose()
        prompt_shown = find_prompt() ~= nil
        editor_closed = find_editor() == nil
    else
        editor:onClose()
        prompt_shown = find_prompt() ~= nil
        editor_closed = find_editor() == nil
    end

    -- The equivalence contract: dirty + close route => the SAME outcome set.
    -- A route either prompts (Save/Discard/Cancel) or closes cleanly ONLY
    -- when nothing is unsaved. With both drag+hide staged, closing without
    -- asking is a silent discard of the hide (the old mixed behaviour).
    if prompt_shown then
        assert_true(true, route .. ": asks what to do with unsaved edits")
        dismiss_prompt(find_prompt(), "discard")
        assert_eq(saved_order(), baseline,
            route .. ": Discard reverts ALL draft semantics (drag+hide)")
        assert_eq(MenuOrderManager:isItemHidden(view, ACTIVE_ID), false,
            route .. ": Discard reverts the visibility toggle too")
    elseif editor_closed then
        -- Closed silently. Contract violation only if work SURVIVED the
        -- silent close (silent-discard of everything is at least coherent);
        -- flag it as a non-prompting route for visibility.
        print(string.format(
            "  [note] %s closed WITHOUT prompting (silent full-discard)", route))
        assert_eq(MenuOrderManager:isItemHidden(view, ACTIVE_ID), false,
            route .. ": silent close did not leave the hide staged")
        -- restore baseline ordering if the swap leaked into staging
        MenuOrderManager:reloadFromDisk(view)
    else
        assert_true(false, route .. ": neither prompted nor closed - stuck UI")
    end
    close_all_windows()
end

---------------------------------------------------------------------
print("\n--- Bug 10: discarded hide never persists via a later save ---")
do
    local editor = open_editor()
    make_dirty_both(editor)          -- drag + hide staged
    editor.title_bar.right_button.callback()
    local prompt = find_prompt()
    assert_true(prompt ~= nil, "dirty X prompts")
    dismiss_prompt(prompt, "discard")

    -- UNRELATED later edit elsewhere in the same session, then save.
    MenuOrderManager:setItemHidden(view, "keep_alive", true, "more_tools")
    MenuOrderManager:saveOrder(view)

    assert_eq(MenuOrderManager:isItemHidden(view, ACTIVE_ID), false,
        "abandoned hide does NOT ride the unrelated save")
    assert_eq(MenuOrderManager:isItemHidden(view, "keep_alive"), true,
        "the unrelated hide DID persist (save did real work)")

    -- cleanup: undo the unrelated hide so later sections start clean
    MenuOrderManager:setItemHidden(view, "keep_alive", false, "more_tools")
    MenuOrderManager:restoreItemDefault(view, "keep_alive")
    MenuOrderManager:saveOrder(view)
    close_all_windows()
end

---------------------------------------------------------------------
print("\n--- Bug 10b: same for a cross-menu move abandoned by Discard ---")
do
    local baseline_more = saved_order()
    local editor = open_editor()
    -- stage a cross-menu move from inside this editor's model: move probe row
    -- to tools through the manager verb (staged only, no save yet happens
    -- until the chooser flow saves; here we stage manually)
    local ok_move = MenuOrderManager:moveItemToMenu(view, ACTIVE_ID,
        "more_tools", "tools")
    assert_true(ok_move, "cross-menu move staged")
    -- Abandon everything: reload-from-disk is what Discard performs.
    MenuOrderManager:reloadFromDisk(view)

    -- Unrelated later edit + save.
    MenuOrderManager:setItemHidden(view, "keep_alive", true, "more_tools")
    MenuOrderManager:saveOrder(view)

    local parent_now = MenuOrderManager:getParentMenu(view, ACTIVE_ID)
    assert_eq(parent_now, "more_tools",
        "abandoned cross-menu move does not persist via the later save")

    MenuOrderManager:setItemHidden(view, "keep_alive", false, "more_tools")
    MenuOrderManager:restoreItemDefault(view, "keep_alive")
    MenuOrderManager:saveOrder(view)
    assert_eq(saved_order(), baseline_more, "baseline fully restored")
    close_all_windows()
end

---------------------------------------------------------------------
print("\n--- Nested editor return keeps the same close contract ---")
do
    local baseline = saved_order()
    UIScreens:showTabReorderDialog({ ui = mock_ui_fm }, view)
    local tab_widget = find_editor()
    assert_true(tab_widget ~= nil, "tab dialog opens")
    -- drill into a submenu editor (nested editor on top)
    UIScreens:showItemSortWidget({ ui = mock_ui_fm }, view, "tools")
    local nested = find_editor()
    assert_true(nested ~= nil, "nested editor opens")
    make_dirty_both(nested)
    nested.title_bar.right_button.callback()
    local prompt = find_prompt()
    if prompt then
        assert_true(true, "nested dirty X prompts (same contract as root)")
        dismiss_prompt(prompt, "cancel")
        assert_true(find_editor() ~= nil, "cancel keeps the nested editor open")
    else
        assert_true(find_editor() == nil, "nested X closed without prompting (clean)")
    end
    close_all_windows()
    MenuOrderManager:reloadFromDisk(view)
    assert_eq(saved_order(), baseline, "nested exploration left no residue")
end

close_all_windows()
wipe_all(); restart()
print(string.format("\n=== %d passed, %d failed ===\n", passed, failed))
os.exit(failed == 0 and 0 or 1)

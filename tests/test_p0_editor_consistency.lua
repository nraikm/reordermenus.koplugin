--[[--
test_p0_editor_consistency.lua — P0 editor-consistency regression battery.

Covers the editor-facing correctness contract on top of the transaction
architecture (no P1 editor-local drafts):

  §1  Editors are notified of cross-menu moves ONLY after durable commit
      success (chooser path AND reset-submenu path); failed saves leave
      every open editor showing pre-move state and canonical untouched.
  §2  Every ordinary close route of a DIRTY editor is equivalent
      (Save / Discard / Cancel): title-bar X, Back key, footer exit,
      programmatic close (UIManager:close -> CloseWidget event ->
      onCloseWidget), and nested-editor return.
  §3  Discard abandons the ENTIRE semantic edit-set (drag/hide/move/
      cross-menu/nested) - never half a combination.
  §4  An edit chosen Discard can never ride a later unrelated save,
      verified across a real settings-file restart.
  §5  Failed-save UI reflects the structured pipeline result:
      total failure = dirty editor + retry; canonical-committed-but-
      derived-write-failed ("saved_needs_regeneration") = move STANDS +
      restart notice; live-reload failure = saved + restart required;
      "unchanged" no-op = phantom dirt resolved, editor closes clean.
  §6  Post-commit synchronization moves items exactly once; stale numeric
      positions are not identity (A->B then B->A round trip).
  §7  Nested editor Save/Discard independence semantics.
  §8  Transaction-owned metadata (mirroring toggle) vs Discard: layout
      abandoned + preference kept, and neither leaks into later saves.

Run:
    cd /Applications/KOReader.app/Contents/koreader && \
    KO_HOME=$(mktemp -d) ./luajit <project>/tests/test_p0_editor_consistency.lua
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")

G_reader_settings = LuaSettings:open(
    DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()

local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local _ = require("gettext")
require("main")

local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local UIManager = require("ui/uimanager")
local MenuOrderManager = require("menuorder_manager")
local UIScreens = require("ui_screens")
local UIEditorRegistry = require("ui_editor_registry")
local IntentStore = require("intent_store")
local KoreaderAdapter = require("koreader_adapter")
local CommitPipeline = require("commit_pipeline")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")

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
local INTENT_FILE = sd .. "/reorderingmenus_intent.lua"
local NATIVE_FM_FILE = sd .. "/filemanager_menu_order.lua"

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
    name = "ConsistencyStub", ui = mock_ui_fm,
    addToMainMenu = function(self, menu_items)
        if not self.ui.view then
            menu_items.cons_alpha = {
                text = _("Alpha item"), sorting_hint = "more_tools",
                callback = function() end }
            menu_items.cons_beta = {
                text = _("Beta item"), sorting_hint = "tools",
                callback = function() end }
            menu_items.reordering_menus = {
                text = _("Reorder menus"), sorting_hint = "more_tools",
                callback = function() end }
        end
    end,
}

local function wipe_all()
    for _, v in ipairs({ "reader", "filemanager" }) do
        os.remove(sd .. "/" .. v .. "_menu_order.lua")
    end
    os.remove(INTENT_FILE)
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    os.remove(sd .. "/reorderingmenus_state.lua")
    IntentStore.load(true)
    MenuOrderManager:dropSessionState(view)
    MenuOrderManager:dropSessionState("reader")
    MenuOrderManager.default_orders[view] = nil
    MenuOrderManager.default_orders["reader"] = nil
end

local function drop_session_caches()
    package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
    MenuOrderManager.orders[view] = nil
    MenuOrderManager.default_orders[view] = nil
end

-- Real restart discipline: drop session caches and force a fresh full load
-- from disk, exactly like a process restart would. Under schema v3,
-- registration IS existence (no persisted anchor pins), so the restart must
-- also replay what main.lua does at startup: reconcile live widget
-- contributions back into the registry. Skipping that would make every
-- stub-injected item go dormant across restart - a harness artifact no real
-- KOReader session can produce.
local function restart()
    drop_session_caches()
    IntentStore.load(true)
    MenuOrderManager:dropSessionState(view)
    UIScreens:reconcileRegisteredItems(fm, view, false)
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
        -- ConfirmBox carries ok_text; restart prompts are nextTick-scheduled
        -- and never materialize inside these tests.
        if w and w.ok_text ~= nil then return w end
    end
end

local function dismiss_prompt(prompt, pick)
    if pick == "save" then
        prompt.ok_callback()
    elseif pick == "discard" then
        prompt.other_buttons[1][1].callback()
    elseif pick == "cancel" then
        prompt.cancel_callback()
    end
    UIManager:close(prompt)
end

local function open_item_editor(menu_id)
    UIScreens:showItemSortWidget({ ui = mock_ui_fm }, view, menu_id or "more_tools")
    local editor = find_editor()
    assert_true(editor ~= nil, "item editor opens (" .. (menu_id or "more_tools") .. ")")
    return editor
end

local function saved_list(menu_id)
    local out = {}
    for _, id in ipairs(MenuOrderManager:getMenuItems(view, menu_id)) do
        table.insert(out, tostring(id))
    end
    return table.concat(out, ",")
end

local function list_contains(list, id)
    for _, x in ipairs(list or {}) do if x == id then return true end end
    return false
end

local function intent_file_has(pat)
    local fh = io.open(INTENT_FILE, "r")
    if not fh then return false end
    local body = fh:read("*a"); fh:close()
    return body:find(pat, 1, true) ~= nil
end

local function swap_first_two(widget)
    widget.item_table[1], widget.item_table[2] =
        widget.item_table[2], widget.item_table[1]
end

-- Scenario isolation: cross-menu move attempts (even ones later discarded)
-- record healing entries that steer how FRESHLY OPENED editors compose their
-- rows. Clearing them emulates returning to the menu later - the same
-- hygiene drop_session_caches performs in other suites.
local function reset_editor_heuristics()
    MenuOrderManager.recent_moves[view] = {}
end

print("=================================================================")
print("=== P0 editor consistency: notify / close / discard / failure ===")
print("=================================================================")

wipe_all()
fm.registered_widgets.stub = stub
fm:setUpdateItemTable()
UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, true)

-- -------------------------------------------------------------------
print("\n--- S1: chooser move with failing disk writes ---")
do
    UIScreens:showItemSortWidget({ ui = mock_ui_fm }, view, "tools") -- dest editor
    local dest_editor = find_editor()
    assert_true(dest_editor ~= nil, "destination (Tools) editor opened")
    local sync_in_calls = 0
    local orig_in = dest_editor.syncMovedIn
    dest_editor.syncMovedIn = function(self, id)
        sync_in_calls = sync_in_calls + 1
        return orig_in(self, id)
    end

    local real_writeToFile = util.writeToFile
    util.writeToFile = function() return nil, "injected total io failure" end

    MenuOrderManager:backupOrder(view)
    local moved = MenuOrderManager:moveItemToMenu(
        view, "cons_alpha", "more_tools", "tools")
    local saved, err = UIScreens:saveAndApply({ ui = mock_ui_fm }, view, true)
    util.writeToFile = real_writeToFile

    assert_true(moved, "move stages while all writes fail")
    assert_eq(saved, false, "saveAndApply reports failure on IO error")
    assert_eq(sync_in_calls, 0, "S1: failed save notifies NO editor")
    -- The save-failure funnel rebases surviving staged work onto a fresh txn
    -- (H1e dirty-state contract), so the DRAFT survives for retry; nothing
    -- durable changed though.
    MenuOrderManager:restoreOrder(view)
    assert_eq(saved_list("more_tools"):find("cons_alpha", 1, true) ~= nil, true,
        "S1: item listed in source after restoreOrder rollback")
    -- Schema v3: the pre-scenario reconcile persisted a TYPED LIFECYCLE PIN
    -- for cons_alpha (first-contact anchoring, registration bookkeeping).
    -- What must NOT be on disk is the FAILED MOVE - i.e. any override of
    -- cons_alpha into "tools". Reload canonical from disk and check that.
    MenuOrderManager:dropSessionState(view)
    IntentStore.load(true)
    local s_disk = IntentStore.view(view)
    local rec_disk = s_disk.parent_override
        and s_disk.parent_override["cons_alpha"] or nil
    assert_true(rec_disk == nil or rec_disk.parent ~= "tools",
        "S1: nothing about the move reached disk")
    close_all_windows()
end

-- -------------------------------------------------------------------
print("\n--- S2: reset-submenu path with failing disk writes ---")
do
    -- Hidden-origin items are what a submenu reset pulls back. Hide one,
    -- commit it, then reset its home while ALL writes fail: the pulled-back
    -- notification used to fire BEFORE that path's own saveOrder.
    assert_true(MenuOrderManager:saveOrder(view),
        "S2-pre: healthy baseline save")
    MenuOrderManager:setItemHidden(view, "cons_alpha", true, "more_tools")
    assert_true(UIScreens:saveAndApply({ ui = mock_ui_fm }, view, true),
        "S2-pre: committed hide")

    UIScreens:showItemSortWidget({ ui = mock_ui_fm }, view, "more_tools")
    local editor = find_editor()

    -- Wrap the notification boundary itself: with the durable-first contract
    -- it may run ONLY after the save succeeded, so counting its invocations
    -- around a failing save pins the ordering exactly.
    local notify_calls = 0
    local orig_notify = UIScreens._notifyEditorsOfMove
    UIScreens._notifyEditorsOfMove = function(self, ...)
        notify_calls = notify_calls + 1
        return orig_notify(self, ...)
    end

    local real_writeToFile = util.writeToFile
    util.writeToFile = function() return nil, "injected total io failure" end
    UIScreens:confirmResetSubmenu({ ui = mock_ui_fm }, view, "more_tools",
        _("More tools"))
    local prompt = find_prompt()
    assert_true(prompt ~= nil, "S2: reset ConfirmBox shown")
    dismiss_prompt(prompt, "save") -- runs ok_callback synchronously
    util.writeToFile = real_writeToFile
    UIScreens._notifyEditorsOfMove = orig_notify

    assert_eq(notify_calls, 0,
        "S2: failed reset save notifies NO editor (was notified pre-save)")
    close_all_windows()

    -- Healthy retry converges: reset unhides the item and commits.
    UIScreens:confirmResetSubmenu({ ui = mock_ui_fm }, view, "more_tools",
        _("More tools"))
    local prompt2 = find_prompt()
    dismiss_prompt(prompt2, "save")
    assert_true(list_contains(MenuOrderManager:getMenuItems(view, "more_tools"),
        "cons_alpha"), "S2: healthy reset pulls item back and commits")
    close_all_windows()
end

-- -------------------------------------------------------------------
print("\n--- S3: post-commit synchronization moves rows exactly once ---")
do
    -- Two open editors: the source (tools) and the destination (more_tools).
    -- Wrap each widget's sync hooks individually so we can assert WHO got
    -- told WHAT after a committed move.
    UIScreens:showItemSortWidget({ ui = mock_ui_fm }, view, "tools")
    local src_editor = find_editor()
    assert_true(src_editor ~= nil, "source (Tools) editor opened")
    UIScreens:showItemSortWidget({ ui = mock_ui_fm }, view, "more_tools")
    local dst_editor
    for i = stack_size(), 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w ~= src_editor and w.item_table and w.marked ~= nil then
            dst_editor = w break
        end
    end
    assert_true(dst_editor ~= nil, "destination (More tools) editor opened")

    local counts = {} -- [widget]["in"/"out"]
    local function instrument(w)
        counts[w] = { inn = 0, out = 0 }
        local oi, oo = w.syncMovedIn, w.syncMovedOut
        w.syncMovedIn = function(self, id)
            counts[w].inn = counts[w].inn + 1; return oi(self, id)
        end
        w.syncMovedOut = function(self, id)
            counts[w].out = counts[w].out + 1; return oo(self, id)
        end
    end
    instrument(src_editor)
    instrument(dst_editor)

    -- tools -> more_tools (registry-level pinning of §6; ordering itself is
    -- pinned by S1/S2 against the real call sites).
    UIScreens:_notifyEditorsOfMove(view, "cons_beta", "tools", "more_tools")
    assert_eq(counts[src_editor].out, 1, "S3: source loses row exactly once")
    assert_eq(counts[src_editor].inn, 0, "S3: source gains nothing")
    assert_eq(counts[dst_editor].inn, 1, "S3: destination gains row exactly once")
    assert_eq(counts[dst_editor].out, 0, "S3: destination loses nothing")

    -- Stale numeric positions are NOT identity: moving the SAME item back
    -- (B -> A) must update both editors again instead of being deduped by
    -- any position cache.
    UIScreens:_notifyEditorsOfMove(view, "cons_beta", "more_tools", "tools")
    assert_eq(counts[dst_editor].out, 1,
        "S6: reverse move re-syncs previous destination")
    assert_eq(counts[src_editor].inn, 1,
        "S6: reverse move re-syncs original home")
    close_all_windows()
end

-- -------------------------------------------------------------------
-- §2: every ordinary close route of a DIRTY editor is equivalent.
-- -------------------------------------------------------------------
local function make_editor_dirty(widget)
    swap_first_two(widget)
    return true
end

print("\n--- C0: CLEAN editors close immediately on every route ---")
do
    local routes = {
        { name = "title-bar X", act = function(w) w.title_bar.right_button.callback() end },
        { name = "Back key", act = function(w) w:onCancelOrClose() end },
        { name = "footer exit", act = function(w) w.footer_cancel.callback() end },
        { name = "programmatic", act = function(w) UIManager:close(w) end },
    }
    for _, r in ipairs(routes) do
        local before = stack_size()
        local ed = open_item_editor()
        r.act(ed)
        assert_eq(stack_size(), before,
            "C0[" .. r.name .. "]: clean editor closed")
        assert_true(find_prompt() == nil,
            "C0[" .. r.name .. "]: clean close never prompts")
    end
    close_all_windows()
end

print("\n--- C1-C3: title-bar X offers Save / Discard / Cancel ---")
do
    -- C1: Save commits and closes.
    local ed = open_item_editor()
    make_editor_dirty(ed)
    ed.title_bar.right_button.callback()
    local p = find_prompt()
    assert_true(p ~= nil, "C1: dirty X prompts")
    dismiss_prompt(p, "save")
    assert_true(find_editor() == nil, "C1: Save closes the editor")
    assert_true(saved_list("more_tools"):find("cons_alpha", 1, true) ~= nil,
        "C1: sanity - menu intact after save")

    -- C2: Discard reverts and closes.
    local ed2 = open_item_editor()
    local canonical_before = saved_list("more_tools")
    make_editor_dirty(ed2)
    ed2.title_bar.right_button.callback()
    local p2 = find_prompt()
    dismiss_prompt(p2, "discard")
    assert_true(find_editor() == nil, "C2: Discard closes the editor")
    assert_eq(saved_list("more_tools"), canonical_before,
        "C2: Discard reverts the staged drag")

    -- C3: Cancel stays.
    local ed3 = open_item_editor()
    make_editor_dirty(ed3)
    ed3.title_bar.right_button.callback()
    local p3 = find_prompt()
    dismiss_prompt(p3, "cancel")
    assert_true(find_editor() ~= nil, "C3: Cancel keeps the editor open")
    close_all_windows()
end

print("\n--- C4/C5/C6: silent routes discard coherently (no prompt) ---")
do
    -- Baseline arrangement to compare against.
    local canonical_more_tools = saved_list("more_tools")
    local canonical_tools = saved_list("tools")

    -- C4: Back key on a DIRTY editor = silent full discard.
    local ed = open_item_editor()
    make_editor_dirty(ed)
    ed:onCancelOrClose()
    assert_true(find_editor() == nil, "C4: Back closes the dirty editor")
    assert_true(find_prompt() == nil, "C4: Back never prompts")
    assert_eq(saved_list("more_tools"), canonical_more_tools,
        "C4: Back discarded the drag")

    -- C5: footer exit icon on a DIRTY editor = silent full discard.
    local ed5 = open_item_editor()
    make_editor_dirty(ed5)
    ed5.footer_cancel.callback()
    assert_true(find_editor() == nil, "C5: footer exit closed the editor")
    assert_eq(saved_list("more_tools"), canonical_more_tools,
        "C5: footer exit discarded the drag")

    -- C6: PROGRAMMATIC close (UIManager:close -> CloseWidget event) must be
    -- equivalent too: full discard AND sync-registry unregistration.
    local ed6 = open_item_editor()
    make_editor_dirty(ed6)
    UIManager:close(ed6)
    assert_eq(saved_list("more_tools"), canonical_more_tools,
        "C6: programmatic close discarded the drag")
    assert_eq(UIEditorRegistry:countLive(view), 0,
        "C6: programmatic close unregisters from the sync registry")
    assert_eq(saved_list("tools"), canonical_tools, "C6: other menus untouched")

    -- C6b: a stale editor must NOT survive a programmatic close: after this
    -- close a committed move may not reach the dead widget anymore.
    local probe_calls = 0
    local ed6b = open_item_editor()
    local orig_in = ed6b.syncMovedIn
    ed6b.syncMovedIn = function(self, id)
        probe_calls = probe_calls + 1; return orig_in(self, id)
    end
    UIManager:close(ed6b)
    UIScreens:_notifyEditorsOfMove(view, "cons_beta", "tools", "more_tools")
    assert_eq(probe_calls, 0,
        "C6b: closed editor receives no further sync broadcasts")
    close_all_windows()
end

print("\n--- C7: nested-editor return route ---")
do
    -- Parent editor (more_tools) dirty, child editor (tools) opened on top
    -- (drill-down), child modifies. Closing the child returns to the parent;
    -- every subsequent route must treat EACH editor's own dirtiness
    -- independently and coherently.
    local canonical_parent = saved_list("more_tools")
    local canonical_child = saved_list("tools")

    local parent = open_item_editor("more_tools")
    make_editor_dirty(parent)
    local child = open_item_editor("tools")
    make_editor_dirty(child)

    -- Child X -> Discard.
    child.title_bar.right_button.callback()
    local p = find_prompt()
    assert_true(p ~= nil, "C7: child X prompts")
    dismiss_prompt(p, "discard")
    assert_eq(saved_list("tools"), canonical_child, "C7: child discard reverts child drag")
    assert_true(find_editor() ~= nil, "C7: parent survives child close")

    -- Parent now exits through the SILENT route: must discard ITS draft too.
    parent.footer_cancel.callback()
    assert_eq(saved_list("more_tools"), canonical_parent,
        "C7: parent silent close discarded parent drag")
    close_all_windows()

    -- Nested variant through the programmatic route on BOTH layers.
    local par2 = open_item_editor("more_tools")
    make_editor_dirty(par2)
    local ch2 = open_item_editor("tools")
    make_editor_dirty(ch2)
    UIManager:close(ch2)
    UIManager:close(par2)
    assert_eq(saved_list("tools"), canonical_child, "C7b: programmatic child discard")
    assert_eq(saved_list("more_tools"), canonical_parent, "C7b: programmatic parent discard")
    assert_eq(UIEditorRegistry:countLive(view), 0, "C7b: no editors left registered")
    close_all_windows()
end

-- -------------------------------------------------------------------
-- §3: Discard abandons the ENTIRE semantic edit-set.
-- -------------------------------------------------------------------
local function x_discard(ed)
    ed.title_bar.right_button.callback()
    local p = find_prompt()
    assert_true(p ~= nil, "discard route prompt shown")
    dismiss_prompt(p, "discard")
end

print("\n--- D1/D2: single-kind edits ---")
do
    -- D1: drag only.
    local base = saved_list("more_tools")
    local ed = open_item_editor()
    make_editor_dirty(ed)
    x_discard(ed)
    assert_eq(saved_list("more_tools"), base, "D1: drag-only fully discarded")
    assert_true(find_editor() == nil, "D1: editor closed")

    -- D2: hide only.
    local ed2 = open_item_editor()
    local target_row
    for _, row in ipairs(ed2.item_table) do
        if row.item_id == "cons_alpha" then target_row = row break end
    end
    assert_true(target_row ~= nil and target_row.checked_func ~= nil,
        "D2: hide toggle row located")
    target_row.callback() -- immediate-applied hide (staged)
    x_discard(ed2)
    assert_eq(MenuOrderManager:isItemHidden(view, "cons_alpha"), false,
        "D2: hide-only fully discarded")
    close_all_windows()
end

print("\n--- D3/D4/D5: mixed drag/hide/move states ---")
do
    reset_editor_heuristics()
    -- D4: drag + hide TOGETHER must revert together.
    local base = saved_list("more_tools")
    local ed = open_item_editor()
    make_editor_dirty(ed)
    local row
    for _, r in ipairs(ed.item_table) do
        if r.item_id == "cons_alpha" then row = r break end
    end
    assert_true(row ~= nil, "D4: hide-toggle row located")
    row.callback() -- hide cons_alpha while the drag is pending
    x_discard(ed)
    local after = saved_list("more_tools")
    assert_eq(after, base, "D4: drag half of drag+hide discarded")
    assert_eq(MenuOrderManager:isItemHidden(view, "cons_alpha"), false,
        "D4: hide half of drag+hide discarded (no half-discarded state)")

    -- D3: staged cross-menu move alone.
    local ed3 = open_item_editor()
    MenuOrderManager:moveItemToMenu(view, "cons_alpha", "more_tools", "tools")
    x_discard(ed3)
    assert_true(list_contains(MenuOrderManager:getMenuItems(view, "more_tools"),
        "cons_alpha"), "D3: move-only discarded - item back home")
    assert_eq(MenuOrderManager:getParentMenu(view, "cons_alpha"), "more_tools",
        "D3: parent_override rolled back")

    -- D5: move + hide together.
    reset_editor_heuristics() -- D3's discarded move left healing entries
    local ed5 = open_item_editor()
    MenuOrderManager:moveItemToMenu(view, "cons_alpha", "more_tools", "tools")
    local row5
    for _, r in ipairs(ed5.item_table) do
        if r.item_id == "cons_alpha" then row5 = r break end
    end
    row5.callback()
    x_discard(ed5)
    assert_eq(MenuOrderManager:getParentMenu(view, "cons_alpha"), "more_tools",
        "D5: move half discarded")
    assert_eq(MenuOrderManager:isItemHidden(view, "cons_alpha"), false,
        "D5: hide half discarded")
    close_all_windows()
end

print("\n--- D6: nested dirty editors, both discarded ---")
do
    local base_parent = saved_list("more_tools")
    local base_child = saved_list("tools")
    local par = open_item_editor("more_tools")
    make_editor_dirty(par)
    MenuOrderManager:setItemHidden(view, "cons_beta", true, "tools")
    local ch = open_item_editor("tools")
    make_editor_dirty(ch)
    x_discard(ch)
    par.footer_cancel.callback()
    assert_eq(saved_list("tools"), base_child, "D6: child level clean")
    assert_eq(saved_list("more_tools"), base_parent, "D6: parent level clean")
    assert_eq(MenuOrderManager:isItemHidden(view, "cons_beta"), false,
        "D6: staged hide did not survive nested discards")
    close_all_windows()
end

-- -------------------------------------------------------------------
-- §4: a DISCARDED edit can never ride a later unrelated save (restart).
-- -------------------------------------------------------------------
local function discard_then_unrelated_save_and_restart()
    -- Unrelated change made elsewhere + durable save, then a real restart.
    MenuOrderManager:reorderTabs(view,
        (function(t) local c = util.tableDeepCopy(t)
            c[1], c[2] = c[2], c[1] return c end)(MenuOrderManager:getTabs(view)))
    assert_true(UIScreens:saveAndApply({ ui = mock_ui_fm }, view, true),
        "unrelated save succeeded")
    restart()
end

print("\n--- A1-A4: discarded edits never surface after restart ---")
do
    reset_editor_heuristics()
    -- A1: hide.
    local ed = open_item_editor()
    local row
    for _, r in ipairs(ed.item_table) do
        if r.item_id == "cons_alpha" then row = r break end
    end
    row.callback()
    x_discard(ed)
    discard_then_unrelated_save_and_restart()
    assert_eq(MenuOrderManager:isItemHidden(view, "cons_alpha"), false,
        "A1: discarded hide invisible after restart")

    -- A2: reorder.
    local base = saved_list("more_tools")
    local ed2 = open_item_editor()
    make_editor_dirty(ed2)
    x_discard(ed2)
    discard_then_unrelated_save_and_restart()
    assert_eq(saved_list("more_tools"), base,
        "A2: discarded reorder absent after restart")

    -- A3: cross-menu move.
    local ed3 = open_item_editor()
    MenuOrderManager:moveItemToMenu(view, "cons_alpha", "more_tools", "tools")
    x_discard(ed3)
    discard_then_unrelated_save_and_restart()
    assert_eq(MenuOrderManager:getParentMenu(view, "cons_alpha"), "more_tools",
        "A3: discarded cross-menu move absent after restart")

    -- A4: tab drag (tab dialog, programmatic dirty close).
    local tabs_before = table.concat(MenuOrderManager:getTabs(view), ",")
    UIScreens:showTabReorderDialog({ ui = mock_ui_fm }, view)
    local tabdlg
    for i = stack_size(), 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w and w.item_table and w._populateItems and w.marked ~= nil then
            tabdlg = w break
        end
    end
    assert_true(tabdlg ~= nil, "A4: tab dialog opened")
    swap_first_two(tabdlg)
    UIManager:close(tabdlg) -- dirty programmatic close = discard
    -- The helper below swaps the first two COMMITTED tabs once more, so the
    -- no-leak expectation is tabs_before swapped once (a leaked draft would
    -- produce tabs_before swapped twice == tabs_before).
    local function swap_first_two_csv(csv)
        local t = {}
        for x in csv:gmatch("[^,]+") do t[#t + 1] = x end
        t[1], t[2] = t[2], t[1]
        return table.concat(t, ",")
    end
    discard_then_unrelated_save_and_restart()
    assert_eq(table.concat(MenuOrderManager:getTabs(view), ","),
        swap_first_two_csv(tabs_before),
        "A4: discarded tab drag absent after restart")
    close_all_windows()
    wipe_all()
end

-- -------------------------------------------------------------------
-- §5: failed/partial saves must reflect the structured pipeline result.
-- -------------------------------------------------------------------
print("\n--- F1: canonical commit fails -> editor stays dirty, retry works ---")
do
    local ed = open_item_editor()
    make_editor_dirty(ed)
    ed.title_bar.right_button.callback()
    local p = find_prompt()
    assert_true(p ~= nil, "F1-pre: dirty X prompts")
    local real_writeToFile = util.writeToFile
    util.writeToFile = function() return nil, "injected total io failure" end
    dismiss_prompt(p, "save")
    util.writeToFile = real_writeToFile

    assert_true(find_editor() ~= nil,
        "F1: failed save keeps the editor open (user can retry)")
    assert_eq(UIEditorRegistry:countLive(view), 1,
        "F1: editor still registered for sync")

    -- Retry with healthy disk: commits and closes.
    ed.title_bar.right_button.callback()
    local p2 = find_prompt()
    assert_true(p2 ~= nil, "F1b: retried close prompts again (draft survived)")
    dismiss_prompt(p2, "save")
    assert_true(find_editor() == nil, "F1b: healthy retry commits and closes")
    close_all_windows()
end

print("\n--- F3: canonical committed, derived write failed (chooser) ---")
do
    reset_editor_heuristics()
    -- Mirror the FM move into reader, and fail ONLY the reader's derived
    -- write: the pipeline reports saved_needs_regeneration while canonical
    -- intent IS committed. The chooser must treat the move as DONE.
    MenuOrderManager:setMirroringEnabled(true)
    MenuOrderManager:stageList("reader", "more_tools",
        util.tableDeepCopy(MenuOrderManager:getMenuItems(view, "more_tools")))
    MenuOrderManager:saveOrder("reader")

    UIScreens:showItemSortWidget({ ui = mock_ui_fm }, view, "tools")
    local dest_editor = find_editor()
    local in_calls = 0
    local orig_in = dest_editor.syncMovedIn
    dest_editor.syncMovedIn = function(self, id)
        in_calls = in_calls + 1; return orig_in(self, id)
    end

    local real_wno = KoreaderAdapter.writeNativeOrder
    KoreaderAdapter.writeNativeOrder = function(v, order_table)
        if v == "reader" then return false, "injected reader write failure" end
        return real_wno(v, order_table)
    end

    -- Real chooser, real callback: pending source order present (drag flow).
    UIScreens:showDestinationMenuChooser({ ui = mock_ui_fm }, view,
        "cons_alpha", "more_tools", nil, {"cons_beta", "cons_alpha"})
    local chooser
    for i = stack_size(), 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w and w.title and tostring(w.title):find("Move", 1, true)
                and type(w.item_table) == "table" then
            chooser = w break
        end
    end
    assert_true(chooser ~= nil, "F3-pre: destination chooser opened")
    KoreaderAdapter.writeNativeOrder = real_wno -- restore before assertions

    -- Pick the TOOLS destination specifically (the instruments hang on the
    -- Tools editor; the last listed choice is not necessarily Tools).
    local picked = false
    for _, choice in ipairs(chooser.item_table) do
        if type(choice.callback) == "function"
                and type(choice.text) == "string"
                and choice.text:find("Tools$") then
            choice.callback()
            picked = true
            break
        end
    end
    assert_true(picked, "F3-pre: Tools destination chosen")

    assert_eq(MenuOrderManager:getParentMenu(view, "cons_alpha"), "tools",
        "F3: committed move NOT rolled back (old bug restored staging)")
    assert_true(in_calls > 0,
        "F3: editors synchronized against the committed move")

    -- Durability across a real restart: the move is on disk.
    restart()
    assert_eq(MenuOrderManager:getParentMenu(view, "cons_alpha"), "tools",
        "F3: move durable after restart")
    close_all_windows()
    MenuOrderManager:setMirroringEnabled(false)
    wipe_all()
end

print("\n--- F4: canonical saved, live reload failed ---")
do
    reset_editor_heuristics()
    local ed = open_item_editor()
    make_editor_dirty(ed)
    ed.title_bar.right_button.callback()
    local p = find_prompt()
    -- Keep reloadLiveMenu REAL: we inject the failure at its inner
    -- applyLiveReload call, so ITS OWN error toast is what must appear.
    -- Watching the toasts pins the §5 contract: durable save reports BOTH
    -- "saved" AND the refresh failure - never a bare failure pretending the
    -- commit did not happen.
    local real_apply = MenuOrderManager.applyLiveReload
    MenuOrderManager.applyLiveReload = function(self, ...)
        return false, "injected live reload failure"
    end
    local err_refresh, notice_saved = false, false
    local real_err, real_notice = UIScreens.showError, UIScreens.showNotice
    UIScreens.showError = function(self, msg)
        if tostring(msg):find("refreshed live", 1, true) then
            err_refresh = true end
        return real_err(self, msg)
    end
    UIScreens.showNotice = function(self, msg)
        if tostring(msg):find("menu order saved", 1, true) then
            notice_saved = true end
        return real_notice(self, msg)
    end
    dismiss_prompt(p, "save")
    MenuOrderManager.applyLiveReload = real_apply
    UIScreens.showError, UIScreens.showNotice = real_err, real_notice

    assert_true(find_editor() == nil,
        "F4: edit is durable - editor closes normally")
    assert_eq(saved_list("more_tools"):find("cons_alpha", 1, true) ~= nil, true,
        "F4: saved arrangement intact")
    assert_true(err_refresh,
        "F4: refresh failure reported to the user (restart required)")
    assert_true(notice_saved, "F4: durable save still announced as saved")
    close_all_windows()
    wipe_all()
end

print("\n--- F5: semantic no-op save resolves phantom dirt ---")
do
    reset_editor_heuristics()
    local ed = open_item_editor()
    make_editor_dirty(ed)
    ed.title_bar.right_button.callback()
    local p = find_prompt()
    -- Stub the manager-level save to report the pipeline's "unchanged"
    -- outcome (canonical already equals this model). The UI must resolve
    -- the editor's phantom dirt exactly like a real save does.
    local orig_save = MenuOrderManager.saveOrder
    MenuOrderManager.saveOrder = function(self, v)
        local outcome = CommitPipeline.unchangedOutcome()
        outcome.committed = true
        return true, "unchanged", outcome
    end
    dismiss_prompt(p, "save")
    MenuOrderManager.saveOrder = orig_save

    assert_true(find_editor() == nil,
        "F5: 'unchanged' means already-saved - editor closes clean")
    close_all_windows()

    -- Leak check for the NEXT scenario: the stubbed save never consumed the
    -- staged draft, so discard it explicitly here (the F5 assertion itself
    -- is about the close behavior above).
    MenuOrderManager:reloadFromDisk(view)
    MenuOrderManager:loadOrder(view)
end

-- -------------------------------------------------------------------
-- §8: transaction-owned metadata vs Discard.
-- -------------------------------------------------------------------
print("\n--- G1/G2: metadata toggles survive Discard, commit with Save ---")
do
    reset_editor_heuristics()
    -- G1: layout discarded; the mirroring preference stays; neither the
    -- abandoned layout NOR anything else rides the next unrelated save.
    local base = saved_list("more_tools")
    local ed = open_item_editor()
    make_editor_dirty(ed)
    MenuOrderManager:setMirroringEnabled(true) -- transaction-owned flip
    x_discard(ed)
    assert_eq(saved_list("more_tools"), base, "G1: abandoned layout discarded")
    assert_eq(IntentStore.meta().mirror_changes, true,
        "G1: independent preference survives Discard")
    discard_then_unrelated_save_and_restart()
    assert_eq(IntentStore.meta().mirror_changes, true,
        "G1: preference durable after unrelated save + restart")
    assert_eq(saved_list("more_tools"), base,
        "G1: abandoned layout did not ride the unrelated save")

    -- G2: flipping back and saving commits TOGETHER with the layout.
    local ed2 = open_item_editor()
    make_editor_dirty(ed2)
    MenuOrderManager:setMirroringEnabled(false)
    ed2.title_bar.right_button.callback()
    local p = find_prompt()
    dismiss_prompt(p, "save")
    assert_eq(IntentStore.meta().mirror_changes, false,
        "G2: flip committed with the layout (single coherent world)")
    assert_eq(saved_list("more_tools") == base, false,
        "G2: layout change committed alongside")
    close_all_windows()
    wipe_all()
end

-- -------------------------------------------------------------------
-- §9 (audit completeness): close paths x change kinds the C/D/A series
-- did not pair up. Every new combo re-asserts the three invariants:
--   (a) no mixed state - editor model, canonical order and disk agree
--       along the whole route;
--   (b) an abandoned staged edit never survives a LATER unrelated save,
--       verified across a restart-equivalent reload;
--   (c) sync notifications fire only after durable canonical success
--       (observation technique of S1/S2/test_notify_after_durable_success).
print("\n--- H1: UNHIDE is a first-class dirty kind ---")
do
    reset_editor_heuristics()
    -- Commit a hide first so an unhide can be staged against durable state.
    local ed = open_item_editor()
    local vrow
    for _, r in ipairs(ed.item_table) do
        if r.item_id == "cons_alpha" then vrow = r break end
    end
    vrow.callback() -- immediate-applied hide (staged)
    ed.title_bar.right_button.callback()
    dismiss_prompt(find_prompt(), "save")
    assert_eq(MenuOrderManager:isItemHidden(view, "cons_alpha"), true,
        "H1-pre: hide committed")
    close_all_windows()

    local function hidden_row_in(widget)
        for _, r in ipairs(widget.item_table) do
            if r.item_id == "cons_alpha" and r.is_hidden_row then return r end
        end
    end

    -- Discard route: staged unhide reverts, model + canonical + disk agree.
    local ed2 = open_item_editor()
    local hrow = hidden_row_in(ed2)
    assert_true(hrow ~= nil, "H1: reopened editor lists the hidden row")
    hrow.callback() -- staged unhide
    assert_eq(hrow.is_hidden_row, nil,
        "H1a: editor model row flipped back to visible")
    assert_eq(hrow.checked_func(), true,
        "H1a: editor checkbox reflects the unhidden state")
    ed2.title_bar.right_button.callback()
    local p = find_prompt()
    assert_true(p ~= nil, "H1: X on a staged unhide prompts")
    dismiss_prompt(p, "discard")
    assert_eq(MenuOrderManager:isItemHidden(view, "cons_alpha"), true,
        "H1a: Discard reverts the unhide (canonical agrees)")
    restart()
    assert_eq(MenuOrderManager:isItemHidden(view, "cons_alpha"), true,
        "H1a: disk still hides the item after reload (no mixed state)")

    -- Abandoned unhide never rides a later unrelated save.
    local ed3 = open_item_editor()
    hidden_row_in(ed3).callback()
    x_discard(ed3)
    discard_then_unrelated_save_and_restart()
    assert_eq(MenuOrderManager:isItemHidden(view, "cons_alpha"), true,
        "H1b: abandoned unhide absent after unrelated save + restart")

    -- Save route commits the unhide durably.
    local ed4 = open_item_editor()
    hidden_row_in(ed4).callback()
    ed4.title_bar.right_button.callback()
    dismiss_prompt(find_prompt(), "save")
    assert_eq(MenuOrderManager:isItemHidden(view, "cons_alpha"), false,
        "H1c: Save commits the unhide canonically")
    restart()
    assert_eq(MenuOrderManager:isItemHidden(view, "cons_alpha"), false,
        "H1c: committed unhide durable on disk")
    close_all_windows()
end

print("\n--- H2-H4: staged cross-menu moves meet the non-X close routes ---")
do
    reset_editor_heuristics()
    local home_before = saved_list("more_tools")
    local dest_before = saved_list("tools")

    local function stage_move_and_hide(widget)
        MenuOrderManager:moveItemToMenu(view, "cons_alpha", "more_tools", "tools")
        for _, r in ipairs(widget.item_table) do
            if r.item_id == "cons_alpha" then r.callback() break end
        end
    end

    -- H2: PROGRAMMATIC close discards a staged move (+hide) coherently;
    --     no sync notification may fire anywhere along this route.
    local notify_calls = 0
    local orig_notify = UIScreens._notifyEditorsOfMove
    UIScreens._notifyEditorsOfMove = function(self, ...)
        notify_calls = notify_calls + 1
        return orig_notify(self, ...)
    end
    local ed = open_item_editor()
    stage_move_and_hide(ed)
    UIManager:close(ed)
    UIScreens._notifyEditorsOfMove = orig_notify
    assert_eq(notify_calls, 0,
        "H2: move-staged programmatic close fires NO sync notification")
    assert_eq(MenuOrderManager:getParentMenu(view, "cons_alpha"), "more_tools",
        "H2: programmatic close discarded the staged move")
    assert_eq(MenuOrderManager:isItemHidden(view, "cons_alpha"), false,
        "H2: hide half of the staged pair discarded too (no half-revert)")
    assert_eq(saved_list("more_tools"), home_before,
        "H2: source menu canonical state intact")
    assert_eq(saved_list("tools"), dest_before,
        "H2: destination menu canonical state intact")
    assert_eq(UIEditorRegistry:countLive(view), 0,
        "H2: sync registry empty after programmatic close")
    restart()
    assert_eq(MenuOrderManager:getParentMenu(view, "cons_alpha"), "more_tools",
        "H2: disk agrees after reload (no mixed state)")
    -- The abandoned pair must not ride a later unrelated save.
    local ed2b = open_item_editor()
    stage_move_and_hide(ed2b)
    UIManager:close(ed2b)
    discard_then_unrelated_save_and_restart()
    assert_eq(MenuOrderManager:getParentMenu(view, "cons_alpha"), "more_tools",
        "H2b: abandoned move absent after unrelated save + restart")
    assert_eq(MenuOrderManager:isItemHidden(view, "cons_alpha"), false,
        "H2b: abandoned hide absent after unrelated save + restart")

    -- H3: Back-key silent close discards a staged move coherently.
    reset_editor_heuristics()
    local ed3 = open_item_editor()
    MenuOrderManager:moveItemToMenu(view, "cons_alpha", "more_tools", "tools")
    ed3:onCancelOrClose()
    assert_true(find_editor() == nil, "H3: Back closed the move-staged editor")
    assert_true(find_prompt() == nil, "H3: Back never prompted")
    assert_eq(MenuOrderManager:getParentMenu(view, "cons_alpha"), "more_tools",
        "H3: silent close discarded the staged move")
    restart()
    assert_eq(MenuOrderManager:getParentMenu(view, "cons_alpha"), "more_tools",
        "H3: disk agrees after reload (no mixed state)")

    -- H4: Cancel on a staged move keeps the editor open, saves nothing.
    reset_editor_heuristics()
    local ed4 = open_item_editor()
    MenuOrderManager:moveItemToMenu(view, "cons_alpha", "more_tools", "tools")
    ed4.title_bar.right_button.callback()
    local p4 = find_prompt()
    assert_true(p4 ~= nil, "H4: X on a staged move prompts")
    dismiss_prompt(p4, "cancel")
    assert_true(find_editor() ~= nil, "H4: Cancel kept the editor open")
    -- Cancel keeps the editor open WITH its staged work intact (C3
    -- precedent): the live projection legitimately previews the staged
    -- destination (graphs resolve through the open transaction), while
    -- canonical intent stays untouched. Pin both halves of that contract.
    assert_eq(MenuOrderManager:getParentMenu(view, "cons_alpha"), "tools",
        "H4: staged destination stays previewed while editing continues")
    assert_eq(IntentStore.view(view).order_override.cons_alpha, nil,
        "H4: Cancel persisted nothing canonically")
    x_discard(ed4)
    assert_eq(saved_list("tools"), dest_before, "H4: cleanup left no residue")
    close_all_windows()
end

print("\n--- H5: tab drag meets the silent close routes ---")
do
    local function tabs_csv()
        return table.concat(MenuOrderManager:getTabs(view), ",")
    end
    local function swap_first_two_csv(csv)
        local t = {}
        for x in csv:gmatch("[^,]+") do t[#t + 1] = x end
        t[1], t[2] = t[2], t[1]
        return table.concat(t, ",")
    end
    local baseline_tabs = tabs_csv()

    -- Footer exit icon: silent full discard of the staged tab drag.
    UIScreens:showTabReorderDialog({ ui = mock_ui_fm }, view)
    local tabdlg = find_editor()
    assert_true(tabdlg ~= nil, "H5: tab dialog opened")
    swap_first_two(tabdlg)
    tabdlg.footer_cancel.callback()
    assert_true(find_editor() == nil, "H5: footer exit closed the tab dialog")
    assert_eq(tabs_csv(), baseline_tabs,
        "H5: footer exit discarded the staged tab drag")

    -- Back key: identical outcome.
    UIScreens:showTabReorderDialog({ ui = mock_ui_fm }, view)
    tabdlg = find_editor()
    swap_first_two(tabdlg)
    tabdlg:onCancelOrClose()
    assert_true(find_editor() == nil, "H5: Back closed the tab dialog")
    assert_eq(tabs_csv(), baseline_tabs,
        "H5: Back discarded the staged tab drag")

    -- An abandoned tab drag must not ride a later unrelated save.
    UIScreens:showTabReorderDialog({ ui = mock_ui_fm }, view)
    tabdlg = find_editor()
    swap_first_two(tabdlg)
    UIManager:close(tabdlg)
    discard_then_unrelated_save_and_restart()
    assert_eq(tabs_csv(), swap_first_two_csv(baseline_tabs),
        "H5b: abandoned tab drag absent after unrelated save + restart")
    close_all_windows()
    wipe_all()
end

close_all_windows()
wipe_all()
print(string.format("\n=== %d passed, %d failed ===\n", passed, failed))
os.exit(failed == 0 and 0 or 1)

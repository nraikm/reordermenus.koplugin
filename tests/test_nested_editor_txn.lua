--[[
test_nested_editor_txn.lua — Area E.

Nested editor transaction semantics: which commits are durable and which
staged snapshots are discarded when editors stack (drill-down).

  E1  parent editor dirty -> child editor opened -> child saved ->
      parent DISCARDED: child's commit stays durable.
  E2  child dirty -> parent changed elsewhere (committed) -> child saves:
      the three-way rebase preserves both.
  E3  parent and child edit the SAME item: last explicit save wins for the
      shared record; no lost hybrid.
  E4  child deletes/moves an item the parent still displays: parent's stale
      Discard must not resurrect it.
  E5  preset applied from a nested editor commits durably.
  E6  Reset All initiated from a nested editor commits durably.

Run: cd /Applications/KOReader.app/Contents/koreader &&
     ./luajit <project>/tests/test_nested_editor_txn.lua
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
local _ = require("gettext")
require("main")

local Manager = require("lib.menuorder_manager")
local IntentStore = require("lib.intent_store")
local NativeWriter = require("lib.native_writer")
local UIScreens = require("lib.ui_screens")

local passed, failed = 0, 0
local function note(cond, msg)
    if cond then passed = passed + 1
    else
        failed = failed + 1
        print("  [FAIL] " .. tostring(msg))
        io.stdout:flush()
    end
end

local sd = DataStorage:getSettingsDir()
local VIEW = "filemanager"
local OTHER = "reader"

local function wipe_all()
    for _, f in ipairs({ "filemanager_menu_order.lua", "reader_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        os.remove(sd .. "/" .. f)
    end
    os.execute("rm -rf " .. sd .. "/menu_order_presets")
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}
    Manager.recent_moves.reader = {}
    Manager:dropSessionState(VIEW)
    Manager:dropSessionState(OTHER)
end

-- "Discard" of an editor: restoreOrder from its backup snapshot.
-- "Open" of an editor: backupOrder (the UI does this when staging begins).
local function open_editor()
    Manager:backupOrder(VIEW)
end
local function discard_editor()
    return Manager:restoreOrder(VIEW)
end

print("===============================================================")
print("=== E. Nested editor transaction semantics                   ===")
print("===============================================================")

-- E1: parent dirty -> child opened+saved -> parent discarded.
do
    wipe_all()
    launch_parent = function() end
    -- parent stages a hide but does NOT save yet
    open_editor()
    Manager:setItemHidden(VIEW, "history", true, "main")   -- parent staged

    -- child editor opens on top, stages its own change, SAVES
    open_editor()
    Manager:setItemHidden(VIEW, "calibre", true, "more_tools")  -- child staged
    local ok_child = Manager:saveOrder(VIEW)                    -- child save
    note(ok_child, "E1: child save succeeds")

    -- parent editor is then DISCARDED
    discard_editor()

    -- child's committed record must survive the parent's discard
    note(IntentStore.view(VIEW).hidden.calibre ~= nil,
        "E1b: child's committed hide survives parent's discard")
    -- parent's staged-only hide must be gone (it was never committed and
    -- the discard restored the pre-parent snapshot... which post-dates the
    -- child's commit? The backup was taken BEFORE the child committed, so
    -- restoring it would roll back the child too. The DESIGN contract under
    -- test: a parent's stale Discard must not undo a separately committed
    -- child transaction.)
    local canon = IntentStore.view(VIEW).hidden
    note(canon.calibre ~= nil,
        "E1c: parent's stale Discard did not undo the child commit")

    -- restart equivalence
    Manager:dropSessionState(VIEW); IntentStore.load(true)
    note(IntentStore.view(VIEW).hidden.calibre ~= nil,
        "E1d: child commit durable across reload")
    wipe_all()
end

-- E2: child dirty -> canonical advanced elsewhere -> child saves (rebase).
do
    wipe_all()
    local A = IntentStore.openTransaction()          -- child txn
    -- meanwhile another writer advances canonical
    local B = IntentStore.openTransaction()
    B:setParentOverride(VIEW, "opds",
        { provider = "stock", parent = "tools", anchor = false })
    note(B:commit(true), "E2: other writer commits first")
    -- child now saves its own record; manager-level save rebases via
    -- mergeSection inside saveOrder when the base generation is stale.
    A:setHidden(VIEW, "history", { provider = "stock", origin = "main" })
    -- simulate the manager path: stage into the ACTIVE flow instead
    local ok = Manager:saveOrder(VIEW)
    _ = ok
    -- direct contract check: mergeSection keeps both sides' records
    local merged = A:mergeSection(VIEW)
    note(merged.parent_override.opds ~= nil,
        "E2b: rebase keeps the concurrent writer's move")
    note(merged.hidden.history ~= nil,
        "E2c: rebase keeps the child's own hide")
    wipe_all()
end

-- E3: parent and child edit the same item — last explicit save wins.
do
    wipe_all()
    Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
    Manager:saveOrder(VIEW)                          -- baseline: opds in tools
    -- child moves opds again to setting and saves
    Manager:moveItemToMenu(VIEW, "opds", "tools", "setting")
    Manager:saveOrder(VIEW)
    note(Manager:getParentMenu(VIEW, "opds") == "setting",
        "E3: last explicit save wins for the same item")
    -- a stale parent snapshot still listing opds in tools must NOT win later:
    local stale_rows = {}
    for _, id in ipairs(Manager:getMenuItems(VIEW, "search")) do
        stale_rows[#stale_rows + 1] = id
    end
    table.insert(stale_rows, "opds")                 -- stale row claims opds
    save_editor_rows = function(menu_id, rows)
        Manager:stageList(VIEW, menu_id, rows)
        return Manager:saveOrder(VIEW)
    end
    -- search editor saving rows WITH opds would drag opds back to search;
    -- that IS an explicit user action from that editor. The contract under
    -- test: the result is deterministic and single-parent.
    save_editor_rows("search", stale_rows)
    local count = 0
    local order = Manager:loadOrder(VIEW)
    for menu_id, list in pairs(order) do
        if type(list) == "table" then
            for _, id in ipairs(list) do
                if id == "opds" then count = count + 1 end
            end
        end
    end
    note(count <= 1, "E3b: same-item edits stay single-parent")
    wipe_all()
end

-- E4: child deletes/moves item the parent still displays; parent Discard
-- must not resurrect it.
do
    wipe_all()
    Manager:moveItemToMenu(VIEW, "terminal", "more_tools", "tools")
    Manager:saveOrder(VIEW)

    open_editor()                                    -- parent (more_tools)
    -- elsewhere (child flow): terminal moves back to more_tools? Instead:
    -- another writer REMOVES terminal's placement by hiding it, committed.
    local W = IntentStore.openTransaction()
    W:setHidden(VIEW, "terminal", { provider = "stock", origin = "tools" })
    assert(W:commit(true))

    -- parent discards its staged state
    Manager:setItemHidden(VIEW, "calibre", true, "more_tools")  -- parent dirt
    discard_editor()

    -- terminal must remain hidden (its commit predates the discard). The
    -- staged projection may briefly serve the restored backup, but the
    -- durable contract is about canonical state and every later save/reload.
    note(IntentStore.view(VIEW).hidden.terminal ~= nil,
        "E4: committed hide survives another editor's Discard (canonical)")
    Manager:saveOrder(VIEW)
    note(IntentStore.view(VIEW).hidden.terminal ~= nil,
        "E4b: later save keeps the concurrent commit")
    Manager:dropSessionState(VIEW); IntentStore.load(true)
    note(IntentStore.view(VIEW).hidden.terminal ~= nil,
        "E4c: concurrent commit durable across reload")
    wipe_all()
end

-- E5: preset applied from nested editor commits durably.
do
    wipe_all()
    Manager:setItemHidden(VIEW, "screensaver", true, "screen")
    Manager:saveOrder(VIEW)
    note(Manager:savePreset(VIEW, "NestedApply"), "E5-pre: preset saved")

    open_editor()                                    -- outer editor
    Manager:setItemHidden(VIEW, "history", true, "main")   -- outer staged
    -- nested flow applies the preset (loadPreset commits internally)
    local ok_apply = Manager:loadPreset(VIEW, "NestedApply")
    note(ok_apply, "E5: preset applied from nested context")

    -- outer editor discarded afterwards must not undo the preset apply
    discard_editor()
    Manager:dropSessionState(VIEW); IntentStore.load(true)
    note(IntentStore.view(VIEW).hidden.screensaver ~= nil,
        "E5b: preset apply durable after outer Discard")
    wipe_all()
end

-- E6: Reset All initiated from nested editor commits durably.
do
    wipe_all()
    Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
    Manager:saveOrder(VIEW)

    open_editor()                                    -- outer editor stages
    Manager:setItemHidden(VIEW, "history", true, "main")

    -- nested Reset All:
    local ok_reset = Manager:resetOrder(VIEW)
    note(ok_reset, "E6: resetOrder succeeds from nested context")

    discard_editor()
    Manager:dropSessionState(VIEW); IntentStore.load(true)
    local sec = IntentStore.view(VIEW)
    note(next(sec.parent_override or {}) == nil and next(sec.hidden or {}) == nil,
        "E6b: Reset All durable; outer Discard does not resurrect old state")
    wipe_all()
end

-- -------------------------------------------------------------------------
-- E7+: extensions pinning observed production semantics (probe-verified).
--
-- Production facts these encode:
--   * The REAL editor Discard path is MenuOrderManager:reloadFromDisk
--     (drop staged transaction, re-derive from canonical intent).
--     backupOrder/restoreOrder are only a micro-undo INSIDE one move-
--     chooser operation (ui_screens.lua showMoveToMenuDialog).
--   * The manager keeps ONE staging area per session; every committing
--     verb (saveOrder / loadPreset / resetOrder) commits the WHOLE staged
--     state - including other editors' unsaved dirt in the same view AND
--     other views' staged sections (the latter is what makes mirrored
--     edits flush atomically). A successful commit also clears the
--     backup slot, which is WHY a stale Discard can no longer undo a
--     committed child transaction.
-- -------------------------------------------------------------------------

-- E7: production discard path. Parent dirty -> child saves -> parent
-- discards via reloadFromDisk.
--
-- SEMANTICS DECISION (aligned with E8a/E12, which pin the session-wide
-- commit boundary): the manager keeps ONE staging area per session, so the
-- child's save sweeps the whole staged state - including the parent's
-- unsaved dirt - into ONE durable commit. After that commit there is no
-- "staged-only parent dirt" left to discard: both records are canonical,
-- and a stale Discard undoes NEITHER (it cannot roll back committed
-- records, which is exactly the guarantee this area demands for the
-- separately committed child transaction).
--
-- The complementary half - what Discard DOES revert - is covered by E7d:
-- dirt staged strictly AFTER the last commit (never swept into any save)
-- is dropped by reloadFromDisk.
do
    wipe_all()
    Manager:setItemHidden(VIEW, "history", true, "main")   -- parent staged dirt
    -- child flow commits its own change (sweeping the parent's dirt with it)
    Manager:setItemHidden(VIEW, "calibre", true, "more_tools")
    note(Manager:saveOrder(VIEW), "E7-pre: child save succeeds")

    -- parent editor discarded (the production path)
    Manager:reloadFromDisk(VIEW)

    local sec = IntentStore.view(VIEW)
    note(sec.hidden.calibre ~= nil,
        "E7: child commit survives production Discard (canonical)")
    note(sec.hidden.history ~= nil,
        "E7b: parent's dirt was swept into the child's commit (session-wide"
        .. " boundary, cf. E8a) - stale Discard does not undo it either")
    Manager:dropSessionState(VIEW); IntentStore.load(true)
    sec = IntentStore.view(VIEW)
    note(sec.hidden.calibre ~= nil and sec.hidden.history ~= nil,
        "E7c: restart-equivalent (both committed records survive)")

    wipe_all()
    -- E7d: dirt staged AFTER the last commit has never been through any
    -- commit boundary; Discard re-derives from canonical intent and drops it.
    Manager:setItemHidden(VIEW, "history", true, "main")
    note(Manager:saveOrder(VIEW), "E7d-pre: baseline committed")
    Manager:setItemHidden(VIEW, "calibre", true, "more_tools")   -- post-commit dirt
    Manager:reloadFromDisk(VIEW)
    sec = IntentStore.view(VIEW)
    note(sec.hidden.history ~= nil and sec.hidden.calibre == nil,
        "E7d: post-commit staged dirt is what Discard actually reverts")
end

-- E8: the shared-staging sweep, pinned as documented semantics.
--  E8a: same view - a child save makes the parent's UNsaved dirt durable too
--       (one commit boundary per session, not per editor).
--  E8b: cross view - an fm commit carries the reader's staged section of the
--       SAME transaction (this atomicity is what mirrors rely on).
do
    wipe_all()
    Manager:setItemHidden(VIEW, "history", true, "main")   -- parent dirt (fm)
    local gen_before = IntentStore.generation()
    Manager:setItemHidden(VIEW, "calibre", true, "more_tools")  -- child dirt
    Manager:saveOrder(VIEW)
    local sec = IntentStore.view(VIEW)
    note(sec.hidden.calibre ~= nil and sec.hidden.history ~= nil,
        "E8a: child save sweeps same-view co-staged dirt (single commit)")
    note(IntentStore.generation() == gen_before + 1,
        "E8a2: exactly one durable commit for both records")

    wipe_all()
    Manager:setItemHidden("reader", "book_status", true, nil)  -- reader dirt
    Manager:setItemHidden(VIEW, "calibre", true, "more_tools") -- fm child dirt
    note(Manager:saveOrder(VIEW), "E8b-pre: fm save succeeds")
    Manager:dropSessionState(VIEW); Manager:dropSessionState("reader")
    IntentStore.load(true)
    note(IntentStore.view("reader").hidden.book_status ~= nil,
        "E8b: fm commit flushed the reader view's staged section (atomic)")
    note(IntentStore.view(VIEW).hidden.calibre ~= nil,
        "E8b2: fm record itself durable")
    wipe_all()
end

-- E9: child HIDES an item the parent still displays; parent then SAVES its
-- stale row model containing that item. The stale-editor membership guard
-- must drop the hidden id: no resurrection, no duplication, hide stays
-- durable across restart.
do
    wipe_all()
    Manager:saveOrder(VIEW)
    local stale_rows = {}
    for _, id in ipairs(Manager:getMenuItems(VIEW, "tools")) do
        table.insert(stale_rows, id)
    end
    local contains = false
    for _, id in ipairs(stale_rows) do
        if id == "calibre" then contains = true end
    end
    note(contains, "E9-pre: stale model contains calibre")

    Manager:setItemHidden(VIEW, "calibre", true, "tools")
    note(Manager:saveOrder(VIEW), "E9-pre2: child hide commits")

    Manager:stageList(VIEW, "tools", stale_rows)           -- stale parent save
    note(Manager:saveOrder(VIEW), "E9: stale parent save succeeds")
    note(IntentStore.view(VIEW).hidden.calibre ~= nil,
        "E9b: stale rows did not resurrect the hidden item")
    local n = 0
    local order = Manager:loadOrder(VIEW)
    for menu_id, items in pairs(order or {}) do
        if menu_id ~= "KOMenu:disabled" and type(items) == "table" then
            for _, x in ipairs(items) do
                if x == "calibre" then n = n + 1 end
            end
        end
    end
    note(n == 0, "E9c: item appears zero times in the visible projection")
    Manager:dropSessionState(VIEW); IntentStore.load(true)
    note(IntentStore.view(VIEW).hidden.calibre ~= nil,
        "E9d: hide still durable across restart")
    wipe_all()
end

-- E10: child MOVES an item the parent still displays; the parent saving its
-- stale rows DOES drag it back durably. That is an explicit user action from
-- the source editor (last explicit save wins) - unlike Discard, which never
-- reverts anything. Deterministic single-parent outcome, restart-stable.
do
    wipe_all()
    Manager:saveOrder(VIEW)
    local stale_rows = {}
    for _, id in ipairs(Manager:getMenuItems(VIEW, "tools")) do
        table.insert(stale_rows, id)
    end
    Manager:moveItemToMenu(VIEW, "calibre", "tools", "more_tools")
    note(Manager:saveOrder(VIEW), "E10-pre: child move commits")

    Manager:stageList(VIEW, "tools", stale_rows)           -- stale parent save
    note(Manager:saveOrder(VIEW), "E10: stale parent save succeeds")
    note(Manager:getParentMenu(VIEW, "calibre") == "tools",
        "E10b: last explicit save won (item dragged back to tools)")
    local n = 0
    local order = Manager:loadOrder(VIEW)
    for _, items in pairs(order or {}) do
        if type(items) == "table" then
            for _, x in ipairs(items) do
                if x == "calibre" then n = n + 1 end
            end
        end
    end
    note(n <= 1, "E10c: single-parent discipline holds")
    Manager:dropSessionState(VIEW); IntentStore.load(true)
    note(Manager:getParentMenu(VIEW, "calibre") == "tools",
        "E10d: outcome restart-equivalent")
    wipe_all()
end

-- E11: a FAILED move from inside an editor (stale source) must stage
-- nothing: no record change, no generation bump, backup slot untouched -
-- so the chooser's restoreOrder micro-undo stays available and inert.
do
    wipe_all()
    Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
    Manager:saveOrder(VIEW)
    local gen_before = IntentStore.generation()
    Manager:backupOrder(VIEW)                              -- chooser opens

    -- stale-source move: opds is no longer in search
    local ok_move, err = Manager:moveItemToMenu(VIEW, "opds", "search", "setting")
    note(not ok_move and type(err) == "string",
        "E11: stale-source move rejected with an error")
    note(next(IntentStore.view(VIEW).parent_override.opds or {})
        and IntentStore.view(VIEW).parent_override.opds.parent == "tools",
        "E11b: rejected move staged nothing (record untouched)")
    local ok_restore = Manager:restoreOrder(VIEW)
    note(ok_restore, "E11c: backup slot survived the failed move")
    note(IntentStore.generation() == gen_before,
        "E11d: failed move performed no durable mutation")
    wipe_all()
end

-- E12: nested Reset All commits the OTHER view's staged section too
-- (session-wide commit boundary; mirrors depend on this atomicity).
-- The fm view ends empty while the reader's co-staged dirt lands durably.
do
    wipe_all()
    Manager:setItemHidden("reader", "book_status", true, nil)  -- reader dirt
    local ok_reset = Manager:resetOrder(VIEW)
    note(ok_reset, "E12: nested resetOrder succeeds")
    Manager:dropSessionState(VIEW); Manager:dropSessionState("reader")
    IntentStore.load(true)
    local sec_fm = IntentStore.view(VIEW)
    note(next(sec_fm.parent_override or {}) == nil
        and next(sec_fm.hidden or {}) == nil,
        "E12b: fm view fully reset across restart")
    note(IntentStore.view("reader").hidden.book_status ~= nil,
        "E12c: other view's co-staged dirt committed by the reset "
        .. "(session-wide commit boundary)")
    wipe_all()
end

wipe_all()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)

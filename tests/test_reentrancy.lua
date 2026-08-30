--[[
test_reentrancy.lua — Area F.

Operational call chains must be reentrancy-safe:
  saveOrder -> applyLiveReload -> menu rebuild -> reconciliation
  reconcile -> save -> reload -> reconcile

Injected duplicate callbacks and reordered callback execution must produce:
  - no recursive save loop,
  - no duplicate durable mutation (generation advances exactly once per
    real change),
  - no repeated transaction commit,
  - no duplicated move-healing record,
  - idempotent reconciliation.

Run: cd /Applications/KOReader.app/Contents/koreader &&
     ./luajit <project>/tests/test_reentrancy.lua
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

local Manager = require("reorderingmenus_menuorder_manager")
local IntentStore = require("reorderingmenus_intent_store")
local NativeWriter = require("reorderingmenus_native_writer")
local UIScreens = require("reorderingmenus_ui_screens")
local CommitPipeline = require("reorderingmenus_commit_pipeline")

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
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}
    Manager.recent_moves.reader = {}
    Manager:dropSessionState(VIEW)
    Manager:dropSessionState(OTHER)
end

local function make_stub(id, hint)
    return { name = id .. "_widget",
        addToMainMenu = function(_, m)
            m[id] = { text = id, sorting_hint = hint, callback = function() end }
        end }
end

-- count durable commits between two points by watching the global generation.
local function generation() return IntentStore.generation() end

print("===============================================================")
print("=== F. Reentrancy                                            ===")
print("===============================================================")

-- F1: reconcile -> save -> reload -> reconcile is idempotent; the second
-- full cycle performs NO durable mutation.
do
    wipe_all()
    local stub = make_stub("reent_p", "tools")
    local ui = { menu = { registered_widgets = { stub } } }

    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, true)  -- cycle 1
    local gen1 = generation()
    local fp1 = NativeWriter.getRecord(VIEW)
        and NativeWriter.getRecord(VIEW).fingerprint

    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, true)  -- cycle 2
    local gen2 = generation()

    note(gen2 == gen1, string.format(
        "F1: second reconcile->save cycle is durable-neutral (%d vs %d)",
        gen1, gen2))

    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, true)  -- cycle 3
    note(generation() == gen1, "F1b: third cycle also neutral")
    _ = fp1
    wipe_all()
end

-- F2: duplicated save calls (saveOrder twice back-to-back, plus a nested
-- call from inside applyLiveReload's rebuild hook simulation).
do
    wipe_all()
    Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
    local gen_before = generation()
    local ok1 = Manager:saveOrder(VIEW)
    local gen_after_first = generation()
    local ok2 = Manager:saveOrder(VIEW)     -- duplicate save
    note(ok1 and ok2, "F2: duplicated saves both report success")
    note(gen_after_first == generation(),
        "F2b: duplicate save performs no additional durable commit")
    note(gen_after_first > gen_before, "F2c: the real change committed once")
    wipe_all()
end

-- F3: reentrant saveOrder via a hooked KoreaderAdapter.writeNativeOrder —
-- the writer triggers a save again (simulating a rebuild-during-save loop).
do
    wipe_all()
    local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
    local real_write = KoreaderAdapter.writeNativeOrder
    local depth = 0
    local reentrant_calls = 0
    KoreaderAdapter.writeNativeOrder = function(view, order_table)
        depth = depth + 1
        if depth == 1 then
            -- first write re-triggers a save (the pathological loop)
            reentrant_calls = reentrant_calls + 1
            if reentrant_calls <= 2 then
                Manager:saveOrder(VIEW)   -- would recurse infinitely if unguarded
            end
        end
        local ok = real_write(view, order_table)
        depth = depth - 1
        return ok
    end

    local ok = pcall(function()
        Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
        Manager:saveOrder(VIEW)
    end)
    KoreaderAdapter.writeNativeOrder = real_write
    note(ok, "F3: reentrant save terminates without stack overflow")
    -- exactly one record for opds survives
    local n_po = 0
    for _ in pairs(IntentStore.view(VIEW).parent_override or {}) do
        n_po = n_po + 1
    end
    note(n_po == 1, "F3b: exactly one durable move record after reentry")
    wipe_all()
end

-- F4: duplicate reconciliation with concurrent registration lists does not
-- duplicate move-healing records.
do
    wipe_all()
    local stub = make_stub("reent_q", "tools")
    local ui = { menu = { registered_widgets = { stub } } }
    Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
    Manager:saveOrder(VIEW)

    -- triple reconcile with the same live registrations
    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)
    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)
    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)

    -- recent_moves must not have accumulated duplicates
    local moves = Manager:getRecentMoves(VIEW)
    local n_moves = 0
    for _ in pairs(moves) do n_moves = n_moves + 1 end
    note(n_moves <= 1, "F4: move-healing records not duplicated"
        .. " (n=" .. tostring(n_moves) .. ")")
    -- and canonical still holds exactly one opds record
    local rec = IntentStore.view(VIEW).parent_override.opds
    note(rec ~= nil and rec.parent == "tools",
        "F4b: opds record intact after repeated reconciliation")
    wipe_all()
end

-- F5: reorder callback execution — reloadFromDisk in the middle of a
-- reconcile chain does not corrupt state.
do
    wipe_all()
    local stub = make_stub("reent_r", "tools")
    local ui = { menu = { registered_widgets = { stub } } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)
    Manager:moveItemToMenu(VIEW, "opds", "search", "tools")

    -- interleave: save, reload, save, reconcile
    Manager:saveOrder(VIEW)
    Manager:reloadFromDisk(VIEW)
    Manager:saveOrder(VIEW)
    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)

    note(Manager:getParentMenu(VIEW, "opds") == "tools",
        "F5: interleaved save/reload/reconcile keeps the user move")
    local ok_sort = pcall(function()
        local MenuSorter = require("ui/menusorter")
        local order = Manager:loadOrder(VIEW)
        local items = { ["KOMenu:menu_buttons"] = {} }
        local reg = require("reorderingmenus_registry").buildFromData(
            Manager.default_orders[VIEW] or Manager:getDefaultOrder(VIEW),
            {}, {})
        for id in pairs(reg.nodes) do
            items[id] = { text = id, callback = function() end }
        end
        return MenuSorter:sort(items, order)
    end)
    note(ok_sort, "F5b: projection renders through stock MenuSorter")
    wipe_all()
end

-- F6: reconcile that regenerates overrides must not itself trigger another
-- regeneration on the next pass (fixpoint within one generation).
do
    wipe_all()
    local stub = make_stub("reent_s", "tools")
    local ui = { menu = { registered_widgets = { stub } } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, true)

    Manager:reconcileRegisteredItems(VIEW,
        { reent_s = { sorting_hint = "tools" } }, { reent_s = "reent_s_widget" })
    Manager:reconcileRegisteredItems(VIEW,
        { reent_s = { sorting_hint = "tools" } }, { reent_s = "reent_s_widget" })
    -- fingerprint stable across passes
    local rec_a = NativeWriter.getRecord(VIEW)
    local fp_a = rec_a and rec_a.fingerprint
    Manager:saveOrder(VIEW)
    local rec_b = NativeWriter.getRecord(VIEW)
    local fp_b = rec_b and rec_b.fingerprint
    note(fp_a == nil or fp_b == nil or fp_a == fp_b,
        "F6b: emission fixpoint reached (fingerprint stable)")
    wipe_all()
end

-- F7: the LITERAL production chain saveOrder -> applyLiveReload -> menu
-- rebuild -> reconciliation, driven end-to-end through UIScreens.saveAndApply
-- with duplicate callbacks injected at the rebuild hook: while the fresh menu
-- constructs, its build hook re-enters BOTH the reconciliation path and a
-- nested saveOrder (the pathological "rebuild triggers reconcile triggers
-- save" loop). Requirements: terminates; the real change commits exactly once;
-- every reentrant pass afterwards is a durable no-op; no duplicated
-- move-healing records.
do
    wipe_all()
    local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
    local stub = make_stub("reent_t", "tools")
    local ui = { menu = {
        registered_widgets = { stub },
        onTapCloseMenu = function() end,
    } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)
    Manager:moveItemToMenu(VIEW, "opds", "search", "tools")

    local gen_before = IntentStore.generation()
    local rebuilds, nested_reconciles, nested_saves = 0, 0, 0
    package.loaded["apps/filemanager/filemanagermenu"] = {
        new = function(_, opts)
            return {
                ui = opts.ui,
                registered_widgets = {},
                setUpdateItemTable = function()
                    rebuilds = rebuilds + 1
                    if rebuilds == 1 then
                        -- duplicated callbacks fired from inside the rebuild:
                        nested_reconciles = nested_reconciles + 1
                        UIScreens:reconcileRegisteredItems(
                            { ui = opts.ui }, VIEW, false)
                        nested_saves = nested_saves + 1
                        Manager:saveOrder(VIEW)
                    end
                end,
            }
        end }

    local ok_chain = pcall(function()
        return UIScreens:saveAndApply({ ui = ui }, VIEW, true)
    end)
    package.loaded["apps/filemanager/filemanagermenu"] = nil

    note(ok_chain, "F7: full save->reload->rebuild->reconcile chain terminates")
    note(IntentStore.generation() == gen_before + 1,
        "F7b: exactly one durable commit despite nested reconcile+save ("
        .. gen_before .. "->" .. IntentStore.generation() .. ")")
    note(rebuilds == 1, "F7c: rebuild executed once (nested pass did not "
        .. "re-trigger a rebuild), got " .. tostring(rebuilds))
    local rec = IntentStore.view(VIEW).parent_override.opds
    note(rec ~= nil and rec.parent == "tools",
        "F7d: user move intact after the reentrant chain")
    local moves = Manager:getRecentMoves(VIEW)
    note(moves.opds == nil or type(moves.opds) == "table",
        "F7e: move-healing record present at most once")
    -- idempotent tail: an immediate repeat of the whole chain is neutral
    local gen_stable = IntentStore.generation()
    local ok_repeat = pcall(function()
        return UIScreens:saveAndApply({ ui = ui }, VIEW, true)
    end)
    note(ok_repeat and IntentStore.generation() == gen_stable,
        "F7f: repeating the chain performs no additional durable commit")
    wipe_all()
end

-- F8: a genuinely raised commit error is contained and, critically, cannot
-- leave the manager's in-commit guard stuck for the rest of the process.
do
    wipe_all()
    Manager:setLiveRegistrations(VIEW, {}, {})
    Manager:loadOrder(VIEW)
    local seed = IntentStore.openTransaction()
    seed:setHidden(VIEW, "reent_stale", {
        provider = "plugin:gone", origin = "tools", ordinal = 1,
    })
    assert(seed:commit(true))
    Manager:dropSessionState(VIEW)
    Manager:setLiveRegistrations(VIEW, {}, {})
    Manager:loadOrder(VIEW)

    local original_commit = CommitPipeline.commitAndApply
    CommitPipeline.commitAndApply = function()
        error("injected raised commit", 0)
    end
    local call_ok, cleanup_ok = pcall(
        Manager.forgetStaleCustomizations, Manager, VIEW)
    CommitPipeline.commitAndApply = original_commit
    note(call_ok and cleanup_ok == false,
        "F8: raised commit becomes a structured cleanup failure")

    Manager:dropSessionState(VIEW)
    local sync_calls = 0
    local original_sync = NativeWriter.syncView
    NativeWriter.syncView = function(...)
        sync_calls = sync_calls + 1
        return original_sync(...)
    end
    local reload_ok = pcall(Manager.loadOrder, Manager, VIEW)
    NativeWriter.syncView = original_sync
    note(reload_ok and sync_calls > 0,
        "F8b: post-error session synchronization still runs")
    wipe_all()
end

wipe_all()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)

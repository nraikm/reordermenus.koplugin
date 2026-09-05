--[[--
test_p0_spent_txn_gate.lua — P0 gate §4 residual cells.

Covers the two spent-transaction behaviors the main contract suite leaves
implicit, without weakening anything it pins:

  G1. discard-then-commit: a deliberately DISCARDED transaction refuses
      commit() with the explicit spent-state contract result
      (false, "transaction_spent"); no generation or epoch moves.

  G2. a transaction held OPEN across ANOTHER transaction's successful
      save must never silently overwrite the newer canonical world:
      committing it afterwards hits the optimistic-concurrency guard
      (false, "stale_transaction"), canonical keeps the newer writer's
      records, and the stale staging appears nowhere.

Run standalone:
    cd /Applications/KOReader.app/Contents/koreader && \
    KO_HOME=$(mktemp -d) ./luajit <project>/tests/test_p0_spent_txn_gate.lua
--]]

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

require("main") -- sorting-hint guard, exactly like a launch

local IntentStore = require("lib.intent_store")

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or ""))
    else
        failed = failed + 1
        io.stdout:flush()
        print("  [FAIL] " .. (msg or "") ..
            string.format(" -> expected %s, got %s",
                tostring(expected), tostring(actual)))
    end
end

local sd = DataStorage:getSettingsDir()
local function wipe_world()
    os.remove(sd .. "/filemanager_menu_order.lua")
    os.remove(sd .. "/reader_menu_order.lua")
    os.remove(sd .. "/reorderingmenus_intent.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    os.remove(sd .. "/reorderingmenus_state.lua")
    IntentStore.load(true)
end

print("===============================================================")
print("=== P0 gate: spent-transaction residual cells               ===")
print("===============================================================")

-- ---------------------------------------------------------------------
print("\n--- G1: discard-then-commit refuses with transaction_spent ---")
do
    wipe_world()
    local txn = IntentStore.openTransaction()
    txn:setPositionOverride("filemanager", "gate_a",
        { after = false, provider = "stock" })
    txn:discard()
    local gen_before = IntentStore.generation()
    local epoch_before = IntentStore.storeEpoch()

    local ok, err = txn:commit(true)
    assert_eq(ok, false, "commit after discard refuses")
    assert_eq(err, "transaction_spent", "refusal carries the spent reason")
    assert_eq(IntentStore.generation(), gen_before,
        "refused commit does not bump generation")
    assert_eq(IntentStore.storeEpoch(), epoch_before,
        "refused commit does not move the store epoch")

    -- canonical never saw the record
    local fresh = IntentStore.openTransaction()
    local section = fresh:view("filemanager")
    assert_eq(section.position_override["gate_a"], nil,
        "discarded record never reached canonical")

    -- idempotent teardown stays harmless afterwards
    assert_eq(txn:discard(), true, "discard after refused commit stays a no-op")
end

-- ---------------------------------------------------------------------
print("\n--- G2: open txn across another save hits the stale guard ---")
do
    wipe_world()
    -- Writer A stages a reader edit and KEEPS the handle.
    local stale = IntentStore.openTransaction()
    stale:setPositionOverride("reader", "gate_stale",
        { after = false, provider = "stock" })
    assert_eq(stale:changedViews().reader, true, "stale txn staged an edit")

    -- Writer B commits a filemanager edit successfully: generation moves.
    local newer = IntentStore.openTransaction()
    newer:setPositionOverride("filemanager", "gate_newer",
        { after = false, provider = "stock" })
    local ok_new = newer:commit(true)
    assert_eq(ok_new, true, "concurrent newer writer commits cleanly")
    local gen_after_newer = IntentStore.generation()

    -- Writer A's stale commit must refuse, not silently drop B's work.
    local ok_stale, err_stale = stale:commit(true)
    assert_eq(ok_stale, false, "stale transaction commit refuses")
    assert_eq(err_stale, "stale_transaction",
        "refusal carries the stale reason")

    -- Canonical still holds exactly the newer world.
    local probe = IntentStore.openTransaction()
    local fm = probe:view("filemanager")
    local rd = probe:view("reader")
    assert_eq(fm.position_override["gate_newer"] ~= nil, true,
        "newer writer's record survives in canonical")
    assert_eq(rd.position_override["gate_stale"], nil,
        "stale writer's record never reached canonical")
    assert_eq(IntentStore.generation(), gen_after_newer,
        "refused stale commit did not bump generation")

    -- The funnel path for the same race: one bounded rebase, then either
    -- success carrying BOTH edits or a truthful failure - never loss.
    local CommitPipeline = require("lib.commit_pipeline")
    local rebased_txn = IntentStore.openTransaction()
    rebased_txn:setPositionOverride("reader", "gate_rebased",
        { after = false, provider = "stock" })
    -- Simulate a racing commit between staging and funnel commit:
    local racer = IntentStore.openTransaction()
    racer:setHidden("filemanager", "gate_race", { provider = "stock" })
    assert_eq(racer:commit(true), true, "racer commits before the funnel")
    local outcome = CommitPipeline.commitAndApply(rebased_txn, {})
    assert_eq(outcome.committed, true,
        "funnel rebase lands the raced edit")
    assert_eq(outcome.error, nil, "rebased outcome carries no error")
    local probe2 = IntentStore.openTransaction()
    assert_eq(probe2:view("reader").position_override["gate_rebased"] ~= nil,
        true, "rebased reader record committed")
    assert_eq(probe2:view("filemanager").hidden["gate_race"] ~= nil,
        true, "racer's record survived the rebase (nothing dropped)")
end

wipe_world()
print(string.format("\n=== %d passed, %d failed ===\n", passed, failed))
os.exit(failed == 0 and 0 or 1)

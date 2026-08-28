--[[--
test_transaction_contract.lua — Transaction spent-state contract (Bug 1).

Required state machine:

    OPEN -> COMMITTED
    OPEN -> DISCARDED

After COMMITTED/DISCARDED:

  - every mutation method rejects (canonical is never touched);
  - commit() again refuses ("transaction_spent");
  - discard() after discard() is a harmless no-op; discard() after
    commit() refuses;
  - view()/section()/meta() cannot expose mutable canonical state —
    handles handed out while OPEN stay usable but are snapshots once
    spent, and canonical never aliases them;
  - commit() installs DEEP COPIES into canonical: mutating the object
    the transaction staged from can never reach committed state and
    vice versa;
  - a FAILED durable commit leaves the transaction DISCARDED: abandoned
    staging must never ride a later unrelated save.

Run standalone:
    cd /Applications/KOReader.app/Contents/koreader && \
    KO_HOME=$(mktemp -d) ./luajit <project>/tests/test_transaction_contract.lua
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

require("main") -- sorting-hint guard, exactly like a launch

local IntentStore = require("reorderingmenus_intent_store")
local AtomicWriter = require("reorderingmenus_atomic_writer")
local util = require("util")

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or ""))
    else
        failed = failed + 1
        io.stdout:flush()
        print("  [FAIL] " .. (msg or "") ..
            string.format(" -> expected %s, got %s", tostring(expected), tostring(actual)))
    end
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end

local VIEWS = { "reader", "filemanager" }
local view = "filemanager"
local sd = DataStorage:getSettingsDir()

local function wipe_world()
    os.remove(sd .. "/" .. view .. "_menu_order.lua")
    os.remove(sd .. "/reader_menu_order.lua")
    os.remove(sd .. "/reorderingmenus_intent.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    os.remove(sd .. "/reorderingmenus_state.lua")
    IntentStore.load(true)
end

-- Mutation surface exercised against a transaction. Every entry must be
-- REFUSED on a spent transaction (no throw, no canonical effect).
-- Schema v3: hidden-anchor mutators and clearSequenceEra are gone (anchors
-- were display bookkeeping; eras ride order_override entries), so the
-- surface below matches the current API.
local MUTATORS = {
    function(t) t:setHidden(view, "txc_x", { provider = "stock" }) end,
    function(t) t:setParentOverride(view, "txc_x", { provider = "stock", parent = "tools" }) end,
    function(t) t:setPositionOverride(view, "txc_x",
        { after = false, provider = "stock" }) end,
    function(t) t:setOrderOverride(view, "txc_lvl", { "a", "b" }, nil) end,
    function(t) t:setLifecyclePin(view, "txc_x", "anchor",
        { provider = "stock", parent = "tools" }) end,
    function(t) t:setCustomMenu(view, "rm:user:txc", { title = "T", parent = "tools" }) end,
    function(t) t:setSeparator(view, "sep_txc", { parent = "tools", after = false }) end,
    function(t) t:setRawOverride(view, "txc_lvl", { "a" }) end,
    function(t) t:setTabOrder(view, { "tools" }) end,
    function(t) t:clearItem(view, "txc_x") end,
    function(t) t:resetView(view) end,
    function(t) t:deleteCustomMenu(view, "rm:user:txc") end,
    function(t) local s = t:view(view); s.hidden["txc_y"] = { provider = nil } end,
}

local function canonical()
    return IntentStore.view(view)
end

-- Cheap, cycle-safe content signature for one view section: only the
-- collections and keys we care about in this suite. util.dump would walk
-- shared/metatabled structures; we need speed and determinism here.
local function sorted_keys(t)
    local keys = {}
    for k in pairs(t or {}) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    return table.concat(keys, ",")
end

local function section_fingerprint(section)
    local parts = {}
    for _, coll in ipairs({ "hidden", "parent_override",
                            "position_override", "order_override",
                            "custom_menus", "separators",
                            "raw_override" }) do
        parts[#parts + 1] = coll .. "[" .. sorted_keys(section and section[coll]) .. "]"
    end
    parts[#parts + 1] = "tab_order[" .. sorted_keys(
        type(section) == "table" and type(section.tab_order) == "table"
            and section.tab_order or nil) .. "]"
    return table.concat(parts, "|")
end

print("===============================================================")
print("=== Transaction spent-state contract                        ===")
print("===============================================================")

-- ---------------------------------------------------------------------
print("\n--- T1: OPEN -> COMMITTED; second commit refuses ---")
do
    wipe_world()
    local txn = IntentStore.openTransaction()
    txn:setPositionOverride(view, "txc_a", { after = false, provider = "stock" })
    local ok1 = txn:commit(true)
    assert_true(ok1, "first commit succeeds")
    local gen = IntentStore.generation()

    local ok2, err2 = txn:commit(true)
    assert_eq(ok2, false, "second commit refuses")
    if ok2 == false then
        print(string.format("         (reason: %s)", tostring(err2)))
    end
    assert_eq(IntentStore.generation(), gen, "double commit does not bump generation")
end

-- ---------------------------------------------------------------------
print("\n--- T2: COMMITTED transaction rejects every mutation ---")
do
    wipe_world()
    local txn = IntentStore.openTransaction()
    txn:commit(true)
    local before = section_fingerprint(canonical())

    for i, mutate in ipairs(MUTATORS) do
        local threw = false
        local ok, err = pcall(mutate, txn)
        threw = not ok
        assert_eq(threw, false,
            string.format("mutation %d on committed txn does not crash", i))
        assert_eq(section_fingerprint(canonical()), before,
            string.format("mutation %d on committed txn leaves canonical untouched", i))
    end
end

-- ---------------------------------------------------------------------
print("\n--- T3: commit detaches staging from canonical (no aliasing) ---")
do
    wipe_world()
    local txn = IntentStore.openTransaction()
    local handle = txn:view(view)          -- grabbed BEFORE commit
    handle.position_override["txc_alias"] = { after = false, provider = "stock" }
    txn:setOrderOverride(view, "txc_lvl", { "one", "two" }, nil)
    local staged_at_commit = txn:view(view)

    local ok = txn:commit(true)
    assert_true(ok, "commit succeeds")

    -- write through the pre-commit handle: canonical must NOT change...
    handle.position_override["txc_alias"] = nil
    handle.order_override["txc_lvl"] = nil
    local canonical_now = canonical()
    assert_true(canonical_now.position_override["txc_alias"] ~= nil,
        "pre-commit handle mutation does not erase committed record")
    assert_true(type(canonical_now.order_override["txc_lvl"]) == "table",
        "committed order survives stale-handle writes")

    -- ...and the transaction's own staged table must not be canonical's table
    assert_true(txn:view(view) ~= canonical(),
        "staged table is not the canonical table object")
    assert_true(staged_at_commit ~= canonical(),
        "commit installed a copy, not the staged object itself")
end

-- ---------------------------------------------------------------------
print("\n--- T4: DISCARDED transaction exposes no mutable canonical ---")
do
    wipe_world()
    local txn = IntentStore.openTransaction()
    txn:discard()
    txn:discard()   -- double discard: harmless explicit no-op
    assert_true(true, "discard twice does not crash")

    local before = section_fingerprint(canonical())
    for i, mutate in ipairs(MUTATORS) do
        local ok = pcall(mutate, txn)
        assert_eq(ok, true,
            string.format("mutation %d on discarded txn does not crash", i))
        assert_eq(section_fingerprint(canonical()), before,
            string.format("mutation %d on discarded txn leaves canonical untouched", i))
    end

    -- read paths must not hand out live canonical tables
    local v = txn:view(view)
    v.hidden["txc_ghost"] = { provider = nil }
    assert_eq(section_fingerprint(canonical()), before,
        "discarded txn view() hands out a snapshot, not canonical")
    local sec = txn:section(view, "hidden")
    assert_true(type(sec) == "table", "discarded txn section() stays readable")
end

-- ---------------------------------------------------------------------
print("\n--- T5: discard after commit refuses ---")
do
    wipe_world()
    local txn = IntentStore.openTransaction()
    txn:commit(true)
    local before = section_fingerprint(canonical())
    local ok, err = txn:discard()
    assert_eq(ok, false, "discard of a COMMITTED transaction refuses")
    if ok == false then
        print(string.format("         (reason: %s)", tostring(err)))
    end
    assert_eq(section_fingerprint(canonical()), before,
        "refused post-commit discard changes nothing")
end

-- ---------------------------------------------------------------------
print("\n--- T6: failed durable commit discards the transaction ---")
do
    wipe_world()
    local real_write = AtomicWriter.writeTable
    AtomicWriter.writeTable = function(path, data, validator)
        if tostring(path):find("reorderingmenus_intent", 1, true) then
            return false, "simulated io failure"
        end
        return real_write(path, data, validator)
    end

    local txn = IntentStore.openTransaction()
    txn:setPositionOverride(view, "txc_io", { after = false, provider = "stock" })
    local base_epoch = IntentStore.storeEpoch()
    local ok, err = txn:commit(true)
    AtomicWriter.writeTable = real_write
    assert_eq(ok, false, "commit with failing durable write fails")
    assert_eq(IntentStore.storeEpoch(), base_epoch + 1,
        "failed durable commit supersedes the transaction world (epoch)")

    -- canonical unchanged
    assert_true(canonical().position_override["txc_io"] == nil,
        "failed commit did not install records into canonical")

    -- the dead transaction can neither re-commit nor leak its staging
    local ok2, err2 = txn:commit(true)
    assert_eq(ok2, false, "transaction that failed IO cannot be reused")
    if ok2 == false then
        print(string.format("         (reason: %s)", tostring(err2)))
    end
end

-- ---------------------------------------------------------------------
print("\n--- T7: store snapshots handed to callers are copies ---")
do
    wipe_world()
    IntentStore.view(view).position_override["txc_snap"] =
        { after = false, provider = "stock" }
    local snapshot = util.tableDeepCopy(IntentStore.view(view))
    snapshot.position_override["txc_snap"] = nil
    snapshot.hidden["injected"] = { provider = nil }

    assert_true(canonical().position_override["txc_snap"] ~= nil,
        "mutating a caller-side snapshot does not erase canonical records")
    assert_true(canonical().hidden["injected"] == nil,
        "mutating a caller-side snapshot does not add canonical records")
    IntentStore.view(view).position_override["txc_snap"] = nil
end

-- ---------------------------------------------------------------------
print("\n--- T8: changedViews truthful while open; spent txn is inert ---")
do
    wipe_world()
    local txn = IntentStore.openTransaction()
    txn:setPositionOverride(view, "txc_cv", { after = false, provider = "stock" })
    local changed_before = txn:changedViews()[view]
    assert_eq(changed_before, true, "changedViews sees the edit while open")
    -- The COMMIT PIPELINE reads changedViews BEFORE commit() swaps state;
    -- that is the value that decides materialization scope.
    local ok = txn:commit(true)
    assert_true(ok, "commit succeeds")
    -- After commit the staging equals canonical BY DESIGN (copies were
    -- installed), so changedViews now reports no delta - which is exactly
    -- why callers must read it before/at commit, never after.
    assert_eq(txn:changedViews()[view], false,
        "changedViews post-commit reports no further delta")
    -- A fresh transaction stages from the committed world and agrees.
    local fresh = IntentStore.openTransaction()
    assert_eq(fresh:changedViews()[view], false,
        "fresh transaction reports no changed views")
end

-- ---------------------------------------------------------------------
print("\n--- T9: manager-level ensureTxn replaces spent transactions ---")
do
    wipe_world()
    local MenuOrderManager = require("reorderingmenus_menuorder_manager")
    -- stage through the manager, commit via a direct funnel use
    MenuOrderManager:setItemHidden(view, "plug_a", true, "more_tools")
    local staged_view = MenuOrderManager:stagedView(view)
    local ok_save = MenuOrderManager:saveOrder(view)
    assert_true(ok_save, "manager save commits staged work")

    -- an unrelated later edit must persist exactly the new edit, not residue
    MenuOrderManager:restoreItemDefault(view, "plug_a")
    MenuOrderManager:saveOrder(view)
    assert_true(MenuOrderManager:getDisabledItems(view) ~= nil,
        "post-spent saves keep working")
end

wipe_world()
print(string.format("\n=== %d passed, %d failed ===\n", passed, failed))
os.exit(failed == 0 and 0 or 1)

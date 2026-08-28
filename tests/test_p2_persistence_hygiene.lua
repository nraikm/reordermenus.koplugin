--[[--
test_p2_persistence_hygiene.lua — P2 verification suite:
- Backup retention cap (max 5 per type, oldest pruned deterministically)
- Load-boundary legacy sidecar migration (reorderingmenus_state.lua -> intent v3)
- Dead API removal verification
- NativeWriter.STATUS constants table
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

local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local IntentStore = require("reorderingmenus_intent_store")
local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local NativeWriter = require("reorderingmenus_native_writer")
local AtomicWriter = require("reorderingmenus_atomic_writer")
local DataLoader = require("reorderingmenus_data_loader")

local passed = 0
local failed = 0

local function assert_true(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("  FAIL: " .. tostring(msg))
    end
end

local function assert_eq(a, b, msg)
    if a == b then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("  FAIL: %s (expected %s, got %s)",
            tostring(msg), tostring(b), tostring(a)))
    end
end

local function assert_nil(a, msg)
    if a == nil then
        passed = passed + 1
    else
        failed = failed + 1
        print("  FAIL: " .. tostring(msg) .. " (expected nil, got " .. tostring(a) .. ")")
    end
end

local settings_dir = DataStorage:getSettingsDir()

local function cleanup_all()
    pcall(os.remove, settings_dir .. "/reorderingmenus_intent.lua")
    pcall(os.remove, settings_dir .. "/reorderingmenus_state.lua")
    pcall(os.remove, settings_dir .. "/reorderingmenus_materialization.lua")
    for file in lfs.dir(settings_dir) do
        if file:match("^reorderingmenus_intent%.lua%.") then
            pcall(os.remove, settings_dir .. "/" .. file)
        end
    end
    IntentStore.clearProtectedState()
    IntentStore._resetPreservationForTests()
end

-- =========================================================================
print("\n--- 1. Dead API Removal Verification ---")
-- =========================================================================
do
    assert_nil(IntentStore.replaceState, "IntentStore.replaceState is removed")
    assert_nil(IntentStore.resetView, "IntentStore.resetView is removed")
    assert_nil(IntentStore.recordApplies, "IntentStore.recordApplies is removed")
    assert_nil(IntentStore.stamp, "IntentStore.stamp is removed")
    assert_nil(IntentStore.INTENT_VERSION, "IntentStore.INTENT_VERSION alias is removed")

    local txn = IntentStore.openTransaction()
    assert_nil(txn.meta, "Transaction:meta is removed")
    txn:discard()

    assert_nil(MenuOrderManager.reconcileDefaultEntries, "MenuOrderManager.reconcileDefaultEntries is removed")
    assert_nil(MenuOrderManager.sanitizeOrder, "MenuOrderManager.sanitizeOrder is removed")
    assert_nil(MenuOrderManager.getHiddenAnchor, "MenuOrderManager.getHiddenAnchor is removed")
    assert_nil(MenuOrderManager.hasBackup, "MenuOrderManager.hasBackup is removed")
    assert_eq(MenuOrderManager:reconcileMenuItems("reader", "tools", {}), false,
        "reconcileMenuItems retained as deprecated safety stub returning false")
end

-- =========================================================================
print("\n--- 2. NativeWriter.STATUS Constants Table ---")
-- =========================================================================
do
    local S = NativeWriter.STATUS
    assert_true(type(S) == "table", "NativeWriter.STATUS table exists")
    assert_eq(S.UNCHANGED, "unchanged", "STATUS.UNCHANGED")
    assert_eq(S.LEGACY, "legacy", "STATUS.LEGACY")
    assert_eq(S.MALFORMED, "malformed", "STATUS.MALFORMED")
    assert_eq(S.CURRENT, "current", "STATUS.CURRENT")
    assert_eq(S.STALE, "stale", "STATUS.STALE")
    assert_eq(S.EXTERNAL, "external", "STATUS.EXTERNAL")
    assert_eq(S.PROTECTED_READONLY, "protected_readonly", "STATUS.PROTECTED_READONLY")
    assert_eq(S.REGENERATED, "regenerated", "STATUS.REGENERATED")
    assert_eq(S.REGENERATED_INTERRUPTED, "regenerated_interrupted", "STATUS.REGENERATED_INTERRUPTED")
    assert_eq(S.REGENERATED_MALFORMED, "regenerated_malformed", "STATUS.REGENERATED_MALFORMED")
    assert_eq(S.REGENERATED_LAGGING, "regenerated_lagging", "STATUS.REGENERATED_LAGGING")
    assert_eq(S.REGENERATED_STALE, "regenerated_stale", "STATUS.REGENERATED_STALE")
    assert_eq(S.REGENERATED_WRITER_UPGRADE, "regenerated_writer_upgrade", "STATUS.REGENERATED_WRITER_UPGRADE")
    assert_eq(S.CONVERGED_SPARSE, "converged_sparse", "STATUS.CONVERGED_SPARSE")
    assert_eq(S.IMPORTED_LEGACY, "imported_legacy", "STATUS.IMPORTED_LEGACY")
    assert_eq(S.IMPORTED_EXTERNAL, "imported_external", "STATUS.IMPORTED_EXTERNAL")
    assert_eq(S.REVERTED, "reverted", "STATUS.REVERTED")
    assert_eq(S.CLEAN, "clean", "STATUS.CLEAN")
    assert_eq(S.CLEAN_EMPTY, "clean_empty", "STATUS.CLEAN_EMPTY")
    assert_eq(S.REGENERATION_FAILED, "regeneration_failed", "STATUS.REGENERATION_FAILED")
end

-- =========================================================================
print("\n--- 3. Backup Retention Limit (Max 5 Per Type) ---")
-- =========================================================================
do
    cleanup_all()

    -- Generate 8 corrupt backups sequentially by loading corrupt files
    for i = 1, 8 do
        local f = io.open(settings_dir .. "/reorderingmenus_intent.lua", "wb")
        f:write(string.format("return { version = 'corrupt_%d' -- syntax error {{{", i))
        f:close()
        IntentStore.load(true)
    end

    local corrupt_backups = {}
    for file in lfs.dir(settings_dir) do
        if file:match("^reorderingmenus_intent%.lua%.corrupt%-%d+%-%d+$") then
            table.insert(corrupt_backups, file)
        end
    end

    assert_eq(#corrupt_backups, 5, "prunes corrupt backups down to max 5")

    -- Clean canonical intent is written and intact
    assert_true(IntentStore.hasPersistedState(), "clean canonical intent written after recovery")
end

-- =========================================================================
print("\n--- 4. Load-Boundary Legacy Sidecar Migration ---")
-- =========================================================================
do
    cleanup_all()

    -- Write legacy reorderingmenus_state.lua without intent file
    local legacy_state = {
        hidden_origins = {
            reader = {
                search = "main",
                history = "tools",
            },
            filemanager = {
                file_search = "main",
            },
        },
        mirror_changes = true,
        hidden_in_place = false,
    }
    AtomicWriter.writeTable(settings_dir .. "/reorderingmenus_state.lua", legacy_state)

    -- Ensure intent file is absent
    assert_true(not IntentStore.hasPersistedState(), "intent file absent before load")

    -- Load through canonical load boundary
    local state, problems = IntentStore.load(true)
    assert_true(type(state) == "table", "load returned table")
    assert_eq(state.version, 3, "migrated directly to schema version 3")
    assert_true(type(state.views.reader.hidden.search) == "table", "search hidden record created")
    assert_eq(state.views.reader.hidden.search.origin, "main", "search origin preserved")
    assert_true(type(state.views.reader.hidden.history) == "table", "history hidden record created")
    assert_eq(state.views.reader.hidden.history.origin, "tools", "history origin preserved")
    assert_true(type(state.views.filemanager.hidden.file_search) == "table", "file_search hidden record created")
    assert_eq(state.views.filemanager.hidden.file_search.origin, "main", "file_search origin preserved")
    assert_eq(state.meta.mirror_changes, true, "mirror_changes preserved in meta")
    assert_eq(state.meta.hidden_in_place, false, "hidden_in_place preserved in meta")

    -- Check that canonical intent file now exists on disk with schema 3
    assert_true(IntentStore.hasPersistedState(), "intent file persisted after legacy migration")
    local on_disk = DataLoader.loadTable(settings_dir .. "/reorderingmenus_intent.lua")
    assert_eq(on_disk.version, 3, "on disk version is 3")
end

cleanup_all()

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)

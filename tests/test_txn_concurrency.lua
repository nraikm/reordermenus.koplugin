--[[--
Transaction concurrency & staleness (single KOReader instance).

  T1  two txns staged from the same generation; sequential commits both land
      (second rebases via mergeSection - no silent lost update).
  T2  same-item conflicting moves: last explicit save wins for that record,
      the other writer's unrelated records survive.
  T3  hide vs move on different items: both survive.
  T4  commit twice -> second refuses (non-reuse after commit).
  T5  discard twice / commit after discard -> refused.
  T6  stale txn commit returns false,"stale_transaction"; canonical intact.
  T7  external file edit while txn open: syncView imports into canonical;
      open txn commits on top without losing the import.
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
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
require("main")

local MenuOrderManager = require("lib.menuorder_manager")
local UIScreens = require("lib.ui_screens")
local IntentStore = require("lib.intent_store")
local NativeWriter = require("lib.native_writer")
local util = require("util")

local view = "filemanager"
local sd = DataStorage:getSettingsDir()
local ORDER_FILE = sd .. "/" .. view .. "_menu_order.lua"

local passed, failed = 0, 0
local function assert_eq(a, e, msg)
    if a == e then passed = passed + 1
    else failed = failed + 1
        print("  [FAIL] " .. msg ..
            string.format(" -> expected %s, got %s", tostring(e), tostring(a)))
        io.stdout:flush()
    end
end
local function assert_true(c, msg) assert_eq(not not c, true, msg) end

local function wipe()
    os.remove(ORDER_FILE)
    os.remove(sd .. "/reorderingmenus_intent.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    IntentStore.load(true); NativeWriter._resetCaches()
    MenuOrderManager:dropSessionState(view)
end
local function launch()
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, view, false)
end

print("===============================================================")
print("=== Transaction concurrency                                 ===")
print("===============================================================")

print("\n--- T1: sequential commits from one base generation ---")
do
    wipe(); launch()
    local gen0 = IntentStore.generation()
    local A = IntentStore.openTransaction()
    local B = IntentStore.openTransaction()
    assert_eq(A.base_generation, gen0, "T1: A stages at gen0")
    assert_eq(B.base_generation, gen0, "T1: B stages at gen0")
    A:setParentOverride(view, "opds", { provider = nil, parent = "tools", anchor = false })
    assert_true(A:commit(), "T1: A commits first")
    -- B staged before A's commit: plain commit would be stale...
    local ok, err = B:commit(true)
    -- mergeSection-based rebase is the manager's job; raw commit must refuse
    assert_eq(ok, false, "T1: B raw commit refuses")
    assert_eq(err, "stale_transaction", "T1: refusal reason")
    -- rebase: pull A's records into B's staging, then commit
    B.staged[view] = B:mergeSection(view)
    B.base_generation = IntentStore.generation()
    B.committed = false
    assert_true(B:commit(), "T1: B commits after rebase")
    local sec = IntentStore.view(view)
    assert_true(sec.parent_override.opds ~= nil,
        "T1: A's move survives B's commit (no lost update)")
end

print("\n--- T2: same-item conflict ---")
do
    wipe(); launch()
    local A = IntentStore.openTransaction()
    A:setParentOverride(view, "opds", { provider = nil, parent = "tools", anchor = false })
    assert_true(A:commit(), "T2: A moves opds")
    local B = IntentStore.openTransaction()
    B.staged[view] = B:mergeSection(view)
    B:view(view).parent_override.opds =
        { provider = nil, parent = "setting", anchor = false }
    B.base_generation = IntentStore.generation()
    assert_true(B:commit(), "T2: B's newer move wins")
    assert_eq(IntentStore.view(view).parent_override.opds.parent, "setting",
        "T2: last explicit save wins")
end

print("\n--- T3: hide vs move on different items ---")
do
    wipe(); launch()
    local A = IntentStore.openTransaction()
    A:setHidden(view, "keep_alive", { provider = nil, origin = "more_tools" })
    assert_true(A:commit(), "T3: A hides keep_alive")
    local B = IntentStore.openTransaction()
    B.staged[view] = B:mergeSection(view)
    B:setParentOverride(view, "opds",
        { provider = nil, parent = "tools", anchor = false })
    B.base_generation = IntentStore.generation()
    assert_true(B:commit(), "T3: B commits its move")
    local sec = IntentStore.view(view)
    assert_true(sec.hidden.keep_alive ~= nil, "T3: hide survives")
    assert_true(sec.parent_override.opds ~= nil, "T3: move survives")
end

print("\n--- T4/T5: non-reuse after commit / discard ---")
do
    wipe(); launch()
    local A = IntentStore.openTransaction()
    A:setParentOverride(view, "opds", { provider = nil, parent = "tools", anchor = false })
    assert_true(A:commit(), "T4: first commit ok")
    local ok2 = A:commit()
    assert_eq(ok2, false, "T4: second commit refused")
    local B = IntentStore.openTransaction()
    B:discard()
    assert_eq(B:commit(), false, "T5: commit after discard refused")
    assert_eq(select(2, B:discard()), nil, "T5: double discard tolerated")
end

print("\n--- T6: stale commit leaves canonical intact ---")
do
    wipe(); launch()
    MenuOrderManager:moveItemToMenu(view, "opds", "search", "tools")
    MenuOrderManager:saveOrder(view)
    local before = util.tableDeepCopy(IntentStore.view(view).parent_override)
    local Stale = IntentStore.openTransaction()
    Stale:setParentOverride(view, "opds",
        { provider = nil, parent = "setting", anchor = false })
    -- concurrent advance
    MenuOrderManager:setItemHidden(view, "keep_alive", true, "more_tools")
    MenuOrderManager:saveOrder(view)
    local ok, err = Stale:commit(true)
    assert_eq(ok, false, "T6: stale commit refused")
    assert_eq(err, "stale_transaction", "T6: reason")
    assert_true(util.tableEquals(IntentStore.view(view).parent_override, before),
        "T6: canonical unchanged by refused commit")
    assert_true(IntentStore.view(view).hidden.keep_alive ~= nil,
        "T6: concurrent hide still present")
end

print("\n--- T7: external edit while txn open ---")
do
    wipe(); launch()
    -- Create a REAL prior emission: under the P0 commit funnel an unchanged
    -- save writes neither a derived file nor a sidecar checkpoint, so the
    -- three-way comparison below needs at least one durable customization.
    MenuOrderManager:setItemHidden(view, "keep_alive", true, "more_tools")
    MenuOrderManager:saveOrder(view)
    local Txn = IntentStore.openTransaction()
    Txn:setParentOverride(view, "opds", { provider = nil, parent = "setting", anchor = false })
    -- external hand edit of the native file while the txn holds staging
    local order_now = MenuOrderManager:loadOrder(view)
    local lst = order_now.help or {}
    for i = 1, #lst - 1 do
        if lst[i] ~= "----------------------------"
                and lst[i + 1] ~= "----------------------------" then
            lst[i], lst[i + 1] = lst[i + 1], lst[i]
            break
        end
    end
    local dump = require("dump")
    local fh = io.open(ORDER_FILE, "w")
    fh:write("return " .. dump(order_now, nil, true)); fh:close()
    NativeWriter._resetCaches(); MenuOrderManager:dropSessionState(view)
    IntentStore.load(true); launch()   -- imports the external help swap

    Txn.staged[view] = Txn:mergeSection(view)
    -- Rebase contract: adopting the post-import canonical world means
    -- restamping BOTH concurrency fields - base_generation (counter) and
    -- store_epoch (the wholesale-reload epoch bumped by load(true) above).
    -- A transaction that kept its pre-reload epoch would be refused by
    -- commit() even after a record-level merge, because it staged from the
    -- superseded in-memory world.
    Txn.base_generation = IntentStore.generation()
    Txn.store_epoch = IntentStore.storeEpoch()
    assert_true(Txn:commit(), "T7: rebased txn commits")
    local sec = IntentStore.view(view)
    assert_true(sec.parent_override.opds ~= nil
        and sec.parent_override.opds.parent == "setting",
        "T7: txn move survives")
    -- The single help swap imports as a minimal position anchor (semantic
    -- diff: one relocated row), not a frozen bulk sequence.
    local imported_swap = false
    for id, rec in pairs(sec.position_override or {}) do
        if rec ~= nil then imported_swap = true end
    end
    assert_true(imported_swap, "T7: external help reorder imported as minimal intent")
end

wipe()
print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

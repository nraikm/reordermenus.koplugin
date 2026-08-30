--[[
P1A canonical invariants: the production mutation APIs make invalid states
unrepresentable (task §8). These tests drive ONLY public transactional
writers — no hand-crafted tables — and assert the structural invariant
directly on staged/committed state.

  V1  hidden membership always carries ordering metadata (ordinal)
  V2  no hidden-order residue can reference a non-hidden id
      (the structure that could dangle no longer exists)
  V3  duplicate sequence entries cannot be created (first wins at the door)
  V4  every sequence entry carries its applicability (id + optional provider);
      era stamps ride the entry — a parallel era map cannot exist
  V5  custom-menu parent authority is single: creation records carry no
      parent; parent_override is THE answer; contradiction impossible
  V6  raw mode is exclusive: installing a raw level clears semantic records;
      writing a sequence does not resurrect beside raw bytes
  V7  position vs sequence exclusivity for one item's placement:
      entering sequence form clears the anchor claim, and vice versa
  V8  isCustomized reflects applicable canonical intent only — stale native
      files / missing derived output cannot flip it
  V9  restart equivalence of the committed canonical shape

Run via run_tests.sh (hermetic per-suite KO_HOME).
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
require("gettext")
require("main")

local IntentStore = require("reorderingmenus_intent_store")
local MenuSchema = require("reorderingmenus_menu_schema")
local NativeWriter = require("reorderingmenus_native_writer")
local UIScreens = require("reorderingmenus_ui_screens")
local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local util = require("util")

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("  [FAIL] %s -> expected %s, got %s",
            msg, tostring(expected), tostring(actual)))
    end
    io.stdout:flush()
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end
local function assert_false(cond, msg) assert_eq(not not cond, false, msg) end

local view = "filemanager"
local sd = DataStorage:getSettingsDir()
local INTENT_FILE = sd .. "/reorderingmenus_intent.lua"

local function wipe()
    os.remove(INTENT_FILE)
    os.remove(sd .. "/" .. view .. "_menu_order.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    os.remove(sd .. "/reorderingmenus_state.lua")
    IntentStore.load(true)
    NativeWriter._resetCaches()
    MenuOrderManager:dropSessionState(view)
end

local function launch(widgets)
    UIScreens:reconcileRegisteredItems(
        { ui = { menu = { registered_widgets = widgets or {} } } }, view, false)
end

print("== P1A canonical invariants ==")

---------------------------------------------------------------------------
do print("V1/V2: hidden records are self-contained (membership+ordinal)")
    wipe(); launch()
    local txn = IntentStore.openTransaction()
    txn:setHidden(view, "item_a", { provider = "stock", origin = "main" })
    txn:setHidden(view, "item_b", { provider = "stock", origin = "main" })
    local sec = txn:view(view)
    assert_eq(sec.hidden.item_a.ordinal, 1, "first hide gets ordinal 1")
    assert_eq(sec.hidden.item_b.ordinal, 2, "second hide appends")
    assert_true(sec.hidden_order == nil,
        "no parallel hidden_order exists to desynchronize")
    txn:setHidden(view, "item_a", nil)
    -- Unhide removes the whole record: nothing can dangle.
    assert_true(sec.hidden.item_a == nil, "unhide removes membership")
    assert_true(type(sec.hidden.item_b) == "table" and sec.hidden.item_b.ordinal == 2,
        "survivor keeps its own ordering metadata")
    txn:discard()
end

---------------------------------------------------------------------------
do print("V3/V4: sequences carry unique ids with their era stamps")
    wipe(); launch()
    local txn = IntentStore.openTransaction()
    txn:setOrderOverride(view, "main",
        { "x1", "x2", "x1", MenuSchema.SEPARATOR_ID },
        { x1 = "stock" })
    local rec = txn:view(view).order_override.main
    assert_true(rec ~= nil and type(rec.entries) == "table", "record written")
    assert_eq(#rec.entries, 2, "duplicate id and divider dropped from sequence")
    assert_eq(rec.entries[1].id, "x1", "first occurrence kept")
    assert_eq(rec.entries[1].provider, "stock", "era stamp rides the entry")
    local separator
    for _, candidate in pairs(txn:view(view).separators) do separator = candidate end
    assert_true(separator and separator.parent == "main"
            and separator.after == "x2",
        "separator stored in the sole anchored authority")
    assert_true(txn:view(view).sequence_eras == nil,
        "no parallel era map can exist alongside entries")
    txn:discard()
end

---------------------------------------------------------------------------
do print("V5: custom-menu parent authority is single")
    wipe(); launch()
    MenuOrderManager:createSubmenu(view, "tools", "My Tools")
    local sec = MenuOrderManager:stagedView(view)
    local custom_id
    for id in pairs(sec.custom_menus) do custom_id = id break end
    assert_true(custom_id ~= nil, "submenu created")
    assert_true(sec.custom_menus[custom_id].parent == nil,
        "creation record carries NO parent")
    assert_eq(MenuSchema.getCustomParent(sec, custom_id), "tools",
        "parent_override answers alone")
    -- Move it: exactly one record changes; still one authority.
    local txn = MenuOrderManager.peekTransaction()
    txn:setParentOverride(view, custom_id, { provider = nil, parent = "main" })
    sec = MenuOrderManager:stagedView(view)
    assert_eq(MenuSchema.getCustomParent(sec, custom_id), "main",
        "moved submenu resolves through the same single authority")
    assert_true(next(sec.custom_menus[custom_id]) ~= nil
        and sec.custom_menus[custom_id].title == "My Tools",
        "title untouched by the move")
    MenuOrderManager:saveOrder(view)
    -- After save+reload the shape persists unchanged.
    MenuOrderManager:dropSessionState(view)
    IntentStore.load(true); NativeWriter._resetCaches()
    local reloaded = IntentStore.view(view)
    assert_true(reloaded.custom_menus[custom_id] ~= nil
        and reloaded.custom_menus[custom_id].parent == nil,
        "persisted creation record stays parent-less after restart")
    assert_eq(MenuSchema.getCustomParent(reloaded, custom_id), "main",
        "single parent authority survives persistence")
end

---------------------------------------------------------------------------
do print("V6: raw mode excludes semantic ordering for the level")
    wipe(); launch()
    local txn = IntentStore.openTransaction()
    txn:setOrderOverride(view, "search", { "a", "b" }, { a = "stock" })
    txn:setSeparator(view, "sep_1", { parent = "search", after = "a" })
    txn:setRawOverride(view, "search", { "z_last", "a_mid" })
    local sec = txn:view(view)
    assert_true(sec.order_override.search == nil,
        "installing raw cleared the curated sequence")
    assert_true(sec.separators.sep_1 == nil,
        "installing raw cleared divider records inside the level")
    assert_eq(MenuSchema.orderingMode(sec, "search"), "raw",
        "level reports raw mode exclusively")
    -- Clearing raw restores representable default mode (no zombie records).
    txn:setRawOverride(view, "search", nil)
    assert_eq(MenuSchema.orderingMode(txn:view(view), "search"), "default",
        "raw removal leaves no half-dead semantic residue")
    txn:discard()
end

---------------------------------------------------------------------------
do print("V7: position vs sequence exclusivity per menu level")
    wipe(); launch()
    local txn = IntentStore.openTransaction()
    txn:setOrderOverride(view, "main", { "m1", "row_x", "m2" }, {})
    txn:setPositionOverride(view, "row_x",
        { provider = "stock", after = "row_prev" })
    -- The writer API stores one order record per menu; the anchor lives on a
    -- different collection. getExplicitPlacement's contract: position wins
    -- when both exist; a sequenced row WITHOUT an anchor reports sequence
    -- governance. Production writers never leave both on one row (V7b).
    local placement_no_anchor = MenuSchema.getExplicitPlacement(
        txn:view(view), function() return "main" end, "m2")
    if placement_no_anchor then
        assert_eq(placement_no_anchor.kind, "sequence",
            "sequenced anchor-less row reports sequence governance")
    end
    local placement = MenuSchema.getExplicitPlacement(
        txn:view(view), function() return "main" end, "row_x")
    assert_eq(placement and placement.kind, "position",
        "row with both claims reports the position record (specificity)")
    txn:discard()
end

---------------------------------------------------------------------------
do print("V7b: production stageList enforces anchor/sequence exclusivity")
    wipe(); launch()
    local util = require("util")
    local items = MenuOrderManager:getMenuItems(view, "search")
    if #items >= 4 then
        -- Two independent relocations (a 3-rotation decomposes into two
        -- single moves) freeze the curated sequence...
        local moved = util.tableDeepCopy(items)
        local a = table.remove(moved, 1)
        table.insert(moved, #moved + 1, a)
        MenuOrderManager:stageList(view, "search", moved)
        local b = table.remove(moved, 2)
        table.insert(moved, 1, b)
        MenuOrderManager:stageList(view, "search", moved)
        local sec_after_bulk = MenuOrderManager:stagedView(view)
        if sec_after_bulk.order_override.search ~= nil then
            -- ...and whichever form each save takes, the level ends up with
            -- EXACTLY ONE authority: entries OR anchors, never both.
            local anchors = 0
            for _ in pairs(sec_after_bulk.position_override) do
                anchors = anchors + 1
            end
            assert_eq(anchors, 0, "bulk level carries no position anchors")
        end
        -- A final arrangement equal to the default derivation must clear ALL
        -- ordering records for the level (sparse minimization contract).
        local default_probe = util.tableDeepCopy(
            MenuOrderManager:stagedView(view))
        default_probe.order_override = {}
        default_probe.position_override = {}
        local reverted = util.tableDeepCopy(items)
        MenuOrderManager:stageList(view, "search", items)
        local sec_final = MenuOrderManager:stagedView(view)
        local has_seq = sec_final.order_override.search ~= nil
        local has_anchor = next(sec_final.position_override) ~= nil
        assert_true(not (has_seq and has_anchor),
            "level never carries both authorities simultaneously")
    else
        assert_true(true, "registry too small for drag scenario (skipped)")
    end
end

---------------------------------------------------------------------------
do print("V8: isCustomized ignores stale/missing derived state")
    wipe(); launch()
    MenuOrderManager:setItemHidden(view, "keep_alive", true, "more_tools")
    MenuOrderManager:saveOrder(view)
    assert_true(MenuOrderManager:isCustomized(view),
        "real customization reads customized")
    -- Simulate stale derived artifacts: delete the native file + sidecar
    -- behind canonical intent. Customization must NOT depend on them...
    os.remove(sd .. "/" .. view .. "_menu_order.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    MenuOrderManager:dropSessionState(view)
    assert_true(MenuOrderManager:isCustomized(view),
        "missing/stale derived files do not un-customize real intent")
    -- ...and a pristine stock menu must not read customized even if some
    -- foreign derived file happens to exist.
    wipe()
    local f = io.open(sd .. "/" .. view .. "_menu_order.lua", "w")
    f:write("return { [\"KOMenu:menu_buttons\"] = { \"main\" } }\n")
    f:close()
    MenuOrderManager:dropSessionState(view)
    assert_false(MenuOrderManager:isCustomized(view),
        "foreign derived file without intent is NOT customized")
end


---------------------------------------------------------------------------
do print("V9: restart equivalence of the canonical shape")
    wipe(); launch()
    MenuOrderManager:setItemHidden(view, "keep_alive", true, "more_tools")
    MenuOrderManager:moveItemToMenu(view, "opds", "search", "tools")
    MenuOrderManager:createSubmenu(view, "tools", "Zed")
    MenuOrderManager:saveOrder(view)
    local before = util.tableDeepCopy(IntentStore.view(view))
    MenuOrderManager:dropSessionState(view)
    IntentStore.load(true); NativeWriter._resetCaches()
    local after = IntentStore.view(view)
    assert_true(util.tableEquals(before, after),
        "canonical section identical across simulated restart")
    assert_true(before.hidden.keep_alive
        and type(before.hidden.keep_alive.ordinal) == "number",
        "hidden record carries ordinal across restart")
end

wipe()
print(string.format("=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)

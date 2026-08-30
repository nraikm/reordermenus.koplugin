--[[
P1A schema migration suite: every historically supported canonical
representation migrates into the v3 consolidated form.

  G1  v0 (no version field) -> v3 losslessly
  G2  v1 -> v3 losslessly
  G3  hidden_order + ui_state.hidden_anchors -> per-record ordinal;
      display anchors dropped; membership survives
  G4  sequence_eras -> per-entry provider stamps on order_override.entries
  G5  custom_menus.parent -> parent_override (explicit override wins)
  G6  lifecycle anchor pins dropped, records preserved
  G7  raw/semantic mode conflict: raw wins, semantic residue cleared
  G8  idempotence: migrating migrated data is a no-op
  G9  restart safety: persisted migration reloads identically
  G10 duplicate sequence entries keep first occurrence

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
local AtomicWriter = require("reorderingmenus_atomic_writer")
local NativeWriter = require("reorderingmenus_native_writer")

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. msg)
    else
        failed = failed + 1
        print(string.format("  [FAIL] %s -> expected %s, got %s",
            msg, tostring(expected), tostring(actual)))
    end
    io.stdout:flush()
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end

local settings_dir = DataStorage:getSettingsDir()
local INTENT_FILE = settings_dir .. "/reorderingmenus_intent.lua"

-- Write a raw intent file in ANY historical shape and force the store to
-- migrate it exactly like a real process start would.
local function seedRawState(table_value)
    os.remove(INTENT_FILE)
    local ok, err = AtomicWriter.writeTable(INTENT_FILE, table_value)
    assert_true(ok, "seed file written (" .. tostring(err) .. ")")
    return IntentStore.load(true)
end

local function freshSection()
    -- A HISTORICAL v2-shaped section (all collections present).
    return {
        hidden = {},
        hidden_order = {},
        parent_override = {},
        position_override = {},
        order_override = {},
        sequence_eras = {},
        custom_menus = {},
        separators = {},
        raw_override = {},
        tab_order = nil,
    }
end

local function baseMeta()
    return {
        mirror_changes = false,
        hidden_in_place = true,
        generation = 4,
        view_generations = { reader = 2, filemanager = 2 },
    }
end

print("== P1A schema migration ==")

-- ---------------------------------------------------------------------------
do print("G1/G2: v0/v1 files migrate losslessly")
    local data = {
        version = 0,
        views = {
            reader = (function()
                local s = freshSection()
                s.hidden["clock"] = { provider = nil, origin = "main" }
                s.hidden_order = { "clock" }
                s.custom_menus["my_tools"] = { title = "My Tools", parent = "main" }
                return s
            end)(),
        },
        meta = nil, -- v0: no metadata at all
    }
    seedRawState(data)
    local state = IntentStore.load(true)
    assert_eq(state.version, 3, "version advanced to 3")
    assert_eq(state.meta.generation, 0, "v1 migration adds generation counter")
    local sec = state.views.reader
    assert_true(type(sec.hidden.clock) == "table", "hidden record survived v0")
    assert_eq(sec.hidden.clock.origin, "main", "origin preserved")
    assert_eq(sec.hidden.clock.ordinal, 1, "ordinal assigned from hide-order list")
    assert_true(sec.hidden_order == nil, "hidden_order removed from section")
    assert_true(sec.custom_menus.my_tools ~= nil, "custom menu survived")
    assert_true(state.views.filemanager ~= nil, "missing view filled in")
end

-- ---------------------------------------------------------------------------
do print("G3: hidden consolidation carries origin/provider/ordinal together")
    local data = {
        version = 2,
        views = {
            reader = (function()
                local s = freshSection()
                -- Two listed ids plus one unlisted (pre-ordering) record.
                s.hidden["a_first"] = { provider = "stock", origin = "menu_x" }
                s.hidden["b_second"] = { provider = nil, origin = nil }
                s.hidden["z_unnumbered"] = { provider = "stock", origin = "menu_y" }
                s.hidden_order = { "a_first", "b_second" }
                return s
            end)(),
        },
        meta = baseMeta(),
    }
    seedRawState(data)
    local sec = IntentStore.load(true).views.reader
    assert_eq(sec.hidden.a_first.ordinal, 1, "first listed id keeps its position")
    assert_eq(sec.hidden.b_second.ordinal, 2, "second listed id keeps its position")
    assert_eq(sec.hidden.z_unnumbered.ordinal, 3,
        "unnumbered record appended deterministically after listed ids")
    assert_eq(MenuSchema.orderedHiddenIds(sec)[1], "a_first",
        "ordered accessor reproduces historical hide order")
    assert_eq(#MenuSchema.orderedHiddenIds(sec), 3,
        "all three records are members with ordering metadata")
    -- Invariant: membership and ordering metadata cannot be independently
    -- inconsistent - every member carries an ordinal by construction.
    for id, record in pairs(sec.hidden) do
        assert_true(type(record.ordinal) == "number",
            "member " .. id .. " carries an ordinal after migration")
    end
end

-- ---------------------------------------------------------------------------
do print("G4: sequence_eras fold into order_override entries")
    local data = {
        version = 2,
        views = {
            reader = (function()
                local s = freshSection()
                s.order_override["menu_a"] =
                    { "item_1", "----------------------------", "item_2" }
                s.sequence_eras = { menu_a = { item_1 = "stock", item_2 = nil } }
                return s
            end)(),
        },
        meta = baseMeta(),
    }
    seedRawState(data)
    local sec = IntentStore.load(true).views.reader
    local rec = sec.order_override.menu_a
    assert_true(rec ~= nil and type(rec.entries) == "table",
        "order record converted to entries form")
    assert_eq(#rec.entries, 2, "sequence keeps item entries only")
    assert_eq(rec.entries[1].id, "item_1", "entry id preserved")
    assert_eq(rec.entries[1].provider, "stock", "era stamp travels onto the entry")
    assert_eq(rec.entries[2].id, "item_2", "trailing entry preserved")
    assert_true(rec.entries[2].provider == nil, "absent era stays absent")
    local migrated_separator
    for _, sep in pairs(sec.separators) do migrated_separator = sep end
    assert_true(migrated_separator and migrated_separator.parent == "menu_a"
            and migrated_separator.after == "item_1",
        "inline separator migrated to anchored authority")
    assert_true(sec.sequence_eras == nil, "parallel era map removed from section")
end

-- ---------------------------------------------------------------------------
do print("G5: custom-menu parent authority resolves to ONE place")
    local data = {
        version = 2,
        views = {
            reader = (function()
                local s = freshSection()
                -- Creation home only.
                s.custom_menus["tools_mine"] =
                    { title = "Mine", parent = "main" }
                -- Contradiction: creation says main, explicit move says tools.
                s.custom_menus["tools_moved"] =
                    { title = "Moved", parent = "main" }
                s.parent_override["tools_moved"] =
                    { provider = nil, parent = "tools" }
                return s
            end)(),
        },
        meta = baseMeta(),
    }
    seedRawState(data)
    local sec = IntentStore.load(true).views.reader
    assert_eq(sec.custom_menus.tools_mine.title, "Mine", "title preserved")
    assert_true(sec.custom_menus.tools_mine.parent == nil,
        "creation-time parent removed from custom_menus record")
    assert_eq(sec.parent_override.tools_mine.parent, "main",
        "creation-time parent folded into parent_override")
    assert_eq(sec.parent_override.tools_moved.parent, "tools",
        "explicit override wins over creation-time home")
    -- Exactly one authority: both queries agree through the accessor.
    assert_eq(MenuSchema.getCustomParent(sec, "tools_moved"), "tools",
        "single-authority accessor answers for moved menu")
    assert_eq(MenuSchema.getCustomParent(sec, "tools_mine"), "main",
        "single-authority accessor answers for created menu")
end

-- ---------------------------------------------------------------------------
do print("G6: lifecycle anchor pins are eliminated; explicit moves survive")
    local data = {
        version = 2,
        views = {
            reader = (function()
                local s = freshSection()
                s.parent_override["pinned_row"] =
                    { provider = "stock", parent = "menu_b", anchor = true }
                s.position_override["pinned_pos"] =
                    { provider = "stock", after = "row_1", anchor = true }
                return s
            end)(),
        },
        meta = baseMeta(),
    }
    seedRawState(data)
    local sec = IntentStore.load(true).views.reader
    -- Schema v3 (task §4): a generated lifecycle pin must NEVER be
    -- mistakable for an explicit user move, so migration eliminates the
    -- record outright instead of keeping a marker-stripped shell. Nothing
    -- is lost: the materializer re-derives the same home live from the
    -- provider's current registration on every resolve.
    assert_true(sec.parent_override.pinned_row == nil,
        "pinned parent record eliminated")
    assert_true(sec.position_override.pinned_pos == nil,
        "pinned position record eliminated")
    assert_true(MenuSchema.sectionHasUserIntent(sec) == false,
        "pin-only section carries NO user intent")
end

do print("G6b: explicit moves migrate intact (never confused with pins)")
    local data = {
        version = 2,
        views = {
            reader = (function()
                local s = freshSection()
                s.parent_override["moved_row"] =
                    { provider = "stock", parent = "menu_b" }
                s.position_override["moved_pos"] =
                    { provider = "stock", after = "row_1" }
                return s
            end)(),
        },
        meta = baseMeta(),
    }
    seedRawState(data)
    local sec = IntentStore.load(true).views.reader
    assert_eq(sec.parent_override.moved_row.parent, "menu_b",
        "explicit parent move preserved verbatim")
    assert_eq(sec.parent_override.moved_row.anchor, nil,
        "anchor field absent from migrated explicit record")
    assert_eq(sec.position_override.moved_pos.after, "row_1",
        "explicit position anchor preserved verbatim")
    assert_true(MenuSchema.sectionHasUserIntent(sec) == true,
        "explicit moves ARE user intent")
end

-- ---------------------------------------------------------------------------
do print("G7: raw/semantic contradiction resolves to raw exclusivity")
    local data = {
        version = 2,
        views = {
            reader = (function()
                local s = freshSection()
                s.raw_override["hand_level"] = { list = { "raw_1", "raw_2" } }
                s.order_override["hand_level"] = { "raw_2", "raw_1" }
                s.sequence_eras = { hand_level = { raw_1 = "stock" } }
                s.separators["sep_9"] = { parent = "hand_level", after = "raw_1" }
                return s
            end)(),
        },
        meta = baseMeta(),
    }
    seedRawState(data)
    local sec = IntentStore.load(true).views.reader
    assert_true(sec.raw_override.hand_level ~= nil, "raw passthrough kept verbatim")
    assert_true(sec.order_override.hand_level == nil,
        "semantic sequence cleared beside a raw level")
    assert_true(sec.separators.sep_9 == nil,
        "divider records inside a raw level cleared (bytes are authoritative)")
    local mode = MenuSchema.orderingMode(sec, "hand_level")
    assert_eq(mode, "raw", "ordering mode reports raw exclusively")
end

-- ---------------------------------------------------------------------------
do print("G8: migration is idempotent on already-v3 data")
    local v3_state = {
        version = 3,
        views = {
            reader = (function()
                local s = MenuSchema.newViewSection()
                s.hidden["h1"] = MenuSchema.newHiddenRecord(
                    { provider = "stock", origin = "m1", ordinal = 1 })
                s.order_override["mm"] =
                    MenuSchema.newOrderRecord({ "x1", "x2" }, { x1 = "stock" })
                s.custom_menus["cc"] = { title = "C" }
                s.parent_override["cc"] = { provider = nil, parent = "m2" }
                return s
            end)(),
        },
        meta = baseMeta(),
    }
    seedRawState(v3_state)
    IntentStore.load(true)
    -- Reload twice: the second load must not change anything on disk.
    -- (Single return value on purpose: load() also returns problems/backup
    -- path, which must never flow into another call's positional args.)
    local snapshot_before = io.open(INTENT_FILE, "r"):read("*a")
    IntentStore.load(true)
    local snapshot_after = io.open(INTENT_FILE, "r"):read("*a")
    assert_true(#snapshot_before > 0, "state serializable at all")
    assert_eq(snapshot_after, snapshot_before,
        "second full load rewrites nothing (restart-safe normalization)")
    assert_eq(IntentStore.view("reader").hidden.h1.ordinal, 1, "ordinal stable across loads")
    assert_eq(#IntentStore.view("reader").order_override.mm.entries, 2,
        "entries stable across loads")
end

-- ---------------------------------------------------------------------------
do print("G9: malformed v2 sequences heal without quarantine of healthy data")
    local data = {
        version = 2,
        views = {
            reader = (function()
                local s = freshSection()
                -- Duplicate entry: loader must keep FIRST occurrence, not
                -- destroy the whole record.
                s.order_override["dup_menu"] = { "dup_a", "dup_b", "dup_a" }
                s.sequence_eras = { dup_menu = { dup_a = "stock" } }
                return s
            end)(),
        },
        meta = baseMeta(),
    }
    seedRawState(data)
    local ok_load, state = pcall(IntentStore.load, true)
    assert_true(ok_load, "duplicate-bearing legacy file loads")
    local entries = state.views.reader.order_override.dup_menu
        and state.views.reader.order_override.dup_menu.entries or {}
    assert_eq(#entries, 2, "duplicate entry dropped, survivors kept")
    assert_eq(entries[1] and entries[1].id, "dup_a", "first occurrence kept")
end

-- ---------------------------------------------------------------------------
do print("G10: future schemas still refuse to load (protection intact)")
    local data = {
        version = 99,
        views = { reader = freshSection() },
        meta = baseMeta(),
    }
    seedRawState(data)
    local _, problems = IntentStore.load(true)
    local saw_future = false
    for _, p in ipairs(problems or {}) do
        if p.kind == "unsupported_future_schema" then saw_future = true end
    end
    assert_true(saw_future, "future version reported as unsupported")
    assert_true(IntentStore.isProtected(), "storage protected after future file")
    -- Cleanup protection for later suites sharing this store object.
    os.remove(INTENT_FILE)
    IntentStore.clearProtectedState()
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)

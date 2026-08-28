--[[--
test_historical_fixtures.lua — Area P (deepened): REAL historical configuration
fixtures loaded against CURRENT code, asserting the actual expected visible
layout — not merely "it did not crash" and not synthetic-schema-only coverage.

Fixture provenance (tests/fixtures/historical/):

  dense-era_filemanager_menu_order.lua
      REAL user file captured from a production install running the
      pre-sparse design (release backup 20260821-021445): every stock key
      fully enumerated, KOMenu:disabled empty, no sidecar metadata.
  dense-era_reader_menu_order.lua
      Same era/backup, reader view. Semantically IDENTICAL to today's
      stock layout (only exit_menu differs by absence).
  early-sidecar_reorderingmenus_state.lua
      REAL early-sidecar design file (hidden_origins map + mirror flags),
      captured from a production settings directory.
  v0_intent_*.lua / v1_intent_*.lua
      Synthetic but shape-faithful reconstructions of the two historical
      canonical-intent eras (schema 0: no version field; schema 1: version
      without meta.generation), cross-checked against MIGRATIONS[].

Scenarios:

  P1  real dense FM fixture -> deviations imported, defaults not frozen,
      restart-equivalent
  P2  real dense reader fixture -> byte-stock content yields ZERO records
      and a projection equal to current defaults everywhere
  P3  real early-sidecar file -> one-shot legacy migration into canonical
      intent across a module-reload process boundary
  P4  schema-v0 intent -> lossless migration, idempotent, no quarantine
  P5  schema-v1 intent -> generation stamped, records intact
  P6  dense fixture meets UPDATED stock defaults (new upstream row):
      newcomer visible, curated arrangement preserved, restart-stable
  P7  pre-provider-era sequences (order_override without sequence_eras)
      apply unconditionally

Run: cd /Applications/KOReader.app/Contents/koreader &&
     ./luajit <project>/tests/test_historical_fixtures.lua
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
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
local AtomicWriter = require("reorderingmenus_atomic_writer")

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
local FX = project_dir .. "/tests/fixtures/historical"

local STATE_FILES = {
    VIEW .. "_menu_order.lua", OTHER .. "_menu_order.lua",
    "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua",
    "reorderingmenus_state.lua",
}

local function wipe_all()
    for _, f in ipairs(STATE_FILES) do os.remove(sd .. "/" .. f) end
    -- Recovery artifacts from any earlier run would defeat the
    -- "no quarantine produced" assertion below.
    local lfs = require("libs/libkoreader-lfs")
    for entry in lfs.dir(sd) do
        if entry:find("^reorderingmenus_intent%.lua%.corrupt")
                or entry:find("^reorderingmenus_intent%.lua%.unsupported") then
            os.remove(sd .. "/" .. entry)
        end
    end
    Manager.default_orders[VIEW] = nil
    Manager.default_orders[OTHER] = nil
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager.recent_moves[VIEW] = {}
    Manager.recent_moves[OTHER] = {}
    Manager:dropSessionState(VIEW)
    Manager:dropSessionState(OTHER)
end

local function launch(view)
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, view or VIEW, false)
end

local function install_fixture(fixture_name, target_name)
    local f = io.open(FX .. "/" .. fixture_name, "r")
    local bytes = f and f:read("*a"); if f then f:close() end
    assert(bytes and #bytes > 0, "fixture missing: " .. fixture_name)
    local g = io.open(sd .. "/" .. target_name, "w")
    g:write(bytes); g:close()
end

local function count_records(section)
    local n = 0
    for _, coll in ipairs({ "hidden", "parent_override", "position_override",
            "order_override", "raw_override", "separators", "custom_menus" }) do
        for _ in pairs(section[coll] or {}) do n = n + 1 end
    end
    return n
end

-- True when `seq` appears in `list` as a subsequence (curated rows keep
-- their relative order even though unsequenced residents may slot-align
-- between them).
local function relativeOrderHolds(list, seq)
    local k = 1
    for _, id in ipairs(list) do
        if id == seq[k] then k = k + 1 end
    end
    return k > #seq
end

print("===============================================================")
print("=== P. Historical configuration fixtures (real artifacts)   ===")
print("===============================================================")

-- -------------------------------------------------------------------------
-- P1: REAL dense-era filemanager file (no sidecar -> importAgainstDefaults).
-- The fixture's deliberate customizations vs CURRENT defaults:
--   more_tools reordered (plugin row cluster differs from stock order),
--   battery_statistics + Storefront listed under tools,
--   auto_frontlight/synchronize_time/patch_management relocated inside
--   more_tools.
-- KOMenu:disabled is EMPTY in the fixture -> nothing may be imported as
-- hidden. Everything dense-but-stock stays record-free.
-- -------------------------------------------------------------------------
do
    wipe_all()
    install_fixture("dense-era_filemanager_menu_order.lua",
        VIEW .. "_menu_order.lua")
    launch()

    local sec = IntentStore.view(VIEW)
    note(next(sec.order_override) ~= nil,
        "P1: dense fixture's deviations imported as order records")
    note(sec.order_override.more_tools ~= nil
        and sec.order_override.tools ~= nil,
        "P1b: customized levels recorded (more_tools, tools)")
    note(next(sec.hidden) == nil,
        "P1c: empty fixture disabled-list imports NO hidden records")

    -- Visible layout: the deliberate arrangements render...
    local mt = Manager:getMenuItems(VIEW, "more_tools")
    note(mt[1] == "book_shortcuts",
        "P1d: more_tools shows the curated fixture arrangement")
    note(Manager:getParentMenu(VIEW, "battery_statistics") == "tools",
        "P1e: battery_statistics rendered under tools per the fixture")
    -- ...while untouched dense menus follow CURRENT defaults...
    local defaults = KoreaderAdapter.getDefaultOrder(VIEW)
    note(#Manager:getMenuItems(VIEW, "device") == #defaults.device,
        "P1f: dense-but-stock device menu follows current defaults")
    -- ...and nothing was frozen for them.
    note(sec.order_override.device == nil and sec.order_override.main == nil
        and sec.order_override.search == nil,
        "P1g: stock-dense levels left record-free (sparse purity)")

    -- Restart equivalence: same records, same projection.
    local baseline_records = count_records(sec)
    Manager:reloadFromDisk(VIEW)
    Manager:dropSessionState(VIEW); IntentStore.load(true)
    NativeWriter._resetCaches(); launch()
    local sec2 = IntentStore.view(VIEW)
    note(count_records(sec2) == baseline_records,
        "P1h: restart preserves the imported record set exactly")
    note(Manager:getParentMenu(VIEW, "battery_statistics") == "tools"
        and Manager:getMenuItems(VIEW, "more_tools")[1] == "book_shortcuts",
        "P1i: visible layout identical across restart")
    wipe_all()
end

-- -------------------------------------------------------------------------
-- P2: REAL dense-era READER file whose content equals today's stock layout
-- (except exit_menu, absent from the fixture). Expected: ZERO records, and
-- the served projection equals the current defaults for every default key.
-- -------------------------------------------------------------------------
do
    wipe_all()
    install_fixture("dense-era_reader_menu_order.lua",
        OTHER .. "_menu_order.lua")
    launch(OTHER)

    local sec = IntentStore.view(OTHER)
    note(count_records(sec) == 0 and sec.tab_order == nil,
        "P2: stock-identical dense file imports NOTHING (got "
        .. count_records(sec) .. " records)")

    local defaults = KoreaderAdapter.getDefaultOrder(OTHER)
    local all_match = true
    for menu_id, list in pairs(defaults) do
        if type(list) == "table" then
            local got = Manager:getMenuItems(OTHER, menu_id)
            if #got ~= #list then all_match = false
            else
                for i = 1, #list do
                    if got[i] ~= list[i] then all_match = false break end
                end
            end
        end
    end
    note(all_match, "P2b: projection equals current defaults on every key")

    Manager:reloadFromDisk(OTHER)
    Manager:dropSessionState(OTHER); IntentStore.load(true)
    NativeWriter._resetCaches(); launch(OTHER)
    note(count_records(IntentStore.view(OTHER)) == 0,
        "P2c: restart keeps the stock-identical world record-free")
    wipe_all()
end

-- -------------------------------------------------------------------------
-- P3: REAL early-sidecar reorderingmenus_state.lua. A legacy sidecar is
-- discovered only across a PROCESS boundary (downgrade/upgrade + restart);
-- the one-shot migration flag is module-local, so simulate the boundary by
-- reloading the manager module (same technique as test_writer_version_upgrade
-- P2). Expected: hidden_origins become canonical hidden records.
-- -------------------------------------------------------------------------
do
    wipe_all()
    -- No canonical intent file yet: the migration path requires its absence.
    os.remove(sd .. "/reorderingmenus_intent.lua")
    install_fixture("early-sidecar_reorderingmenus_state.lua",
        "reorderingmenus_state.lua")
    assert(not IntentStore.hasPersistedState(),
        "P3 setup: canonical intent must not pre-exist")

    package.loaded["reorderingmenus_intent_store"] = nil
    package.loaded["reorderingmenus_menuorder_manager"] = nil
    package.loaded["reorderingmenus_ui_screens"] = nil
    IntentStore = require("reorderingmenus_intent_store")
    Manager = require("reorderingmenus_menuorder_manager")
    UIScreens = require("reorderingmenus_ui_screens")
    NativeWriter._resetCaches(); launch()

    note(Manager:isItemHidden(VIEW, "plugin_management"),
        "P3: legacy hidden_origins entry migrated and applied")
    note(IntentStore.view(VIEW).hidden.plugin_management ~= nil
        and IntentStore.view(VIEW).hidden.plugin_management.origin
            == "more_tools",
        "P3b: canonical holds the migrated record with its origin")

    Manager:dropSessionState(VIEW); IntentStore.load(true); launch()
    note(Manager:isItemHidden(VIEW, "plugin_management"),
        "P3c: migrated hide durable across restart")
    wipe_all()
end

-- -------------------------------------------------------------------------
-- P4: schema-v0 canonical intent (no version field). Migration must be
-- lossless, stamp version 2, add meta.generation, and be IDEMPOTENT (a
-- second load neither quarantines nor alters anything).
-- -------------------------------------------------------------------------
do
    wipe_all()
    AtomicWriter.writeTable(sd .. "/reorderingmenus_intent.lua", {
        views = {
            filemanager = {
                hidden = { history = { origin = "main" } },
                hidden_order = { "history" },
                parent_override = { opds = { parent = "tools" } },
                order_override = { search =
                    { "opds", "search_settings", "dictionary_lookup" } },
            },
            reader = {},
        },
        meta = { mirror_changes = false },
    })
    -- Process-boundary semantics: the file is discovered at load time, so
    -- force the reload before the session syncs (same pattern as every
    -- other suite that plants a file underneath a running manager).
    Manager:dropSessionState(VIEW)
    IntentStore.load(true)
    NativeWriter._resetCaches()
    launch()

    local sec = IntentStore.view(VIEW)
    note(sec.hidden.history ~= nil
        and sec.parent_override.opds ~= nil
        and sec.parent_override.opds.parent == "tools"
        and sec.order_override.search.entries[1].id == "opds",
        "P4: v0 records migrated losslessly")
    note(IntentStore.meta().generation == 0,
        "P4b: generation counter initialized at 0")
    local raw = io.open(sd .. "/reorderingmenus_intent.lua", "r")
    local body = raw and raw:read("*a"); if raw then raw:close() end
    note(body and body:find('["version"] = 3', 1, true) ~= nil,
        "P4c: on-disk file stamped schema version 3")

    -- Idempotence: reload changes nothing, quarantines nothing.
    local n_before = count_records(sec)
    IntentStore.load(true); NativeWriter._resetCaches()
    Manager:dropSessionState(VIEW); launch()
    local lfs_ok, quarantined = pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        local found = false
        for entry in lfs.dir(sd) do
            if entry:find("^reorderingmenus_intent%.lua%.corrupt") then
                found = true
            end
        end
        return found
    end)
    note(lfs_ok and not quarantined,
        "P4d: healthy v0 migration never produces a quarantine backup")
    note(count_records(IntentStore.view(VIEW)) == n_before,
        "P4e: second migration pass is record-idempotent")

    -- Visible consequence of the migrated records. Per S4, untouched stock
    -- rows keep stock-relative order around the curated spine; per S5
    -- (single-parent discipline) opds's explicit parent_override -> tools
    -- WINS over its stale membership in the search sequence, so the search
    -- projection must show the remaining sequenced rows in relative order.
    local function seq_index(list, id)
        for i, x in ipairs(list) do if x == id then return i end end
        return math.huge
    end
    local rendered = Manager:getMenuItems(VIEW, "search")
    note(seq_index(rendered, "search_settings")
            < seq_index(rendered, "dictionary_lookup"),
        "P4f: migrated sequence renders in the projection (relative order)")
    note(seq_index(rendered, "opds") == math.huge
        and Manager:getParentMenu(VIEW, "opds") == "tools",
        "P4f2: parent_override beats stale sequence membership")
    note(not Manager:isItemHidden(VIEW, "history") == false,
        "P4g: migrated hide renders")
    wipe_all()
end

-- -------------------------------------------------------------------------
-- P5: schema-v1 canonical intent (version=1, no meta.generation). Same
-- lossless contract, plus the v1->v2 generation stamp.
-- -------------------------------------------------------------------------
do
    wipe_all()
    AtomicWriter.writeTable(sd .. "/reorderingmenus_intent.lua", {
        version = 1,
        views = {
            filemanager = {
                hidden = {},
                hidden_order = {},
                parent_override = {
                    dictionary_lookup = { provider = nil, parent = "search_settings" },
                },
                position_override = {
                    wikipedia_lookup = { provider = nil, after = "opds" },
                },
                order_override = {},
                custom_menus = {},
                separators = {},
                raw_override = {},
            },
            reader = {},
        },
        meta = { mirror_changes = false, hidden_in_place = true },
    })
    Manager:dropSessionState(VIEW)
    IntentStore.load(true)
    NativeWriter._resetCaches()
    launch()

    local sec = IntentStore.view(VIEW)
    note(sec.position_override.wikipedia_lookup ~= nil
        and sec.position_override.wikipedia_lookup.after == "opds"
        and sec.parent_override.dictionary_lookup.parent == "search_settings",
        "P5: v1 anchor + move records survive migration")
    note(type(IntentStore.meta().generation) == "number",
        "P5b: v1->v2 stamped meta.generation")
    note(IntentStore.SCHEMA_VERSION == 3
        and IntentStore.meta().generation == 0,
        "P5c: current build reads/writes schema 3")
    wipe_all()
end

-- -------------------------------------------------------------------------
-- P6: dense fixture meets UPDATED stock defaults (simulated KOReader
-- update adding an upstream row). The imported arrangement persists, and
-- the newcomer becomes visible without disturbing curated levels.
-- -------------------------------------------------------------------------
do
    wipe_all()
    install_fixture("dense-era_filemanager_menu_order.lua",
        VIEW .. "_menu_order.lua")
    launch()
    note(Manager:getParentMenu(VIEW, "battery_statistics") == "tools",
        "P6 setup: fixture imported")

    -- Simulate an update: stock defaults gain 'storefront_probe'.
    local updated = KoreaderAdapter.getDefaultOrder(VIEW)
    table.insert(updated.more_tools, "storefront_probe")
    Manager.default_orders[VIEW] = updated

    Manager:reloadFromDisk(VIEW)
    Manager:dropSessionState(VIEW); IntentStore.load(true)
    NativeWriter._resetCaches(); launch()

    local seen, duplicated = {}, false
    for _, id in ipairs(Manager:getMenuItems(VIEW, "more_tools")) do
        if id == "storefront_probe" then
            if seen[id] then duplicated = true end
            seen[id] = true
        end
    end
    note(seen.storefront_probe,
        "P6: upstream newcomer visible after defaults update")
    note(not duplicated, "P6b: newcomer not duplicated")
    note(Manager:getParentMenu(VIEW, "battery_statistics") == "tools",
        "P6c: curated fixture arrangement survived the update")

    Manager:dropSessionState(VIEW); IntentStore.load(true); launch()
    note(Manager:getParentMenu(VIEW, "battery_statistics") == "tools"
        and seen.storefront_probe,
        "P6d: post-update layout restart-stable")
    wipe_all()  -- also clears the injected defaults hook
end

-- -------------------------------------------------------------------------
-- P7: pre-provider-era bulk sequences: an order_override WITHOUT companion
-- sequence_eras must apply UNCONDITIONALLY (unstamped = legacy apply-all),
-- never be skipped for lacking stamps.
-- -------------------------------------------------------------------------
do
    wipe_all()
    AtomicWriter.writeTable(sd .. "/reorderingmenus_intent.lua", {
        version = 2,
        views = {
            filemanager = {
                hidden = {}, hidden_order = {},
                parent_override = {}, position_override = {},
                order_override = { search =
                    { "wikipedia_lookup", "opds", "search_settings",
                      "dictionary_lookup", "dictionary_lookup_history" } },
                custom_menus = {}, separators = {}, raw_override = {},
            },
            reader = {},
        },
        meta = { mirror_changes = false, hidden_in_place = true,
                 generation = 0, view_generations = {} },
    })
    Manager:dropSessionState(VIEW)
    IntentStore.load(true)
    NativeWriter._resetCaches()
    launch()

    local items = Manager:getMenuItems(VIEW, "search")
    -- S4: untouched stock rows interleave at stock-relative slots; the
    -- legacy sequence governs the RELATIVE order of its own members.
    local function seq_index(list, id)
        for i, x in ipairs(list) do if x == id then return i end end
        return math.huge
    end
    note(seq_index(items, "wikipedia_lookup") < seq_index(items, "opds")
        and seq_index(items, "opds") < seq_index(items, "search_settings")
        and seq_index(items, "search_settings") < seq_index(items, "dictionary_lookup"),
        "P7: unstamped legacy sequence applies (relative order)")

    Manager:dropSessionState(VIEW); IntentStore.load(true)
    NativeWriter._resetCaches(); launch()
    items = Manager:getMenuItems(VIEW, "search")
    note(seq_index(items, "wikipedia_lookup") < seq_index(items, "opds"),
        "P7b: unstamped sequence restart-stable")
    wipe_all()
end

wipe_all()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)

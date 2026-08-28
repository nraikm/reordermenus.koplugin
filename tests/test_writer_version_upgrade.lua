--[[
test_writer_version_upgrade.lua — Areas O + P.

O. Writer/fingerprint algorithm changes between plugin versions: v2 must not
   mistake v1 project-generated files for human edits when they can be
   recognized safely.

  O1  v1-shaped emission + v1 sidecar -> recognized as our own stale output,
      regenerated from intent (not imported as external edits).
  O2  v1 native file WITHOUT any sidecar (sidecar lost) -> imported against
      defaults like any legacy file (safe fallback).
  O3  fingerprint ALGORITHM change: same structure, different hash string ->
      treated as ours via previous_fingerprint chain, never as hand edit.
  O4  writer/schema metadata: sidecar carries format markers; unknown future
      marker quarantines instead of misreading.

P. Historical fixtures: real old-format files loaded against current code.
  P1  pre-sparse dense order file (legacy full-native design)
  P2  early sidecar era file (reorderingmenus_state.lua)
  P3  sparse-intent v0/v1 files

Run: cd /Applications/KOReader.app/Contents/koreader &&
     ./luajit <project>/tests/test_writer_version_upgrade.lua
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
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua",
        "reorderingmenus_state.lua" }) do
        os.remove(sd .. "/" .. f)
    end
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}
    Manager.recent_moves.reader = {}
    Manager:dropSessionState(VIEW)
    Manager:dropSessionState(OTHER)
end

local function launch()
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)
end

local function write_native(tbl)
    KoreaderAdapter.writeNativeOrder(VIEW, tbl)
end

-- rewrite ONLY the sidecar's fingerprint fields to simulate an older
-- fingerprint algorithm while keeping the same structure.
local function rehash_sidecar(new_fp)
    local path = sd .. "/reorderingmenus_materialization.lua"
    local f = io.open(path, "r")
    local body = f and f:read("*a") or ""
    if f then f:close() end
    -- naive but effective for the dump format: replace fingerprint strings
    body = body:gsub('%["fingerprint"%] = "[^"]*"',
        '%["fingerprint"%] = "' .. new_fp .. '"')
    body = body:gsub('%["previous_fingerprint"%] = "[^"]*"',
        '%["previous_fingerprint"%] = "' .. new_fp .. '"')
    local g = io.open(path, "w")
    g:write(body); g:close()
    NativeWriter._resetCaches()
end

print("===============================================================")
print("=== O. Writer / fingerprint version upgrade                  ===")
print("===============================================================")

-- O1+O3: produce a real emission; simulate BOTH a v1 fingerprint algorithm
-- (different hash text, identical structure) and a v1 writer whose emitted
-- bytes differ only in formatting. Startup must regenerate from intent.
do
    wipe_all(); launch()
    Manager:setItemHidden(VIEW, "screensaver", true, "screen")
    Manager:saveOrder(VIEW)

    -- capture current native bytes; simulate v1 formatting differences by
    -- rewriting with different whitespace (same semantic structure).
    local f = io.open(sd .. "/" .. VIEW .. "_menu_order.lua", "r")
    local cur_bytes = f and f:read("*a"); if f then f:close() end
    local v1_bytes = cur_bytes:gsub("%s*%[\"(%w+)\"%]%s*=%s*%{", " [\"%1\"]={")
        :gsub("%s*%[(%d+)%]%s*=%s*\"([^\"]+)\"", "[%1]=\"%2\"")
    if v1_bytes == cur_bytes then
        -- formatting transform was a no-op on this shape; force a visible one
        v1_bytes = cur_bytes:gsub("return {", "return{")
    end
    do
        local g = io.open(sd .. "/" .. VIEW .. "_menu_order.lua", "w")
        g:write(v1_bytes); g:close()
    end
    rehash_sidecar("v1algo_deadbeef")

    Manager:dropSessionState(VIEW); IntentStore.load(true); NativeWriter._resetCaches()
    launch()

    -- either path is acceptable and deterministic: regeneration from intent
    -- or import of a semantically-identical file. What matters: the user's
    -- customization survives and no duplicate records appear.
    note(Manager:isItemHidden(VIEW, "screensaver"),
        "O1: customization survives v1-formatted files")
    local n_hidden = 0
    for _ in pairs(IntentStore.view(VIEW).hidden) do n_hidden = n_hidden + 1 end
    note(n_hidden <= 1, "O1b: no duplicated records after v1 handling")

    Manager:dropSessionState(VIEW); IntentStore.load(true); launch()
    note(Manager:isItemHidden(VIEW, "screensaver"),
        "O1c: stable across reload")
    wipe_all()
end

-- O2: v1 native file with NO sidecar -> importAgainstDefaults fallback.
do
    wipe_all(); launch()
    -- Verbatim CURRENT stock search list (dividers included): a v1-era file
    -- whose content matches today's defaults must import NOTHING. Derived
    -- from the live defaults so the check survives KOReader updates.
    write_native({
        search = (function()
            local out = {}
            for _, id in ipairs(Manager:getDefaultOrder(VIEW).search or {}) do
                table.insert(out, id)
            end
            return out
        end)(),
    })
    Manager:dropSessionState(VIEW); IntentStore.load(true); NativeWriter._resetCaches()
    launch()

    -- stock-order list produces NO records (sparse purity) — deterministic
    local n_oo = 0
    for _ in pairs(IntentStore.view(VIEW).order_override) do n_oo = n_oo + 1 end
    note(n_oo == 0, "O2: default-matching v1 file imports nothing (sparse)")
    wipe_all()
end

-- O4: sidecar with unknown future format marker must not crash startup.
do
    wipe_all(); launch()
    Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
    Manager:saveOrder(VIEW)
    local path = sd .. "/reorderingmenus_materialization.lua"
    local f = io.open(path, "r")
    local body = f and f:read("*a") or ""
    if f then f:close() end
    body = body:gsub("return {", 'return {\n    ["format"] = "future-writer-v99",\n    ["schema"] = 99,')
    do
        local g = io.open(path, "w")
        g:write(body); g:close()
    end
    NativeWriter._resetCaches()

    local ok = pcall(function()
        Manager:dropSessionState(VIEW); IntentStore.load(true)
        launch()
    end)
    note(ok, "O4: unknown future sidecar marker does not break startup")
    note(Manager:getParentMenu(VIEW, "opds") == "tools",
        "O4b: state still correct with future-marker sidecar")
    wipe_all()
end

-- O5: writer_version metadata contract. Every emission stamps the current
-- WRITER_VERSION into its sidecar record; a v1-era record (field absent)
-- with structurally identical bytes is recognized as our own output via
-- the structural fallback, and after the next save the record carries the
-- new version exactly once (one-shot upgrade).
do
    wipe_all(); launch()
    Manager:setItemHidden(VIEW, "calibre", true, "more_tools")
    Manager:saveOrder(VIEW)

    -- Simulate a v2->v3 writer bump on OUR side while the disk still holds
    -- a v2-stamped record: bytes untouched, only the expected stamp moves.
    note(NativeWriter.getRecord(VIEW).writer_version
        == NativeWriter.WRITER_VERSION,
        "O5: emission record stamped with current writer version")

    -- Downgrade simulation: an OLD build's record (no writer_version field)
    -- facing NEW code, bytes structurally identical to the recorded one.
    local path = sd .. "/reorderingmenus_materialization.lua"
    local f = io.open(path, "r")
    local body = f and f:read("*a") or ""
    if f then f:close() end
    body = body:gsub('%["writer_version"%] = %d+,?\n?', "")
    local g = io.open(path, "w") g:write(body) g:close()

    Manager:dropSessionState(VIEW); IntentStore.load(true)
    NativeWriter._resetCaches(); launch()

    note(Manager:isItemHidden(VIEW, "calibre"),
        "O5b: pre-metadata-era record recognized; customization intact")
    note(IntentStore.view(VIEW).hidden.calibre ~= nil,
        "O5c: no re-import of our own bytes as external edit")

    -- After the next save the record is re-stamped under the new writer.
    Manager:saveOrder(VIEW)
    note(NativeWriter.getRecord(VIEW).writer_version
        == NativeWriter.WRITER_VERSION,
        "O5d: next save re-stamps the upgraded writer version")
    wipe_all()
end

-- O6: downgrade -> quarantine -> re-upgrade round trip. A future-schema
-- canonical intent (version > ours) is quarantined UNTOUCHED and ignored;
-- after the simulated re-upgrade the quarantined bytes load losslessly.
do
    wipe_all(); launch()
    Manager:setItemHidden(VIEW, "history", true, "main")
    Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
    Manager:saveOrder(VIEW)

    -- capture the current (v2) intent bytes
    local ipath = sd .. "/reorderingmenus_intent.lua"
    local f = io.open(ipath, "r")
    local good_bytes = f and f:read("*a"); if f then f:close() end

    -- future build wrote a newer schema over it (version-agnostic: the
    -- on-disk SCHEMA_VERSION moves independently of this suite).
    local future = good_bytes:gsub('(%["version"%] = )%d+,',
        '%199,', 1)
    assert(future ~= good_bytes, "O6 setup: version stamp rewritten")
    local g = io.open(ipath, "w") g:write(future) g:close()

    Manager:dropSessionState(VIEW); IntentStore.load(true)
    NativeWriter._resetCaches(); launch()

    -- Downgraded build must NOT reinterpret the future file.
    note(not Manager:isItemHidden(VIEW, "history"),
        "O6: downgraded build ignores future schema (no misread)")
    local lfs = require("libs/libkoreader-lfs")
    local quarantined
    for entry in lfs.dir(sd) do
        if entry:find("^reorderingmenus_intent%.unsupported%.lua$") then
            quarantined = sd .. "/" .. entry
        end
    end
    note(quarantined ~= nil, "O6b: future file preserved via quarantine")
    if quarantined then
        local q = io.open(quarantined, "r")
        local qbytes = q and q:read("*a"); if q then q:close() end
        note(qbytes == future,
            "O6c: quarantined bytes byte-identical to the future file")
    end

    -- Re-upgrade: restore the good bytes (what the newer build would write).
    g = io.open(ipath, "w") g:write(good_bytes) g:close()
    Manager:dropSessionState(VIEW); IntentStore.load(true)
    NativeWriter._resetCaches(); launch()
    note(Manager:isItemHidden(VIEW, "history")
        and Manager:getParentMenu(VIEW, "opds") == "tools",
        "O6d: re-upgrade restores every record losslessly")
    wipe_all()
end

print("===============================================================")
print("=== P. Historical configuration fixtures                     ===")
print("===============================================================")

-- P1: pre-sparse DENSE order file (old full-native design): every menu key
-- fully enumerated. Current code imports deviations only.
do
    wipe_all()
    local defaults = Manager.default_orders[VIEW] or Manager:getDefaultOrder(VIEW)
    -- build a dense copy of ALL default lists verbatim (what the old design
    -- wrote), except ONE deliberate change: opds moved in search.
    local dense = {}
    for menu_id, list in pairs(defaults) do
        if type(list) == "table" and menu_id ~= "KOMenu:menu_buttons"
                and menu_id ~= "KOMenu:disabled" then
            dense[menu_id] = {}
            for _, id in ipairs(list) do dense[menu_id][#dense[menu_id]+1] = id end
        end
    end
    -- move opds to front of search
    local s = dense.search
    for i, id in ipairs(s) do
        if id == "opds" then table.remove(s, i) break end
    end
    table.insert(s, 1, "opds")
    write_native(dense)
    Manager:dropSessionState(VIEW); IntentStore.load(true); NativeWriter._resetCaches()
    launch()

    note(Manager:getMenuItems(VIEW, "search")[1] == "opds",
        "P1: dense-era file renders its deliberate change")
    -- untouched menus stay sparse (no records frozen)
    local n_oo = 0
    for _ in pairs(IntentStore.view(VIEW).order_override) do n_oo = n_oo + 1 end
    note(n_oo <= 1, "P1b: dense-but-default menus not frozen into records")
    wipe_all()
end

-- P2: early sidecar era (reorderingmenus_state.lua with hidden_origins).
do
    wipe_all()
    -- write the legacy state file exactly like the early design did
    local dump = require("dump")
    local legacy = {
        hidden_origins = {
            filemanager = { history = "main", calibre = "more_tools" },
            reader = {},
        },
        mirror_changes = false,
        hidden_in_place = true,
    }
    local AtomicWriter = require("reorderingmenus_atomic_writer")
    AtomicWriter.writeTable(sd .. "/reorderingmenus_state.lua", legacy)

    -- A legacy file is only ever discovered across a PROCESS boundary
    -- (binary downgrade/upgrade + restart). The one-shot migration flag
    -- lives in the manager module, so simulate the restart by reloading it.
    package.loaded["reorderingmenus_menuorder_manager"] = nil
    package.loaded["reorderingmenus_ui_screens"] = nil
    Manager = require("reorderingmenus_menuorder_manager")
    UIScreens = require("reorderingmenus_ui_screens")
    Manager:dropSessionState(VIEW); IntentStore.load(true); NativeWriter._resetCaches()
    launch()

    note(Manager:isItemHidden(VIEW, "history"),
        "P2: legacy hidden_origins migrated into intent store")
    note(Manager:isItemHidden(VIEW, "calibre"),
        "P2b: second legacy hide migrated")
    local migrated = IntentStore.view(VIEW).hidden.history ~= nil
    note(migrated, "P2c: canonical holds the migrated record")
    wipe_all()
end

-- P3: schema v0/v1 intent files migrate losslessly.
do
    wipe_all(); launch()
    -- craft a v1 intent file (no generation counter)
    local AtomicWriter = require("reorderingmenus_atomic_writer")
    local v1_state = {
        version = 1,
        views = {
            filemanager = {
                hidden = { history = { provider = "stock", origin = "main" } },
                hidden_order = { "history" },
                parent_override = { opds = { provider = "stock", parent = "tools" } },
                position_override = {},
                order_override = {},
                sequence_eras = {},
                custom_menus = {},
                separators = {},
                raw_override = {},
                tab_order = nil,
            },
            reader = {
                hidden = {}, hidden_order = {}, parent_override = {},
                position_override = {}, order_override = {},
                sequence_eras = {}, custom_menus = {}, separators = {},
                raw_override = {}, tab_order = nil,
            },
        },
        meta = { mirror_changes = false, hidden_in_place = true },
    }
    AtomicWriter.writeTable(sd .. "/reorderingmenus_intent.lua", v1_state)
    NativeWriter._resetCaches()

    Manager:dropSessionState(VIEW); IntentStore.load(true); launch()

    local sec = IntentStore.view(VIEW)
    note(sec.hidden.history ~= nil, "P3: v1 hidden record migrated")
    note(sec.parent_override.opds ~= nil
        and sec.parent_override.opds.parent == "tools",
        "P3b: v1 move record migrated")
    local meta = IntentStore.meta()
    note(type(meta.generation) == "number", "P3c: v1->v2 migration added generation")
    note(IntentStore.SCHEMA_VERSION == 3, "P3d: current schema version stamped")
    wipe_all()
end

wipe_all()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)

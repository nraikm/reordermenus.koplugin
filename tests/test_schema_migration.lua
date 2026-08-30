--[[--
Schema versioning & migration fixtures.

  M1  v0 file (no version field) loads; records survive; generation added.
  M2  v1 file migrates to current; migration adds generation only.
  M3  migration is idempotent: reload does not rewrite or re-detect.
  M4  restart after migration is stable (same semantic state).
  M5  future version (> supported) is quarantined verbatim and ignored;
      the live state starts clean but the user's bytes are preserved.
  M6  unknown top-level fields in a CURRENT-version file are preserved
      across load and resave (forward-compatible field tolerance).
  M7  current-version contradictory authority converges deterministically:
      raw levels win over order/separators, and legacy inline dividers become
      anchored separator records without surviving in bulk entries.
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local dump = require("dump")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
require("main")

local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local UIScreens = require("reorderingmenus_ui_screens")
local IntentStore = require("reorderingmenus_intent_store")
local NativeWriter = require("reorderingmenus_native_writer")

local view = "filemanager"
local sd = DataStorage:getSettingsDir()
local ORDER_FILE = sd .. "/" .. view .. "_menu_order.lua"
local INTENT_FILE = sd .. "/reorderingmenus_intent.lua"
local SIDECAR = sd .. "/reorderingmenus_materialization.lua"

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
    for _, f in ipairs({ ORDER_FILE, INTENT_FILE, SIDECAR,
            sd .. "/reorderingmenus_state.lua" }) do os.remove(f) end
    IntentStore.load(true)
    NativeWriter._resetCaches()
    MenuOrderManager:dropSessionState(view)
end
local function launch()
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, view, false)
end
local function read_intent() return dofile(INTENT_FILE) end

print("===============================================================")
print("=== Schema versioning & migration                           ===")
print("===============================================================")

print("\n--- M1: v0 file (no version field) ---")
do
    wipe()
    local f = io.open(INTENT_FILE, "w"); f:write([[
return {
    ["views"] = {
        ["reader"] = {},
        ["filemanager"] = {
            ["hidden"] = {
                ["keep_alive"] = { ["provider"] = "stock", ["origin"] = "more_tools" },
            },
            ["parent_override"] = {},
            ["position_override"] = {},
            ["order_override"] = {},
            ["sequence_eras"] = {},
            ["custom_menus"] = {},
            ["separators"] = {},
            ["raw_override"] = {},
        },
    },
    ["meta"] = { ["mirror_changes"] = false, ["hidden_in_place"] = true },
}]])
    f:close()
    IntentStore.load(true); NativeWriter._resetCaches()
    MenuOrderManager:dropSessionState(view); launch()
    assert_true(IntentStore.view(view).hidden.keep_alive ~= nil,
        "M1: v0 hidden record survives")
    local on_disk = read_intent()
    assert_eq(on_disk.version, IntentStore.SCHEMA_VERSION,
        "M1: version stamped to current")
    assert_eq(type(on_disk.meta.generation), "number",
        "M1: generation counter added")
end

print("\n--- M2: v1 file migrates ---")
do
    wipe(); launch()
    MenuOrderManager:moveItemToMenu(view, "opds", "search", "tools")
    MenuOrderManager:saveOrder(view)
    -- downgrade the file to v1 semantics: drop meta.generation + view_generations
    local data = read_intent()
    assert_true(data ~= nil and data.views ~= nil, "M2: current file readable")
    data.version = 1
    if data.meta then data.meta.generation = nil; data.meta.view_generations = nil end
    local f = io.open(INTENT_FILE, "w")
    f:write("return " .. dump(data, nil, true))
    f:close()

    -- reload from the downgraded bytes and require the migration to keep
    -- every record (run twice: the migration must be deterministic).
    for _ = 1, 2 do
        IntentStore.load(true); NativeWriter._resetCaches()
        MenuOrderManager:dropSessionState(view); launch()
        assert_true(IntentStore.view(view).parent_override.opds ~= nil,
            "M2: v1 move record survives migration")
        assert_eq(read_intent().version, IntentStore.SCHEMA_VERSION,
            "M2: version advanced to current")
        -- re-downgrade for the second pass
        local d2 = read_intent()
        d2.version = 1
        if d2.meta then d2.meta.generation = nil; d2.meta.view_generations = nil end
        f = io.open(INTENT_FILE, "w")
        f:write("return " .. dump(d2, nil, true))
        f:close()
    end
end

print("\n--- M3/M4: idempotence + restart stability ---")
do
    wipe(); launch()
    MenuOrderManager:moveItemToMenu(view, "opds", "search", "tools")
    MenuOrderManager:setItemHidden(view, "keep_alive", true, "more_tools")
    MenuOrderManager:saveOrder(view)

    -- force one migration cycle by downgrading twice
    for _ = 1, 2 do
        local data = read_intent()
        data.version = math.max(1, IntentStore.SCHEMA_VERSION - 1)
        if data.meta then data.meta.generation = nil end
        local f = io.open(INTENT_FILE, "w")
        f:write("return " .. dump(data, nil, true)); f:close()
        IntentStore.load(true)
    end
    assert_true(IntentStore.view(view).parent_override.opds ~= nil
        and IntentStore.view(view).hidden.keep_alive ~= nil,
        "M3: repeated migrate cycles keep semantics")

    -- simulated restart
    MenuOrderManager:dropSessionState(view)
    NativeWriter._resetCaches()
    IntentStore.load(true)
    launch()
    assert_true(IntentStore.view(view).parent_override.opds ~= nil,
        "M4: move survives restart after migration")
    assert_true(MenuOrderManager:isItemHidden(view, "keep_alive"),
        "M4: hide survives restart after migration")
end

print("\n--- M5: future schema version is quarantined ---")
do
    wipe(); launch()
    MenuOrderManager:moveItemToMenu(view, "opds", "search", "tools")
    MenuOrderManager:saveOrder(view)
    local f = io.open(INTENT_FILE, "r"); local c = f:read("*a"); f:close()
    local mutated = c:gsub('%["version"%] = ' .. IntentStore.SCHEMA_VERSION .. ',',
        '%["version"%] = ' .. (IntentStore.SCHEMA_VERSION + 7) .. ',')
    f = io.open(INTENT_FILE, "w"); f:write(mutated); f:close()

    local quarantine = sd .. "/reorderingmenus_intent.unsupported"
    -- Backups are timestamped + sequence-numbered and never overwrite an
    -- earlier artifact from the same second; match by prefix.
    os.execute(string.format("rm -f %s*", quarantine))
    IntentStore.load(true); NativeWriter._resetCaches()
    MenuOrderManager:dropSessionState(view); launch()
    assert_true(IntentStore.view(view).parent_override.opds == nil,
        "M5: future-version data NOT loaded into live state")
    local qf = io.popen(string.format("ls %s* 2>/dev/null", quarantine))
    local qpath = qf and qf:read("*l") or nil
    if qf then qf:close() end
    assert_true(qpath ~= nil, "M5: unsupported file quarantined verbatim")
    if qpath then
        local fh = io.open(qpath, "r")
        if fh then
            local body = fh:read("*a"); fh:close()
            assert_true(body:find("opds", 1, true) ~= nil,
                "M5: quarantine preserves the user's records")
        end
    end
    os.execute(string.format("rm -f %s*", quarantine))
end

print("\n--- M6: unknown top-level keys tolerated ---")
do
    wipe(); launch()
    MenuOrderManager:moveItemToMenu(view, "opds", "search", "tools")
    MenuOrderManager:saveOrder(view)
    local f = io.open(INTENT_FILE, "r"); local c = f:read("*a"); f:close()
    -- Production files carry a "-- <path>" header line before "return {",
    -- so anchor on the constructor itself rather than start-of-file.
    c = c:gsub("return %{", 'return {\n ["future_field"] = { nested = true },', 1)
    assert_true(c:find("future_field", 1, true) ~= nil,
        "M6 fixture: injection matched the constructor")
    f = io.open(INTENT_FILE, "w"); f:write(c); f:close()

    IntentStore.load(true); NativeWriter._resetCaches()
    MenuOrderManager:dropSessionState(view); launch()
    assert_true(IntentStore.view(view).parent_override.opds ~= nil,
        "M6: known records still load alongside unknown fields")
    MenuOrderManager:saveOrder(view)
    f = io.open(INTENT_FILE, "r"); c = f:read("*a"); f:close()
    assert_true(c:find("future_field", 1, true) ~= nil,
        "M6: unknown field survives load+resave round trip")
end

print("\n--- M7: current-schema authority normalization ---")
do
    wipe(); launch()
    -- Force a durable canonical file, then replace its view payload with the
    -- adversarial current-version fixture below.
    MenuOrderManager:moveItemToMenu(view, "opds", "search", "tools")
    MenuOrderManager:saveOrder(view)
    local data = read_intent()
    local section = data.views[view]
    section.parent_override = {}
    section.position_override = {}
    section.hidden = {}
    section.raw_override.help = { list = { "hostile_unknown", "about" } }
    section.order_override.help = {
        entries = { { id = "about", provider = "stock" } },
    }
    section.separators.conflicting_help = { parent = "help", after = "about" }
    section.order_override.search = {
        entries = {
            { id = "file_search", provider = "stock" },
            { separator = true },
            { id = "opds", provider = "stock" },
        },
    }
    local f = assert(io.open(INTENT_FILE, "w"))
    f:write("return " .. dump(data, nil, true)); f:close()

    IntentStore.load(true)
    local normalized = IntentStore.view(view)
    assert_true(normalized.raw_override.help ~= nil,
        "M7: raw passthrough survives as the level authority")
    assert_eq(normalized.order_override.help, nil,
        "M7: raw level clears contradictory bulk order")
    assert_eq(normalized.separators.conflicting_help, nil,
        "M7: raw level clears contradictory separator authority")
    local search = normalized.order_override.search
    assert_eq(#(search and search.entries or {}), 2,
        "M7: inline divider removed from bulk entries")
    local anchored = false
    for _, sep in pairs(normalized.separators or {}) do
        if sep.parent == "search" and sep.after == "file_search" then
            anchored = true
        end
    end
    assert_true(anchored, "M7: inline divider migrated to one anchored authority")

    IntentStore.load(true)
    local again = IntentStore.view(view)
    assert_eq(#(again.order_override.search.entries or {}), 2,
        "M7: normalization is idempotent after restart")
end

wipe()
print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

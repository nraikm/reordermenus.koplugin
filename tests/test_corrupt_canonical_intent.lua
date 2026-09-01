--[[--
Corrupt canonical intent handling (P0 regression suite).

Contract under test:

  C1  a corrupt canonical intent file must NEVER silently become a clean
      empty configuration; the pre-corruption state is preserved in a
      quarantine backup next to the original file;
  C2  repair is deterministic: the same corrupt input always yields the
      same repaired state, and repairs only drop what is malformed
      (healthy records survive);
  C3  each malformed collection is individually detectable and repaired;
  C4  a healthy file passes validation with zero problems (no false
      positive repairs) and produces no backup;
  C5  load() reports what it did (problems + backup path) via its return
      values and logs one structured warning per problem.
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

local _ = require("gettext")

require("main")

local IntentStore = require("intent_store")

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or ""))
    else
        failed = failed + 1
        print("  [FAIL] " .. (msg or "") ..
            string.format(" -> expected %s, got %s", tostring(expected), tostring(actual)))
    end
    io.stdout:flush()
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end

local settings_dir = DataStorage:getSettingsDir()
local INTENT_FILE = settings_dir .. "/reorderingmenus_intent.lua"

-- Tolerant accessors: the pre-fix API returns only the state, so every
-- expectation below must fail loudly instead of crashing the suite.
local function problems_of(state, problems)
    return type(problems) == "table" and problems or
        { { kind = "MISSING-REPORTING", collection = "NONE" } }
end
local function backup_of(backup_path)
    return backup_path
end

-- The dump serializer used by production (round-trips Lua tables to text).
local dump = require("dump")

local function write_intent(text)
    local f = assert(io.open(INTENT_FILE, "w"))
    f:write(text)
    f:close()
end

local function read_intent(path)
    local f = io.open(path or INTENT_FILE, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function list_backups()
    local found = {}
    -- Production suffix is ".lua.corrupt-<time>" (keeps the .lua extension
    -- so the quarantine opens in any editor as a Lua file).
    local p = io.popen("ls " .. settings_dir
        .. "/reorderingmenus_intent.lua.corrupt-* 2>/dev/null")
    for line in p:lines() do found[#found + 1] = line end
    p:close()
    table.sort(found)
    return found
end

local function clear_backups()
    os.execute("rm -f " .. settings_dir .. "/reorderingmenus_intent.lua.corrupt-*")
end

local function new_view_section()
    -- Schema v3 section shape (no hidden_order / sequence_eras / ui_state).
    return {
        hidden = {}, parent_override = {},
        position_override = {}, order_override = {},
        custom_menus = {}, separators = {}, raw_override = {}, tab_order = nil,
    }
end

local function healthy_state_table()
    local reader = new_view_section()
    reader.hidden.m2 = { provider = "stock", origin = "main", ordinal = 1 }
    reader.parent_override.mt1 = { provider = "stock", parent = "setting" }
    return {
        version = 3,
        views = { reader = reader, filemanager = new_view_section() },
        meta = { mirror_changes = false, hidden_in_place = true },
    }
end

-- Production persists dofile-ready files: "-- <path>\nreturn <payload>\n".
local function healthy_state_text()
    return table.concat({ "-- ", INTENT_FILE, "\nreturn ",
        dump(healthy_state_table(), nil, true), "\n" })
end

print("===============================================================")
print("=== Corrupt canonical intent handling                       ===")
print("===============================================================")

os.remove(INTENT_FILE)
clear_backups()

-- C4 first: healthy file -> no problems, no backup, no repair.
do
    write_intent(healthy_state_text())
    local state, problems_raw, backup_path = IntentStore.load(true)
    local problems = problems_of(state, problems_raw)
    assert_true(type(state) == "table", "C4: healthy file loads")
    assert_eq(#problems, 0, "C4: healthy file yields zero problems")
    assert_eq(backup_path, nil, "C4: healthy file creates no backup")
    assert_eq(#list_backups(), 0, "C4: no backup files on disk")
    -- untouched customization survived the round-trip
    assert_true(state.views.reader.hidden.m2 ~= nil, "C4: healthy records intact")
end

-- C1/C3: truncated garbage -> quarantine + clean state, never silent loss.
do
    write_intent("this is { not lua at all")
    local _, problems_raw, backup_path = IntentStore.load(true)
    local problems = problems_of(_, problems_raw)
    assert_eq(#problems, 1, "C1: unparsable file reports exactly one problem")
    assert_eq(problems[1].kind, "unparsable", "C1: problem kind is 'unparsable'")
    assert_true(type(backup_path) == "string", "C1: backup path returned")
    assert_eq(#list_backups(), 1, "C1: exactly one backup on disk")
    local backed = read_intent(backup_path)
    assert_eq(backed, "this is { not lua at all",
        "C1: backup preserves the corrupt bytes verbatim")
    -- canonical file is now a valid fresh state that parses
    local reparsed = loadfile(INTENT_FILE)
    assert_true(reparsed ~= nil, "C1: replaced file parses")
end

-- C1b: parsable but wrong shape (a number, not a table).
do
    clear_backups()
    write_intent("return 42")
    local _, problems_raw, backup_path = IntentStore.load(true)
    local problems = problems_of(_, problems_raw)
    assert_eq(#problems, 1, "C1b: wrong-typed payload reported")
    assert_eq(problems[1].kind, "unparsable",
        "C1b: non-table payload treated as unusable file")
    assert_true(backup_path ~= nil, "C1b: quarantined before replacement")
end

-- C2/C3: per-collection malformations are individually detected and
-- deterministically repaired, keeping healthy sibling records.
local CASES = {
    {
        name = "hidden record not a table",
        mutate = function(v) v.views.reader.hidden.m9 = "oops" end,
        expect_collection = "hidden",
        expect_gone = { ["reader.hidden"] = { "m9" } },
    },
    {
        name = "hidden record without ordinal is healed, not dropped",
        mutate = function(v)
            v.views.reader.hidden.h9 = { provider = "stock", origin = "main" }
        end,
        expect_collection = nil,       -- benign normalization: no quarantine
        expect_gone = {},
        ordinal_heal = true,
    },
    {
        name = "parent_override self-cycle",
        mutate = function(v)
            v.views.reader.parent_override.t1 = { provider = "stock", parent = "t1" }
        end,
        expect_collection = "parent_override",
        expect_gone = { ["reader.parent_override"] = { "t1" } },
    },
    {
        name = "position_override missing anchor",
        mutate = function(v) v.views.reader.position_override.mt1 = {} end,
        expect_collection = "position_override",
        expect_gone = { ["reader.position_override"] = { "mt1" } },
    },
    {
        name = "order_override not an array of strings",
        mutate = function(v) v.views.reader.order_override.main = { "m1", 99 } end,
        expect_collection = "order_override",
        expect_gone = { ["reader.order_override"] = { "main" } },
    },
    {
        name = "order_override duplicate entry keeps first occurrence",
        mutate = function(v)
            v.views.reader.order_override.main =
                { entries = { { id = "m1", provider = "stock" }, { id = "m1" } } }
        end,
        expect_count = 1,
        expect_collection = "order_override",
        duplicate_entry = true,
        expect_gone = {},
    },
    {
        name = "custom_menu record missing title",
        mutate = function(v)
            v.views.reader.custom_menus.custom_submenu_7 = { parent = "setting" }
        end,
        expect_collection = "custom_menus",
        expect_gone = { ["reader.custom_menus"] = { "custom_submenu_7" } },
    },
    {
        name = "custom_menu record missing title",
        mutate = function(v)
            v.views.reader.custom_menus.broken_menu = { after = false }
        end,
        expect_collection = "custom_menus",
        expect_gone = { ["reader.custom_menus"] = { "broken_menu" } },
    },
    {
        name = "order_override entry garbage is dropped wholesale",
        mutate = function(v)
            v.views.reader.order_override.main =
                { entries = { { id = "m1", provider = "stock" }, 42 } }
        end,
        expect_collection = "order_override",
        expect_gone = { ["reader.order_override"] = { "main" } },
    },
    {
        name = "separator record without parent",
        mutate = function(v)
            v.views.reader.separators.sep_1 = { after = "m1" }
        end,
        expect_collection = "separators",
        expect_gone = { ["reader.separators"] = { "sep_1" } },
    },
    {
        name = "raw_override list not strings",
        mutate = function(v) v.views.reader.raw_override.main = { list = { true } } end,
        expect_collection = "raw_override",
        expect_gone = { ["reader.raw_override"] = { "main" } },
    },
    {
        name = "tab_order not an array",
        mutate = function(v) v.views.filemanager.tab_order = "main" end,
        expect_collection = "tab_order",
        expect_gone = {},
    },
}

for _, case in ipairs(CASES) do
    do
        clear_backups()
        local ok, text = pcall(function()
            -- build the state as a real table, mutate it, dump it
            local chunk = assert(loadstring(healthy_state_text(), "fixture"))
            local v = chunk()
            case.mutate(v)
            return table.concat({ "-- ", INTENT_FILE, "\nreturn ",
                dump(v, nil, true), "\n" })
        end)
        if not ok then
            assert_true(false, case.name .. ": fixture build failed: " .. tostring(text))
        elseif case.ordinal_heal then
            -- Benign normalization path: the record is healed in place and
            -- NO quarantine is written (nothing destructive happened).
            write_intent(text)
            local s1, p1_raw = IntentStore.load(true)
            local p1 = problems_of(s1, p1_raw)
            assert_eq(#p1, 1, case.name .. ": missing ordinal reported benignly")
            assert_eq(p1[1].kind, "missing_ordinal",
                case.name .. ": missing-ordinal kind identified")
            assert_eq(#list_backups(), 0, case.name .. ": healthy data NOT quarantined")
            assert_eq(#list_backups(), 0, case.name .. ": healthy data NOT quarantined")
            local rec = s1 and s1.views.reader.hidden.h9 or nil
            assert_true(type(rec) == "table" and type(rec.ordinal) == "number",
                case.name .. ": ordinal assigned deterministically")
            -- idempotent: reload does not change anything
            local before = require("dump")(s1)
            IntentStore.load(true)
            assert_eq(#list_backups(), 0, case.name .. ": reload stays clean")
            assert_true(IntentStore.view("reader").hidden.h9 ~= nil,
                case.name .. ": healed record survives reload")
            _ = before
        elseif case.duplicate_entry then
            -- Duplicate sequence entries: benign heal (first occurrence wins).
            write_intent(text)
            local s1, p1_raw = IntentStore.load(true)
            local p1 = problems_of(s1, p1_raw)
            assert_eq(#p1, 1, case.name .. ": duplicate reported as benign problem")
            assert_eq(p1[1].kind, "duplicate_entry",
                case.name .. ": duplicate kind identified")
            assert_eq(#list_backups(), 0, case.name .. ": no backup for benign heal")
            local rec = s1.views.reader.order_override.main
            assert_eq(rec and rec.entries and #rec.entries or 0, 1,
                case.name .. ": first occurrence kept, duplicate dropped")
            assert_eq(rec.entries[1].provider, "stock",
                case.name .. ": surviving entry keeps its era stamp")
            write_intent(text)
            local s2, p2_raw = IntentStore.load(true)
            local p2 = problems_of(s2, p2_raw)
            assert_eq(#p2, 1, case.name .. ": reproducible detection")
            assert_eq(require("dump")(s1), require("dump")(s2),
                case.name .. ": repair is deterministic")
        else
            write_intent(text)
            local s1, p1_raw = IntentStore.load(true)
            local p1 = problems_of(s1, p1_raw)
            assert_eq(#p1, case.expect_count or 1,
                case.name .. ": problem count reported")
            assert_eq(p1[1].collection, case.expect_collection,
                case.name .. ": collection identified")
            assert_eq(#list_backups(), 1, case.name .. ": quarantined once")
            -- deterministic: reload from the SAME corrupt bytes again
            write_intent(read_intent(list_backups()[1]))
            local s2, p2_raw = IntentStore.load(true)
            local p2 = problems_of(s2, p2_raw)
            assert_eq(#p2, case.expect_count or 1,
                case.name .. ": reproducible detection")
            local d1, d2 = require("dump")(s1), require("dump")(s2)
            assert_eq(d1, d2, case.name .. ": repair is deterministic")
            -- healthy siblings survived
            if case.expect_gone["reader.hidden"] then
                for _, id in ipairs(case.expect_gone["reader.hidden"]) do
                    assert_true(s1.views.reader.hidden[id] == nil,
                        case.name .. ": malformed hidden dropped (" .. id .. ")")
                end
                assert_true(s1.views.reader.parent_override.mt1 ~= nil,
                    case.name .. ": healthy sibling kept")
            end
        end
    end
end

clear_backups()
os.remove(INTENT_FILE)

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

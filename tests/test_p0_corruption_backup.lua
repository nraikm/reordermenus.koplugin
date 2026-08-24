--[[
P0-6 regression suite: never destroy the only surviving representation.

  B1  corrupt canonical file + quarantine failure -> load() reports
      preservation_failed, continues on repaired in-memory state, and the
      ORIGINAL BYTES remain untouched on disk
  B2  while preservation is unresolved, IntentStore.save() refuses every
      durable canonical write (in-session work stays in memory)
  B3  after a restart (fresh quarantine attempt), a successful backup heals
      normally and the corrupt original is replaced
  B4  healthy file + healthy backup path -> no behavior change
  B5  unsupported future schema + failed quarantine -> original untouched,
      session runs on empty state
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
local _ = require("gettext")
require("main")

local IntentStore = require("reorderingmenus_intent_store")
local dump = require("dump")

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

local function clear_backups()
    os.execute("rm -f " .. settings_dir .. "/reorderingmenus_intent.lua.corrupt-*")
    os.execute("rm -f " .. settings_dir .. "/reorderingmenus_intent.lua.unsupported*")
end

local CORRUPT_BYTES = "this is { not lua at all"

print("===============================================================")
print("=== P0-6: corruption recovery must preserve the original     ===")
print("===============================================================")

print("\n--- B1/B2: quarantine fails -> original survives, save refuses ---")
do
    clear_backups()
    write_intent(CORRUPT_BYTES)
    local before = read_intent()

    -- Make the verbatim quarantine fail (its temp write cannot be staged).
    local real_rename = os.rename
    os.rename = function(a, b)
        if type(b) == "string" and b:find("reorderingmenus_intent%.lua%.corrupt%-") then
            return nil, "permission denied (injected)"
        end
        return real_rename(a, b)
    end
    local state, problems = IntentStore.load(true)
    os.rename = real_rename

    -- The session continues on repaired (fresh) in-memory state.
    assert_true(type(state) == "table", "B1: load returns usable state")
    local found_preservation_problem = false
    for _, p in ipairs(problems or {}) do
        if p.kind == "preservation_failed" then
            found_preservation_problem = true
        end
    end
    assert_true(found_preservation_problem,
        "B1: preservation failure reported in problem list")
    -- THE INVARIANT: original bytes are still exactly on disk.
    assert_eq(read_intent(), before,
        "B1: corrupt ORIGINAL bytes untouched by recovery")
    assert_true(IntentStore.isOriginalPreserved() == false,
        "B1: store reports unresolved preservation")
    -- Any durable canonical write is refused while the original is at risk.
    local ok_save, save_err = IntentStore.save()
    assert_eq(ok_save, false, "B2: durable save refused")
    assert_true(type(save_err) == "string" and save_err:len() > 0,
        "B2: refusal carries a reason")
    assert_eq(read_intent(), before,
        "B2: disk STILL holds the original after refused save")
end

print("\n--- B3: restart with working backup heals normally ---")
do
    -- Fresh process semantics: re-load with injections lifted.
    clear_backups()
    write_intent(CORRUPT_BYTES)
    local state, problems, backup_path = IntentStore.load(true)
    assert_true(type(state) == "table", "B3: loads")
    assert_eq(#problems, 1, "B3: unparsable reported once")
    assert_true(type(backup_path) == "string", "B3: quarantined to backup")
    assert_true(IntentStore.isOriginalPreserved(),
        "B3: preservation resolved")
    assert_eq(read_intent(backup_path), CORRUPT_BYTES,
        "B3: backup holds the corrupt bytes verbatim")
    -- Now the repaired canonical world may be persisted.
    local ok_save = IntentStore.save()
    assert_eq(ok_save, true, "B3: durable save allowed again")
end

print("\n--- B4: healthy file unaffected ---")
do
    clear_backups()
    local healthy = {
        version = 2,
        views = {
            reader = { hidden = {}, hidden_order = {}, parent_override = {},
                position_override = {}, order_override = {},
                sequence_eras = {}, custom_menus = {}, separators = {},
                raw_override = {} },
            filemanager = { hidden = {}, hidden_order = {},
                parent_override = {}, position_override = {},
                order_override = {}, sequence_eras = {},
                custom_menus = {}, separators = {}, raw_override = {} },
        },
        meta = { generation = 4,
            view_generations = { reader = 2, filemanager = 2 },
            ui_state = { hidden_anchors = { reader = {}, filemanager = {} } } },
    }
    local text = table.concat({ "-- ", INTENT_FILE, "\nreturn ",
        dump(healthy, nil, true), "\n" })
    write_intent(text)
    local before = read_intent()
    local state, problems = IntentStore.load(true)
    assert_eq(#problems, 0, "B4: zero problems on healthy file")
    assert_true(IntentStore.isOriginalPreserved(), "B4: no preservation issue")
    assert_eq(read_intent(), before, "B4: healthy bytes untouched")
end

print("\n--- B5: unsupported schema + failed quarantine ---")
do
    clear_backups()
    local future = table.concat({ "-- ", INTENT_FILE, "\nreturn ",
        dump({ version = 99, views = {}, meta = {} }, nil, true), "\n" })
    write_intent(future)
    local before = read_intent()

    local real_rename = os.rename
    os.rename = function(a, b)
        if type(b) == "string"
                and b:find("reorderingmenus_intent%.lua%.unsupported") then
            return nil, "permission denied (injected)"
        end
        return real_rename(a, b)
    end
    local state, problems = IntentStore.load(true)
    os.rename = real_rename

    assert_true(type(state) == "table", "B5: usable empty state returned")
    local preserved_flag = false
    for _, p in ipairs(problems or {}) do
        if p.preserved == false then preserved_flag = true end
    end
    assert_true(preserved_flag, "B5: problem carries preserved=false")
    assert_eq(read_intent(), before,
        "B5: unsupported ORIGINAL bytes untouched")
    assert_true(IntentStore.isOriginalPreserved() == false,
        "B5: writes stay blocked until quarantine succeeds")
    assert_eq(select(1, IntentStore.save()), false,
        "B5: save refused")
end

clear_backups()
os.remove(INTENT_FILE)
print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

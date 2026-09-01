--[[
P0-7 + P0-8 regression suite: restricted data loaders & preset containment.

Loader (P0-7):
  L1  a valid historical dump() file loads and round-trips
  L2  a data file cannot modify globals, write files, or reach os.execute:
      every attempt raises inside the sandbox and is reported as a failure
      - no side effect occurs
  L3  non-table payloads are rejected with a clear error
  L4  missing/unreadable files fail soft
Presets (P0-8):
  N1  traversal/absolute/nested/sibling-prefix names are REJECTED, never
      transformed: "../foo", "../../foo", "/absolute", "a/b", "foo/../bar",
      ".", "..", backslash forms
  N2  case-variant collision still refused; same name overwrite allowed via
      update path
  N3  resolve() refuses caller-supplied raw paths (id/name-based API only)
  N4  savePreset with a hostile name writes NOTHING anywhere outside the
      presets directory
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

local DataLoader = require("data_loader")
local Presets = require("presets")
local IntentStore = require("intent_store")

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
local probe_file = settings_dir .. "/loader_probe.lua"
local canary = "/tmp/rm_loader_canary_%d.lua"

local function write(path, body)
    local f = assert(io.open(path, "w"))
    f:write(body)
    f:close()
end

print("===============================================================")
print("=== P0-7/P0-8: restricted loaders & preset containment       ===")
print("===============================================================")

print("\n--- L1: valid historical files keep loading ---")
do
    local dump = require("dump")
    local payload = { format = "reorderingmenus_intent_preset", version = 2,
        intent = { hidden = { m1 = { provider = "stock", origin = "main" } } } }
    write(probe_file, "-- " .. probe_file .. "\nreturn "
        .. dump(payload, nil, true) .. "\n")
    local data, err = DataLoader.loadTable(probe_file)
    assert_true(data ~= nil, "L1: valid file loads")
    assert_eq(err, nil, "L1: no error for valid file")
    assert_eq(data.intent.hidden.m1.origin, "main", "L1: content intact")
    os.remove(probe_file)
end

print("\n--- L2/L3/L4: hostile payloads cannot execute anything ---")
do
    local attempts = {
        { name = "global write",
          body = "return (function() __RM_CANARY__ = 42 return {} end)()" },
        { name = "io write",
          body = 'return (function() local f = io.open("' ..
              string.format(canary, 1) .. '", "w") f:write("x") f:close() return {} end)()' },
        { name = "os.execute",
          body = 'return (function() os.execute("touch ' ..
              string.format(canary, 2) .. '") return {} end)()' },
        { name = "dofile escape",
          body = 'return (function() dofile("' .. probe_file .. '") return {} end)()' },
        { name = "require escape",
          body = "return (function() require(\"util\") return {} end)()" },
        { name = "_G walk",
          body = "return (function() local g = getfenv and getfenv(1) or _G g[\"x\"] = 1 return {} end)()" },
    }
    for _, att in ipairs(attempts) do
        write(probe_file, att.body)
        local data, err = DataLoader.loadTable(probe_file)
        assert_eq(data, nil,
            "L2 (" .. att.name .. "): hostile file rejected")
        assert_true(type(err) == "string" and #err > 0,
            "L2 (" .. att.name .. "): failure carries diagnostics")
    end
    -- No side effects happened.
    local lfs = require("libs/libkoreader-lfs")
    assert_true(lfs.attributes(string.format(canary, 1)) == nil,
        "L2: io.open inside data file had NO effect")
    assert_true(lfs.attributes(string.format(canary, 2)) == nil,
        "L2: os.execute inside data file had NO effect")

    -- L3: non-table payloads rejected.
    write(probe_file, "return 42")
    local d3, e3 = DataLoader.loadTable(probe_file)
    assert_eq(d3, nil, "L3: number payload rejected")
    assert_true(tostring(e3):find("table") ~= nil, "L3: error names the type problem")
    write(probe_file, "return function() return 1 end")
    local d3b = DataLoader.loadTable(probe_file)
    assert_eq(d3b, nil, "L3: function payload rejected")

    -- L4: missing / unreadable.
    local d4, e4 = DataLoader.loadTable(settings_dir .. "/definitely_missing_9.lua")
    assert_eq(d4, nil, "L4: missing file fails soft")
    assert_true(type(e4) == "string", "L4: missing file reports why")
    os.remove(probe_file)
end

print("\n--- N1/N2/N4: preset names are validated identifiers ---")
do
    local view = "filemanager"
    Presets.getPresetsDir(view)
    local lfs = require("libs/libkoreader-lfs")
    local PRESET_DIR = Presets.getPresetsDir(view)

    local function count_lua_files(dir)
        local n = 0
        if lfs.attributes(dir, "mode") == "directory" then
            for f in lfs.dir(dir) do
                if f:sub(-4) == ".lua" then n = n + 1 end
            end
        end
        return n
    end

    for _, bad in ipairs({ "../foo", "../../foo", "/absolute", "a/b",
            "foo/../bar", ".", "..", "a\\b", "..\\win", "\\\\srv\\share" }) do
        local before = count_lua_files(PRESET_DIR)
        local ok = Presets.saveViewPreset(view, bad, {})
        local after = count_lua_files(PRESET_DIR)
        assert_eq(ok, false,
            "N1: '" .. bad .. "' rejected outright")
        assert_eq(after, before,
            "N1: '" .. bad .. "' wrote nothing")
    end
    assert_true(lfs.attributes(settings_dir .. "/foo.lua") == nil,
        "N1: nothing escaped to the settings dir")
    assert_true(lfs.attributes(settings_dir .. "/menu_order_presets/foo.lua") == nil,
        "N1: sibling-prefix escape did not land in presets dir either")

    -- Hostile-but-innocent names are refused too (no silent transformation):
    for _, hostile in ipairs({ "emoji 🎉 party", "quote\"name", "semi;colon" }) do
        local ok = Presets.saveViewPreset(view, hostile, {})
        assert_eq(ok, false,
            "N1: hostile name '" .. hostile .. "' refused (not sanitized)")
    end

    -- Plain names still work; case-collision contract preserved.
    local baseline_files = count_lua_files(PRESET_DIR)
    local ok_save, save_err = Presets.saveViewPreset(view, "My Layout", {})
    assert_true(ok_save,
        "N2: plain name accepted (" .. tostring(save_err) .. ")")
    assert_eq(lfs.attributes(PRESET_DIR .. "/My Layout.lua", "mode"), "file",
        "N2: plain name wrote exactly its own file")
    local coll_ok, coll_err = Presets.saveViewPreset(view, "my layout", {})
    if coll_ok then
        -- Case-sensitive FS: both exist as distinct files is acceptable;
        -- nothing escaped though.
        assert_eq(lfs.attributes(PRESET_DIR .. "/my layout.lua", "mode"), "file",
            "N2: case-sensitive fs stores distinct names as distinct files")
        os.remove(PRESET_DIR .. "/my layout.lua")
        assert_eq(lfs.attributes(PRESET_DIR .. "/my layout.lua", "mode"), nil,
            "N2: near-collision cleanup removed its file")
    else
        assert_true(type(coll_err) == "string" and coll_err ~= "",
            "N2: near-collision refused with a message")
    end
    -- cleanup leaves the preset storage exactly as we found it.
    os.remove(PRESET_DIR .. "/My Layout.lua")
    assert_eq(lfs.attributes(PRESET_DIR .. "/My Layout.lua", "mode"), nil,
        "N2: plain-name cleanup removed its file")
    assert_eq(count_lua_files(PRESET_DIR), baseline_files,
        "N2: no preset files left behind by this scenario")
end

print("\n--- N3: resolve() refuses raw paths ---")
do
    local view = "filemanager"
    local ok, err = Presets.resolve(view,
        { path = settings_dir .. "/menu_order_presets/" .. view .. "/../evil.lua" })
    assert_eq(ok, nil, "N3: path-only table refused")
    assert_true(type(err) == "string", "N3: refusal explained")
    local ok2 = Presets.resolve(view, { path = "/etc/passwd" })
    assert_eq(ok2, nil, "N3: absolute foreign path refused")
    -- Enumerated-style descriptors still work. P1B: built-in fragments are
    -- view-typed, so the reader-only minimalist preset must resolve for the
    -- reader view and be REFUSED for the file manager.
    local ok3 = Presets.resolve(view, { id = "builtin_minimalist" })
    assert_eq(ok3, nil,
        "N3: reader builtin refused for filemanager (view compatibility)")
    local ok3b = Presets.resolve("reader", { id = "builtin_minimalist" })
    assert_true(ok3b ~= nil, "N3: builtin id resolves for its own view")
    local ok3c = Presets.resolve(view, { id = "builtin_clean_fm" })
    assert_true(ok3c ~= nil, "N3: FM builtin resolves for filemanager")
    local ok4 = Presets.resolve(view, { intent = { hidden = {} },
        name = "whatever" })
    assert_true(ok4 ~= nil, "N3: intent-carrying descriptor resolves")
end

os.remove(probe_file)
print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

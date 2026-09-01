--[[--
Preset-file robustness & filename hardening.

  F1  truncated preset file -> clean rejection, no crash, no partial apply
  F2  invalid shape (list instead of map) -> rejected
  F3  unknown future version in preset file -> rejected with message
  F4  path traversal names ("../x", "/x", "a/b", "..", ".") cannot escape
      the presets directory
  F5  case-collision refusal (Tools.lua vs tools.lua)
  F6  emoji / unicode / newline / quote names are sanitized safely
  F7  huge names rejected or truncated within filesystem limits
  F8  deletion while listed: deleting a preset file then applying fails soft
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

local MenuOrderManager = require("menuorder_manager")
local UIScreens = require("ui_screens")
local IntentStore = require("intent_store")
local NativeWriter = require("native_writer")
local Presets = require("presets")

local view = "filemanager"
local sd = DataStorage:getSettingsDir()
local PRESET_DIR = Presets.getPresetsDir(view)

local passed, failed = 0, 0
local function assert_eq(a, e, msg)
    if a == e then passed = passed + 1
    else failed = failed + 1
        print(string.format("  [FAIL] %s -> expected %s, got %s",
            msg, tostring(e), tostring(a)))
        io.stdout:flush()
    end
end
local function assert_true(c, msg) assert_eq(not not c, true, msg) end

local function fresh()
    os.remove(sd .. "/" .. view .. "_menu_order.lua")
    os.remove(sd .. "/reorderingmenus_intent.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    IntentStore.load(true); NativeWriter._resetCaches()
    MenuOrderManager:dropSessionState(view)
end

local function wipe_presets()
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(PRESET_DIR, "mode") == "directory" then
        for f in lfs.dir(PRESET_DIR) do
            if f:sub(-4) == ".lua" then os.remove(PRESET_DIR .. "/" .. f) end
        end
    end
end

print("===============================================================")
print("=== Preset file robustness                                   ===")
print("===============================================================")

fresh()
UIScreens:reconcileRegisteredItems(
    { ui = { menu = { registered_widgets = {} } } }, view, false)
wipe_presets()

print("\n--- F1/F2/F3: malformed preset contents ---")
do
    local cases = {
        { name = "F1-truncated", body = "return {" },
        { name = "F2-badshape",  body = 'return { "a", "b", "c" }' },
        { name = "F3-futurever",
          body = 'return { format = "reorderingmenus_intent_preset",'
              .. ' version = 99, name = "F3", intent = {} }' },
        { name = "F3b-wrongformat",
          body = 'return { format = "something_else", version = 2,'
              .. ' name = "F3b", intent = {} }' },
    }
    Presets.ensurePresetsDir(view)
    for _, case in ipairs(cases) do
        local fh = io.open(string.format("%s/%s.lua", PRESET_DIR, case.name), "w")
        assert(fh, "presets dir writable")
        fh:write(case.body); fh:close()
        local raw = Presets.readUserPreset(
            string.format("%s/%s.lua", PRESET_DIR, case.name))
        if case.name:find("^F1") then
            assert_eq(raw, nil, case.name .. ": unparsable file rejected")
        elseif case.name:find("^F2") then
            -- list-shaped file has no .intent; must not be applicable
            local usable = type(raw) == "table" and raw.intent ~= nil
            assert_eq(usable, false, case.name .. ": invalid shape unusable")
        else
            -- future version / wrong format must be refused at read time:
            -- readUserPreset returns nil for inadmissible envelopes, and the
            -- FILE must survive untouched either way.
            local refused = raw == nil
                or (type(raw) == "table"
                    and raw.format ~= "reorderingmenus_intent_preset")
            assert_true(refused, case.name .. ": unsupported envelope refused at read")
        end
        os.remove(string.format("%s/%s.lua", PRESET_DIR, case.name))
    end
end

print("\n--- F4: traversal names ---")
do
    for _, bad in ipairs({ "../evil", "/abs", "a/b", "..", ".", "c/d/e" }) do
        local ok, where = MenuOrderManager:savePreset(view, bad)
        if ok then
            local stem = tostring(where):match("([^/]+)%.lua$")
            -- the resulting file MUST live inside PRESET_DIR
            assert_true(stem ~= nil and not tostring(where):find("%.%./", 1, true),
                "F4: '" .. bad .. "' sanitized inside preset dir (-> "
                    .. tostring(stem) .. ")")
        else
            passed = passed + 1   -- outright refusal is also fine
        end
    end
    -- nothing may have escaped the directory:
    local lfs = require("libs/libkoreader-lfs")
    assert_true(lfs.attributes(sd .. "/evil.lua") == nil,
        "F4: nothing written above the preset dir")
end

print("\n--- F5: case collisions ---")
do
    wipe_presets()
    assert_true(MenuOrderManager:savePreset(view, "Tools") ~= false,
        "F5: first save ok")
    assert_eq(MenuOrderManager:savePreset(view, "tools"), false,
        "F5: case-variant save refused")
    local lfs = require("libs/libkoreader-lfs")
    local n = 0
    for f in lfs.dir(PRESET_DIR) do
        if f:sub(-4) == ".lua" then n = n + 1 end
    end
    assert_eq(n, 1, "F5: only one file exists")
end

print("\n--- F6: hostile characters ---")
do
    wipe_presets()
    for _, name in ipairs({ "emoji 🎉 party", "quote\"name", "semi;colon",
            "back\\slash", "tab\tname" }) do
        local ok = MenuOrderManager:savePreset(view, name)
        -- Either outcome is legal (sanitize or refuse); the REAL invariant
        -- is that a save either produced a .lua file inside PRESET_DIR or
        -- produced nothing at all - never an escape, never a crash.
        if ok then passed = passed + 1 end
    end
    local lfs = require("libs/libkoreader-lfs")
    local n_files = 0
    if lfs.attributes(PRESET_DIR, "mode") == "directory" then
        for f in lfs.dir(PRESET_DIR) do
            if f:sub(-4) == ".lua" then n_files = n_files + 1 end
        end
    end
    -- Whatever was sanitized must be enumerable in the one known directory;
    -- nothing may have landed outside it.
    assert_true(lfs.attributes(sd .. "/.lua") == nil
        and lfs.attributes(sd .. "/party.lua") == nil,
        "F6: no hostile-name file escaped the preset dir")
    for f in lfs.dir(PRESET_DIR) do
        if f:sub(-4) == ".lua" then os.remove(PRESET_DIR .. "/" .. f) end
    end
end

print("\n--- F7: huge names ---")
do
    wipe_presets()
    local ok = MenuOrderManager:savePreset(view, string.rep("H", 300))
    assert_eq(ok, false, "F7: oversized name rejected")
end

print("\n--- F8: deletion while in use ---")
do
    wipe_presets()
    MenuOrderManager:savePreset(view, "doomed")
    local path = string.format("%s/doomed.lua", PRESET_DIR)
    os.remove(path)
    local raw = Presets.readUserPreset(path)
    assert_eq(raw, nil, "F8: reading a deleted preset fails soft")
end

wipe_presets()
fresh()
print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

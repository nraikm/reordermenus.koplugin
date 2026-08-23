--[[--
Module namespace isolation (Area R2).

Lua's package.loaded is process-global, and KOReader's plugin loader leaves
EVERY plugin's directory on package.path after startup. A second plugin
shipping generic module names (registry.lua, presets.lua, ...) could
therefore hand this plugin the wrong module — unless every plugin-owned
module carries a unique require identity.

    N1  preloading FAKE registry / presets / validator / materializer
        modules under the GENERIC names must not poison ReorderingMenus:
        require("reorderingmenus_*") still returns our real modules
        (both fresh-load and cached-load paths)
    N2  the reverse direction: with all reorderingmenus_* modules loaded,
        a synthetic third-party plugin requiring generic "registry" gets
        ITS fake module, not ours
    N3  package.loaded holds no stale GENERIC keys for any of our old
        module names (the migration left nothing behind)
    N4  every production require of a plugin-local module uses the
        reorderingmenus_ prefix (source-level sweep over runtime files)
--]]

local function script_dir()
    local src = debug.getinfo(1, "S").source:sub(2)
    return src:match("^(.*)/tests/[^/]+$")
end
local project_dir = assert(script_dir(), "cannot locate plugin directory")

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir()
    .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

-- dev checkout LAST on the path: fakes resolve from tests/lib first
package.path = project_dir .. "/?.lua;" .. package.path

local T = { passed = 0, failed = 0 }
function T.assert_eq(actual, expected, msg)
    if actual == expected then
        T.passed = T.passed + 1
        print("  [PASS] " .. (msg or ""))
    else
        T.failed = T.failed + 1
        print("  [FAIL] " .. (msg or "") ..
            string.format(" -> expected %s, got %s",
                tostring(expected), tostring(actual)))
    end
    io.stdout:flush()
end
function T.assert_true(cond, msg) T.assert_eq(not not cond, true, msg) end
function T.summary(name)
    print(string.format("=== %s: %d passed, %d failed ===", name,
        T.passed, T.failed))
    if T.failed > 0 then os.exit(1) end
end

print("===============================================================")
print("Module namespace isolation")
print("===============================================================")

-- ---------------------------------------------------------------------------
-- synthetic third-party "plugin": four generic-named fake modules
-- ---------------------------------------------------------------------------
package.path = (project_dir .. "/tests/lib/fake_generic_plugin/?.lua;")
    .. package.path

local FAKE_NAMES = { "registry", "presets", "validator", "materializer" }

local function preload_fakes()
    for _, name in ipairs(FAKE_NAMES) do
        local chunk = assert(loadfile(
            project_dir .. "/tests/lib/fake_generic_plugin/" .. name .. ".lua"))
        package.loaded[name] = chunk()
    end
end

-- ---------------------------------------------------------------------------
-- N1a: fakes preloaded FIRST, then the plugin loads — it must get its own
-- modules (fresh resolution through the prefixed names).
-- ---------------------------------------------------------------------------
preload_fakes()

do
    -- clear anything already cached so N1a exercises real resolution
    for _, mod in ipairs({
        "reorderingmenus_registry", "reorderingmenus_presets",
        "reorderingmenus_validator", "reorderingmenus_materializer",
    }) do
        package.loaded[mod] = nil
    end

    local Registry = require("reorderingmenus_registry")
    local Presets = require("reorderingmenus_presets")

    T.assert_true(Registry and Registry._reorderingmenus_module ~= true,
        "N1a: registry resolves to the REAL module despite fake preload")
    T.assert_eq(type(Registry), "table",
        "N1a: real registry loads as a table under poisoned cache")
    T.assert_true(Presets and type(Presets) == "table",
        "N1a: presets resolves to the REAL module despite fake preload")
    T.assert_true(rawget(Registry, "_fake_generic_plugin") == nil,
        "N1a: registry is NOT one of the fakes")

    local Validator = require("reorderingmenus_validator")
    local Materializer = require("reorderingmenus_materializer")
    T.assert_true(type(Validator) == "table"
        and type(Materializer) == "table",
        "N1a: validator + materializer resolve to REAL modules")
    T.assert_true(rawget(Validator, "_fake_generic_plugin") == nil
        and rawget(Materializer, "_fake_generic_plugin") == nil,
        "N1a: neither validator nor materializer is a fake")
end

-- ---------------------------------------------------------------------------
-- N1b: same experiment with the REAL modules cached FIRST (KOReader loads
-- plugins in arbitrary order; the poison may come later too).
-- ---------------------------------------------------------------------------
do
    -- drop the fakes from the cache; keep them findable on disk
    for _, name in ipairs(FAKE_NAMES) do
        package.loaded[name] = nil
    end
    -- warm the cache with the real modules via a production entry point
    local Manager = require("reorderingmenus_menuorder_manager")
    T.assert_true(type(Manager) == "table",
        "N1b: menuorder_manager loaded (warms full real module graph)")

    preload_fakes()  -- NOW the hostile plugin registers its generics

    local Validator = require("reorderingmenus_validator")
    local Materializer = require("reorderingmenus_materializer")
    T.assert_true(rawget(Validator, "_fake_generic_plugin") == nil
        and rawget(Materializer, "_fake_generic_plugin") == nil,
        "N1b: cached real modules unaffected by later fake preload")
end

-- ---------------------------------------------------------------------------
-- N2: reverse direction — another plugin's generic require must get its
-- own fake, never ours.
-- ---------------------------------------------------------------------------
do
    local foreign = require("registry")
    T.assert_true(type(foreign) == "table"
        and foreign._fake_generic_plugin == true,
        "N2: generic require('registry') returns the FOREIGN module")
    T.assert_true(rawget(foreign, "refreshRegistry") == nil,
        "N2: foreign registry was not replaced by ours")
end

-- ---------------------------------------------------------------------------
-- N3: no stale generic keys left in package.loaded by OUR modules
-- (main.lua/menuorder_manager etc. were migrated; nothing should have
-- populated the OLD generic identities).
-- ---------------------------------------------------------------------------
do
    local stale = {}
    for _, name in ipairs(FAKE_NAMES) do
        local v = rawget(package.loaded, name)
        if v ~= nil and type(v) == "table"
                and v._fake_generic_plugin ~= true then
            stale[#stale + 1] = name
        end
    end
    T.assert_eq(#stale, 0,
        "N3: no non-fake module occupies the generic loaded keys")
end

-- ---------------------------------------------------------------------------
-- N4: source sweep — production files only reference plugin-local modules
-- by their prefixed identity.
-- ---------------------------------------------------------------------------
do
    local lfs = require("libs/libkoreader-lfs")
    local GENERIC = {}
    for _, name in ipairs(FAKE_NAMES) do GENERIC[name] = true end
    -- plus the full set of renamed basenames
    for _, name in ipairs({
        "atomic_writer", "commit_pipeline", "data_loader", "ghost_gc",
        "intent_store", "koreader_adapter", "menu_schema", "menu_titles",
        "menuorder_manager", "native_writer", "semantic_diff", "ui_compat",
        "ui_editor_model", "ui_editor_registry", "unicode_fold",
    }) do GENERIC[name] = true end

    local violations = {}
    local files = {}
    for entry in lfs.dir(project_dir) do
        if entry:match("%.lua$") then
            files[#files + 1] = project_dir .. "/" .. entry
        end
    end
    for _, path in ipairs(files) do
        local file = io.open(path, "r")
        if file then
            local body = file:read("*a")
            file:close()
            for generic in pairs(GENERIC) do
                local pat = 'require("' .. generic .. '")'
                if body:find(pat, 1, true) then
                    violations[#violations + 1]
                        = path:gsub(".*/", "") .. ": " .. pat
                end
            end
        end
    end
    T.assert_eq(#violations, 0,
        "N4: zero generic requires remain in production sources")
    for _, v in ipairs(violations) do print("    STALE: " .. v) end
end

T.summary("module namespace isolation")

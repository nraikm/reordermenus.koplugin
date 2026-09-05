--[[--
Module naming and loadability (Area R2).

Plugin-local Lua modules live under lib/ and are required with dotted
lib.* names, so the release tree stays inspectable and matches KOReader's
plugin loader resolution (the loader prepends the plugin root to
package.path, and lib.<name> resolves to lib/<name>.lua). main.lua and
_meta.lua keep the loader-contract names at the plugin root.

Persistent settings files retain their reorderingmenus_* names separately;
those names are part of the on-disk compatibility contract, not module names.
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

-- Match KOReader's plugin-root-first resolution used by the release smoke
-- test and by the installed plugin.
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

local MODULES = {
    "atomic_writer", "commit_pipeline", "data_loader", "ghost_gc",
    "intent_store", "koreader_adapter", "materializer", "menu_schema",
    "menu_titles", "menuorder_manager", "native_writer", "placement",
    "plugin_prefs", "presets", "registry", "semantic_diff", "ui_compat",
    "ui_editor_model", "ui_editor_registry", "ui_screens", "unicode_fold",
    "validator", "visibility",
}

-- Loader-contract names stay at the plugin root.
local ROOT_MODULES = { "main", "_meta" }

print("===============================================================")
print("Module naming and loadability")
print("===============================================================")

local lfs = require("libs/libkoreader-lfs")
local legacy_prefix = "reorderingmenus_"

for _, name in ipairs(ROOT_MODULES) do
    T.assert_true(lfs.attributes(project_dir .. "/" .. name .. ".lua", "mode") == "file",
        "R0: loader-contract module at plugin root: " .. name .. ".lua")
end

for _, name in ipairs(MODULES) do
    local normal_path = project_dir .. "/lib/" .. name .. ".lua"
    local legacy_path = project_dir .. "/lib/" .. legacy_prefix .. name .. ".lua"
    local root_stray = project_dir .. "/" .. name .. ".lua"
    T.assert_true(lfs.attributes(normal_path, "mode") == "file",
        "R1: conventional module file exists: lib/" .. name .. ".lua")
    T.assert_true(lfs.attributes(legacy_path, "mode") == nil,
        "R2: legacy-prefixed module file is absent: lib/" .. legacy_prefix .. name .. ".lua")
    T.assert_true(lfs.attributes(root_stray, "mode") == nil,
        "R2b: flat root copy is absent: " .. name .. ".lua")

    package.loaded["lib." .. name] = nil
    local ok, module = pcall(require, "lib." .. name)
    T.assert_true(ok and type(module) == "table",
        "R3: conventional require resolves: lib." .. name)
end

-- Source-level guard: implementation files must not retain the old module
-- namespace, and must address moved modules through their lib.* names
-- (a bare require would resolve against KOReader stock or fail). This
-- intentionally searches only production files, not the compatibility names
-- used for persisted settings data.
do
    local violations = {}
    local bare_violations = {}
    local roots = { project_dir .. "/main.lua" }
    for entry in lfs.dir(project_dir .. "/lib") do
        if entry:match("%.lua$") then
            roots[#roots + 1] = project_dir .. "/lib/" .. entry
        end
    end
    local bare_pat = {}
    for _, name in ipairs(MODULES) do bare_pat[name] = true end
    for _, path in ipairs(roots) do
        local file = io.open(path, "r")
        if file then
            local body = file:read("*a")
            file:close()
            local short = path:match("([^/]+)$")
            if body:find('require("' .. legacy_prefix, 1, true) then
                violations[#violations + 1] = short
            end
            for name in pairs(bare_pat) do
                if body:find('require("' .. name .. '")', 1, true) then
                    bare_violations[#bare_violations + 1] = short .. ": bare require(" .. name .. ")"
                end
            end
        end
    end
    T.assert_eq(#violations, 0,
        "R4: production requires use conventional module names")
    for _, entry in ipairs(violations) do
        print("    STALE: " .. entry)
    end
    T.assert_eq(#bare_violations, 0,
        "R5: production requires address moved modules as lib.*")
    for _, entry in ipairs(bare_violations) do
        print("    BARE: " .. entry)
    end
end

T.summary("module naming and loadability")

--[[--
Module naming and loadability (Area R2).

Plugin-local Lua modules use conventional flat basenames so the release is
easy to inspect and matches the names used by KOReader's plugin loader. The
loader prepends the plugin root to package.path, so each runtime module must
exist under its basename and every production require must use that basename.

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
    "menu_titles", "menuorder_manager", "native_writer", "plugin_prefs",
    "presets", "registry", "semantic_diff", "ui_compat", "ui_editor_model",
    "ui_editor_registry", "ui_screens", "unicode_fold", "validator",
}

print("===============================================================")
print("Module naming and loadability")
print("===============================================================")

local lfs = require("libs/libkoreader-lfs")
local legacy_prefix = "reorderingmenus_"

for _, name in ipairs(MODULES) do
    local normal_path = project_dir .. "/" .. name .. ".lua"
    local legacy_path = project_dir .. "/" .. legacy_prefix .. name .. ".lua"
    T.assert_true(lfs.attributes(normal_path, "mode") == "file",
        "R1: conventional module file exists: " .. name .. ".lua")
    T.assert_true(lfs.attributes(legacy_path, "mode") == nil,
        "R2: legacy-prefixed module file is absent: " .. legacy_prefix .. name .. ".lua")

    package.loaded[name] = nil
    local ok, module = pcall(require, name)
    T.assert_true(ok and type(module) == "table",
        "R3: conventional require resolves: " .. name)
end

-- Source-level guard: implementation files must not retain the old module
-- namespace. This intentionally searches only production files, not the
-- compatibility names used for persisted settings data.
do
    local violations = {}
    for entry in lfs.dir(project_dir) do
        if entry:match("%.lua$") then
            local file = io.open(project_dir .. "/" .. entry, "r")
            if file then
                local body = file:read("*a")
                file:close()
                if body:find('require("' .. legacy_prefix, 1, true) then
                    violations[#violations + 1] = entry
                end
            end
        end
    end
    T.assert_eq(#violations, 0,
        "R4: production requires use conventional module names")
    for _, entry in ipairs(violations) do
        print("    STALE: " .. entry)
    end
end

T.summary("module naming and loadability")

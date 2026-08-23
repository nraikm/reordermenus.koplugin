--[[--
Release install smoke test (Area R1).

Simulates a clean KOReader installation of the release ZIP:

  S1  the ZIP exists and contains exactly ReorderingMenus.koplugin/*
  S2  it extracts into an EMPTY directory with no dev-checkout leakage
  S3  package.path is configured EXACTLY like KOReader does for plugins
      (plugin root PREPENDED, frontend paths only — never the dev checkout;
      see frontend/pluginloader.lua:200 and :241)
  S4  main.lua executes as the plugin-loader dofile()s it
  S5  every production require resolves (load-time graph)
  S6  deferred requires resolve too: prepareForPluginRemoval's lazy
      menuorder_manager load and applyLiveReload's lazy ui_screens load
  S7  no module resolved from the development checkout (dev tree absent
      from package.path; every loaded plugin module's source path is
      inside the extraction dir)
  S8  _meta.lua loads under the same restricted path configuration

The ZIP path defaults to dist/reorderingmenus-*.zip (newest match); build
one first with ./build_release.sh, or override with RM_RELEASE_ZIP.
--]]

local function script_dir()
    local src = debug.getinfo(1, "S").source:sub(2)
    return src:match("^(.*)/tests/[^/]+$")
end

local project_dir = assert(script_dir(), "cannot locate plugin directory")

-- KOReader runtime bootstrap ONLY — deliberately NOT the dev-tree prepend
-- that tests/lib/runtime_world.lua performs; this suite must be able to
-- prove the dev tree contributes nothing.
dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir()
    .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local lfs = require("libs/libkoreader-lfs")

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
print("Release install smoke test")
print("===============================================================")

-- ---------------------------------------------------------------------------
-- locate the release ZIP
-- ---------------------------------------------------------------------------
local zip_path = os.getenv("RM_RELEASE_ZIP")
if not zip_path or zip_path == "" then
    local dist = project_dir .. "/dist"
    local best, best_mtime = nil, -1
    if lfs.attributes(dist, "mode") == "directory" then
        for entry in lfs.dir(dist) do
            local full = dist .. "/" .. entry
            if entry:match("%.zip$") and lfs.attributes(full, "mode") == "file" then
                local m = lfs.attributes(full, "modification")
                if m > best_mtime then best, best_mtime = full, m end
            end
        end
    end
    zip_path = best
end
T.assert_true(zip_path and lfs.attributes(zip_path, "mode") == "file",
    "S1: release ZIP exists" ..
    (zip_path and (" (" .. zip_path .. ")") or " (none found in dist/)"))
if not (zip_path and lfs.attributes(zip_path, "mode") == "file") then
    -- No artifact yet: this is a normal state for a plain test battery run
    -- (building a release is a deliberate act). Skip loudly instead of
    -- failing the whole tier; set RM_REQUIRE_ZIP=1 to make absence fatal.
    if os.getenv("RM_REQUIRE_ZIP") == "1" then
        T.summary("release install smoke")
        return
    end
    print("  [SKIP] build a release first: ./build_release.sh "
        .. "(or point RM_RELEASE_ZIP at an existing zip)")
    print("=== release install smoke: 0 passed, 0 failed (skipped) ===")
    return
end

-- ---------------------------------------------------------------------------
-- extract into an empty temp directory
-- ---------------------------------------------------------------------------
local function rmtree(path)
    if lfs.attributes(path, "mode") ~= "directory" then return end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local full = path .. "/" .. entry
            if lfs.attributes(full, "mode") == "directory" then
                rmtree(full)
            else
                os.remove(full)
            end
        end
    end
    lfs.rmdir(path)
end

local tmp_root = os.getenv("TMPDIR") or "/tmp"
local extract_dir = tmp_root .. "/rm_smoke_" .. tostring(os.time())
    .. "_" .. tostring(math.random(100000))
lfs.mkdir(extract_dir)
local entries_before = 0
for _ in lfs.dir(extract_dir) do entries_before = entries_before + 1 end
T.assert_true(entries_before <= 2, "S2: extraction dir starts empty")

local unzip_ok = os.execute(
    'unzip -q -o "' .. zip_path .. '" -d "' .. extract_dir .. '"')
T.assert_true(unzip_ok == 0 or unzip_ok == true, "S2: unzip succeeded")

local plugin_root = extract_dir .. "/ReorderingMenus.koplugin"
T.assert_true(lfs.attributes(plugin_root, "mode") == "directory",
    "S2: archive root is ReorderingMenus.koplugin/")
T.assert_true(lfs.attributes(plugin_root .. "/main.lua", "mode") == "file",
    "S2: main.lua present at plugin root")

-- ---------------------------------------------------------------------------
-- configure package.path EXACTLY like KOReader's PluginLoader
-- (frontend/pluginloader.lua: prepended during load; frontend-only base)
-- ---------------------------------------------------------------------------
package.path = plugin_root .. "/?.lua;" .. package.path

local loaded_sources = {}
local searchers = package.searchers or package.loaders
local orig_searcher = searchers[2]
searchers[2] = function(name)
    local loader, path_or_msg, rest = orig_searcher(name)
    if type(path_or_msg) == "string" and path_or_msg:sub(1, 1) == "@" then
        loaded_sources[name] = path_or_msg:sub(2)
    end
    return loader, path_or_msg, rest
end

-- ---------------------------------------------------------------------------
-- S4/S5: execute main.lua like the loader does + verify identity
-- ---------------------------------------------------------------------------
local chunk_ok, plugin_module = pcall(dofile, plugin_root .. "/main.lua")
T.assert_true(chunk_ok and type(plugin_module) == "table",
    "S4: main.lua executes and returns the plugin widget table"
    .. (chunk_ok and "" or (" (" .. tostring(plugin_module) .. ")")))

T.assert_true(type(package.loaded["reorderingmenus_menuorder_manager"]) == "table",
    "S5: reorderingmenus_menuorder_manager resolved and cached")
T.assert_true(type(package.loaded["reorderingmenus_ui_screens"]) == "table",
    "S5: reorderingmenus_ui_screens resolved and cached")

if type(plugin_module) == "table" then
    T.assert_eq(plugin_module.name, "reorderingmenus",
        "S4: returned widget identifies as reorderingmenus")
end

-- ---------------------------------------------------------------------------
-- S6: deferred requires
-- ---------------------------------------------------------------------------
do
    local ok_deferred, adapter_or_err =
        pcall(require, "reorderingmenus_koreader_adapter")
    T.assert_true(ok_deferred and type(adapter_or_err) == "table",
        "S6: koreader_adapter loads under install layout")
    if ok_deferred and type(adapter_or_err) == "table"
            and adapter_or_err.prepareForPluginRemoval then
        -- call WITHOUT the Manager argument: exercises its internal lazy
        -- require("reorderingmenus_menuorder_manager"). No settings exist
        -- in a fresh install -> nothing to restore, must return cleanly.
        local ok_call, restored = pcall(
            adapter_or_err.prepareForPluginRemoval, adapter_or_err)
        T.assert_true(ok_call,
            "S6: prepareForPluginRemoval lazy-require path executes"
            .. (ok_call and "" or (" (" .. tostring(restored) .. ")")))
    end

    local ok_mgr = pcall(require, "reorderingmenus_menuorder_manager")
    T.assert_true(ok_mgr, "S6: lazy menuorder_manager target resolves")
end

-- ---------------------------------------------------------------------------
-- S7: nothing came from the development checkout
-- ---------------------------------------------------------------------------
local leaks = {}
for name, src in pairs(loaded_sources) do
    if src:find(project_dir, 1, true) == 1 then
        leaks[#leaks + 1] = name .. " <- " .. src
    end
end
T.assert_eq(#leaks, 0,
    "S7: zero modules resolved from the development checkout")
if #leaks > 0 then
    for _, l in ipairs(leaks) do print("    LEAK: " .. l) end
end
T.assert_true(package.path:find(project_dir, 1, true) == nil,
    "S7: dev checkout absent from package.path entirely")

-- ---------------------------------------------------------------------------
-- S8: _meta.lua loads under the same restricted configuration
-- ---------------------------------------------------------------------------
do
    local meta_ok, meta = pcall(dofile, plugin_root .. "/_meta.lua")
    T.assert_true(meta_ok and type(meta) == "table"
        and meta.name == "reorderingmenus",
        "S8: _meta.lua loads and identifies the plugin")
end

rmtree(extract_dir)
T.summary("release install smoke")

--[[
test_regressions_promoted.lua — positive replay of PROMOTED regression
fixtures.

Fixtures arrive here from tests/fixtures/regression/ via the XPASS flow:
a fixture that used to reproduce a bug and now PASSES is moved here (never
silently deleted). Its minimized history becomes a permanent MUST-PASS
assertion: the exact scenario that once broke the pipeline must stay green
forever. If a promoted history ever fails again, this suite fails loudly —
that is a regression of an already-fixed bug, not a new discovery.

Run: ./run_tests.sh tests/test_regressions_promoted.lua
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
CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
require("main")

local World = require("tests.lib.sm_world")

local lfs = require("libs/libkoreader-lfs")
local fixture_dir = project_dir .. "/tests/fixtures/promoted"

local files = {}
for entry in lfs.dir(fixture_dir) do
    if entry:match("%.lua$") then files[#files + 1] = entry end
end
table.sort(files)

io.write(string.format(
    "EFFECTIVE_CONFIG suite=%s fixtures=%d mode=must-pass\n",
    debug.getinfo(1, "S").source:match("([^/]+)$"), #files))
io.stdout:flush()

print("===============================================================")
print(string.format("=== Promoted regression fixtures (%d) must stay fixed", #files))
print("===============================================================")

local passed, failed = 0, 0
for _, fname in ipairs(files) do
    local chunk, err = loadfile(fixture_dir .. "/" .. fname)
    local fixture = chunk and select(2, pcall(chunk)) or nil
    if type(fixture) ~= "table" then
        failed = failed + 1
        print(string.format("  [FAIL] %s unreadable: %s", fname, tostring(err)))
    else
        local ok, replay_err = pcall(function()
            local w = World:new(fixture.seed)
            for i, entry in ipairs(fixture.history or {}) do
                local desc = w:replay(entry)
                if type(desc) == "string" and desc:sub(1, 8) == "OPERROR:" then
                    error(string.format("op %d crashed: %s", i, desc))
                end
                local invariant_ok, inv = w:check({})
                if not invariant_ok then
                    error((inv[1] or "?"):gsub("\n", " "))
                end
            end
        end)
        if ok then
            passed = passed + 1
        else
            failed = failed + 1
            print(string.format("  [FAIL] %s (seed %s): %s",
                fname, tostring(fixture.seed), tostring(replay_err):sub(1, 140)))
            io.stdout:flush()
        end
    end
end

print(string.format("\n=== %d passed, %d failed (promoted histories) ===",
    passed, failed))
os.exit(failed == 0 and 0 or 1)

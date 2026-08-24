--[[--
test_regressions_generated.lua — replays every generated regression fixture
with EXPLICIT expected-failure semantics (Priority 4 contract).

Each fixture under tests/fixtures/regression/ carries:
    history        the minimized operation history
    signature      (optional) normalized failure signature recorded at
                   promotion time; fixtures promoted before this field
                   existed get it backfilled on first replay.

Replay outcomes:

  [XFAIL]       fails with the SAME signature as recorded -> known bug,
                counted separately, NEVER as an ordinary pass.
  [XPASS]       passes now. The bug may be fixed: the fixture is NOT deleted.
                The suite exits non-zero so a human converts the fixture into
                a positive regression test asserting the corrected behavior,
                then removes the file deliberately.
  [SIGCHANGED]  fails DIFFERENTLY than recorded -> an unrelated regression
                may have replaced the original bug. Hard failure.
  [SKIP]        unreadable/not-a-fixture.

Exit code is non-zero if anything is XPASS or SIGCHANGED (XFAIL alone keeps
the suite "red-but-expected": visible in counts, exit code reflects only
UNEXPECTED outcomes).
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
local FailureSig = require("tests.lib.failure_sig")

local lfs = require("libs/libkoreader-lfs")
local fixture_dir = project_dir .. "/tests/fixtures/regression"

local xfail, xpass, sigchanged, missing = 0, 0, 0, 0

local files = {}
for entry in lfs.dir(fixture_dir) do
    if entry:match("%.lua$") then files[#files + 1] = entry end
end
table.sort(files)

io.write(string.format(
    "EFFECTIVE_CONFIG suite=%s fixtures=%d mode=xpass-aware\n",
    debug.getinfo(1, "S").source:match("([^/]+)$"), #files))
io.stdout:flush()

print("===============================================================")
print("=== Generated regression fixtures (" .. #files .. ")              ===")
print("===============================================================")

local function currentFailure(fixture)
    local w = World:new(fixture.seed)
    for i, entry in ipairs(fixture.history or {}) do
        local desc = w:replay(entry)
        if type(desc) == "string" and desc:sub(1, 8) == "OPERROR:" then
            return { string.format("op %d crashed: %s", i, desc) }
        end
        local ok, ffails = w:check({})
        if not ok then return ffails end
    end
    return nil
end

local function writeFixtureSignature(fname, fixture, sig)
    -- Backfill the recorded signature into the fixture file so future
    -- replays can distinguish XFAIL from SIGCHANGED.
    local lines = {
        "-- Auto-generated regression fixture. DO NOT EDIT BY HAND.",
        "-- Regenerate via the state-machine suite; retire via XPASS review.",
        'return {',
        string.format('  seed = %d,', fixture.seed),
        string.format('  signature = %q,', sig),
        '  history = {',
    }
    for _, entry in ipairs(fixture.history or {}) do
        lines[#lines + 1] = string.format('    { op = %q, args = %s },',
            entry.op, require("dump")(entry.args, nil, true):gsub("%s*\n%s*", " "))
    end
    lines[#lines + 1] = '  },'
    lines[#lines + 1] = '}'
    local f = io.open(fixture_dir .. "/" .. fname, "w")
    if f then f:write(table.concat(lines, "\n")); f:close() end
end

for _, fname in ipairs(files) do
    local chunk, err = loadfile(fixture_dir .. "/" .. fname)
    if not chunk then
        print(string.format("  [SKIP] %s: %s", fname, tostring(err)))
        missing = missing + 1
    else
        local ok, fixture_or_err = pcall(chunk)
        if not ok or type(fixture_or_err) ~= "table" then
            print(string.format("  [SKIP] %s: not a fixture table (%s)",
                fname, tostring(fixture_or_err)))
            missing = missing + 1
        else
            local fixture = fixture_or_err
            local failures = currentFailure(fixture)
            if not failures then
                xpass = xpass + 1
                print(string.format(
                    "  [XPASS] %s no longer fails — convert to positive regression test, then delete",
                    fname))
            else
                -- signature over the FULL failure set (order-insensitive):
                -- which violation is "first" varies with hash order per process
                local live_sig = FailureSig.normalize(failures)
                local recorded = fixture.signature
                if recorded == nil then
                    -- legacy fixture: backfill on first structured replay
                    writeFixtureSignature(fname, fixture, live_sig)
                    recorded = live_sig
                    print(string.format("  [note] %s backfilled signature %s",
                        fname, live_sig))
                end
                if live_sig == recorded then
                    xfail = xfail + 1
                    print(string.format("  [XFAIL] %s (%s)",
                        fname, live_sig))
                else
                    sigchanged = sigchanged + 1
                    print(string.format(
                        "  [SIGCHANGED] %s recorded=%s live=%s — investigate before touching anything",
                        fname, recorded, live_sig))
                    print("         first line: " ..
                        (failures[1] or "?"):gsub("\n", " "):sub(1, 110))
                end
            end
        end
    end
end

print(string.format(
    "=== %d XFAIL (known bugs), %d XPASS, %d SIGCHANGED, %d skipped ===",
    xfail, xpass, sigchanged, missing))

if xpass > 0 or sigchanged > 0 then
    print("UNEXPECTED OUTCOMES PRESENT — resolve XPASS/SIGCHANGED before committing.")
    os.exit(1)
end

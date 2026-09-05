--[[--
Manager-verb state machine over the full intent alphabet.

Every operation goes through menuorder_manager (the same write path the
UI uses), then a battery of global invariants runs against the live
projection and the real MenuSorter. Failures are automatically minimized
with ddmin (tests/lib/shrinker.lua) and promoted to executable fixtures
under tests/fixtures/regression/, replayed forever by
test_regressions_generated.lua.

Tier knobs (SM_SEEDS / SM_STEPS), mirroring the first-generation suite:

    quick/PR   : 6 x 60     (~seconds)
    normal CI  : SM_SEEDS=20 SM_STEPS=200
    nightly    : SM_SEEDS=100 SM_STEPS=500
    soak       : SM_SEEDS=500 SM_STEPS=1000

SM_RESTART_EVERY=N additionally forces an I8 restart-equivalence check
every N steps (costly: reloads both sessions).
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

local World = require("tests.lib.sm_world")
local Shrinker = require("tests.lib.shrinker")
local Manager = require("lib.menuorder_manager")
local IntentStore = require("lib.intent_store")

local passed, failed = 0, 0
local function note(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("  [FAIL] " .. tostring(msg))
        io.stdout:flush()
    end
end

print("===============================================================")
print("=== Manager-verb state machine (full intent alphabet)       ===")
print("===============================================================")

local SEEDS = tonumber(os.getenv("SM_SEEDS")) or 6
local STEPS = tonumber(os.getenv("SM_STEPS")) or 60
local RESTART_EVERY = tonumber(os.getenv("SM_RESTART_EVERY")) or 25

-- P0-C: seed-bank replay — SM_SEED_LIST="7919,15838,..." overrides 1..SEEDS.
local SEED_LIST = nil
if os.getenv("SM_SEED_LIST") and os.getenv("SM_SEED_LIST"):match("%S") then
    SEED_LIST = {}
    for n in os.getenv("SM_SEED_LIST"):gmatch("%d+") do
        table.insert(SEED_LIST, tonumber(n))
    end
    assert(#SEED_LIST > 0, "SM_SEED_LIST set but parsed to zero seeds")
end

-- P0-A: effective configuration banner; run_tests.sh verifies this against
-- the requested tier so a silently-downgraded run is impossible.
io.write(string.format(
    "EFFECTIVE_CONFIG suite=%s gen=2 seeds=%d steps=%d restart_every=%d seed_list=%s\n",
    debug.getinfo(1, "S").source:match("([^/]+)$"),
    SEED_LIST and #SEED_LIST or SEEDS, STEPS, RESTART_EVERY,
    SEED_LIST and table.concat(SEED_LIST, "+") or tostring(SEEDS)))
io.stdout:flush()

local fixture_dir = project_dir .. "/tests/fixtures/regression"
os.execute("mkdir -p '" .. fixture_dir .. "'")

-- Reproduce a recorded history against a fresh world; return failures or nil.
local function reproduce(seed, history)
    local w = World:new(seed)
    for i, entry in ipairs(history) do
        local desc = w:replay(entry)
        if type(desc) == "string" and desc:sub(1, 8) == "OPERROR:" then
            return { string.format("op %d (%s) crashed: %s",
                i, entry.op, desc), w }
        end
        local ok, failures = w:check({})
        if not ok then
            return { table.concat(failures, "; "), w }
        end
    end
    return nil
end

for seed_run = 1, SEED_LIST and #SEED_LIST or SEEDS do
    local seed = SEED_LIST and SEED_LIST[seed_run] or (seed_run * 7919)
    local w = World:new(seed)
    local run_failed = false
    for step = 1, STEPS do
        local opname, args, desc = w:step()
        local check_opts = {}
        if opname == "restart" or (RESTART_EVERY > 0 and step % RESTART_EVERY == 0) then
            check_opts.restart_check = true
        end
        -- I17: capture pre-fault canonical bytes; after an injected IO fault
        -- the ROLLED-BACK IN-MEMORY canonical must equal them (S11/S12
        -- contract: failed durable write leaves canonical untouched). We
        -- deliberately do NOT drop sessions or reload from disk here: that
        -- would model a process restart, which discards every view's staged
        -- state symmetrically - not part of this scenario.
        local pre_fault_fp
        if opname == "io_fault_save" then
            w:check(check_opts) -- advance to a consistent state first
            pre_fault_fp = w:preFaultFingerprint()
        end
        local ok, failures = w:check(check_opts)
        -- I18 tab-bar sanity rides on every step
        for _, f in ipairs(w:tabBarCheck()) do
            failures = failures or {}
            failures[#failures + 1] = f
        end
        if opname == "io_fault_save" and ok and args ~= nil then
            if w:preFaultFingerprint() ~= pre_fault_fp then
                failures = failures or {}
                failures[#failures + 1] =
                    "I17 failed commit changed canonical state (rollback violated)"
            end
        end
        -- I9/I11 ride on save operations
        if opname == "save_order" and args ~= nil and ok then
            local fixpoint_failures = w:nativeFixpointCheck()
            for _, f in ipairs(fixpoint_failures) do
                failures = failures or {}
                failures[#failures + 1] = f
            end
            local ser_failures = w:serializationDeterminismCheck()
            for _, f in ipairs(ser_failures) do
                failures = failures or {}
                failures[#failures + 1] = f
            end
        end
        if not ok or (type(desc) == "string" and desc:sub(1, 8) == "OPERROR:") then
            failed = failed + 1
            print(string.format("\n  [FAIL] seed=%d step=%d [%s %s]",
                seed, step, opname, tostring(desc)))
            for _, f in ipairs(failures or { "operation crashed" }) do
                print("         " .. f)
            end
            io.stdout:flush()
            -- ---- automatic shrinking + fixture promotion ----
            local shrunk, replays, reproduced =
                Shrinker.shrink(seed, w.history, reproduce, 300)
            if reproduced then
                print(string.format(
                    "         shrunk %d -> %d ops (%d replays)",
                    #w.history, #shrunk, replays))
                for _, entry in ipairs(shrunk) do
                    print(string.format("           - %s %s", entry.op,
                        World.fingerprint(entry.args)))
                end
                -- P4: verify the SHRUNK history still fails and record the
                -- normalized failure signature so replay can tell XFAIL
                -- (same bug) from SIGCHANGED (different bug) later.
                local shrunk_failures = reproduce(seed, shrunk)
                -- full-set signature (order-insensitive across processes)
                local live_sig = require("tests.lib.failure_sig").normalize(
                    shrunk_failures or failures or { "unknown failure" })
                local fname = string.format("%s/seed-%d-step-%d-%s.lua",
                    fixture_dir, seed, step, opname)
                local lines = {
                    "-- Auto-generated regression fixture. DO NOT EDIT BY HAND.",
                    "-- Regenerate via the state-machine suite; retire via XPASS review.",
                    "return {",
                    string.format("  seed = %d,", seed),
                    string.format("  signature = %q,", live_sig),
                    "  history = {",
                }
                for _, entry in ipairs(shrunk) do
                    lines[#lines + 1] = string.format('    { op = %q, args = %s },',
                        entry.op, require("dump")(entry.args, nil, true)
                            :gsub("%s*\n%s*", " "))
                end
                lines[#lines + 1] = "  },"
                lines[#lines + 1] = "}"
                local g = io.open(fname, "w")
                g:write(table.concat(lines, "\n"))
                g:close()
                print(string.format(
                    "         fixture promoted: tests/fixtures/regression/%s (sig %s)",
                    fname:match("([^/]+)$"), live_sig))
            else
                print("         (shrinking did not reproduce; keeping full history)")
            end
            io.stdout:flush()
            run_failed = true
            break
        end
        passed = passed + 1
    end
    if not run_failed then
        print(string.format("  seed %d: %d steps clean (%d ops executed)",
            seed, STEPS, w.op_counter))
    end
    io.stdout:flush()
end

print(string.format("\n=== %d checks passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

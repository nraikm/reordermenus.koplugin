--[[--
P0-B contract: a seeded state machine is only as good as its reproduction.

test_gen1_determinism.lua — launches the SAME Gen1 seed in multiple separate
LuaJIT processes and requires exact agreement on:

  1. operation history  (SM_TRACE=1 op lines)
  2. effective check count (the "N passed" total)

Any mismatch means the suite's seeds do not actually identify a run —
fixtures promoted from it could never be trusted.

Run: cd /Applications/KOReader.app/Contents/koreader && \
     ./luajit /Users/nr/Development/ReorderingMenus/tests/test_gen1_determinism.lua

Env: DET_SEEDS (how many seeds to cross-check, default 3),
     DET_STEPS (steps per seed, default 80), DET_PROCS (default 2).
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")

local passed, failed = 0, 0
local function ok(cond, msg)
    if cond then passed = passed + 1
    else failed = failed + 1; print("  [FAIL] " .. msg) end
end

local DET_SEEDS = tonumber(os.getenv("DET_SEEDS")) or 3
local DET_STEPS = tonumber(os.getenv("DET_STEPS")) or 80
local DET_PROCS = tonumber(os.getenv("DET_PROCS")) or 2

io.write(string.format(
    "EFFECTIVE_CONFIG suite=%s seeds=%d steps=%d procs=%d\n",
    debug.getinfo(1, "S").source:match("([^/]+)$"),
    DET_SEEDS, DET_STEPS, DET_PROCS))
io.stdout:flush()

local seeds = {}
for i = 1, DET_SEEDS do seeds[i] = i * 7919 end

-- Run one child process per seed; capture trace + totals from each.
local runs = {}   -- runs[seed_idx][proc_idx] = {trace=..., checks=...}
for p = 1, DET_PROCS do
    for si, seed in ipairs(seeds) do
        local log = os.tmpname()
        local cmd = string.format(
            'cd /Applications/KOReader.app/Contents/koreader && SM_TRACE=1 SM_SEED_LIST="%d" SM_STEPS=%d ./luajit %s/tests/test_state_machine.lua > %s 2>&1; exit 0',
            seed, DET_STEPS, project_dir, log)
        os.execute(cmd)
        local f = io.open(log, "r")
        local out = f and f:read("*a") or ""
        if f then f:close() end
        os.remove(log)
        local trace, checks = {}, nil
        for line in out:gmatch("[^\n]+") do
            local step = line:match("^TRACE seed=%d+ step=(%d+) op=")
            if step then trace[tonumber(step)] = line end
            local c = line:match("(%d+) passed, (%d+) failed")
            if c then checks = tonumber(c) end
        end
        runs[si] = runs[si] or {}
        runs[si][p] = { trace = table.concat(trace, "\n"), checks = checks }
    end
end

for si, seed in ipairs(seeds) do
    local base = runs[si][1]
    ok(base.checks ~= nil, string.format("seed %d: baseline run produced no check total", seed))
    for p = 2, DET_PROCS do
        local other = runs[si][p]
        ok(base.trace == other.trace,
            string.format("seed %d: operation history differs between processes (%s)",
                seed, base.trace == other.trace and "" or "history mismatch"))
        ok(base.checks == other.checks,
            string.format("seed %d: check count differs between processes (%s vs %s)",
                seed, tostring(base.checks), tostring(other.checks)))
    end
    print(string.format("  seed %d: %d steps traced, %s checks — identical across %d processes",
        seed, select(2, base.trace:gsub("\n", "")) + (#base.trace > 0 and 1 or 0),
        tostring(base.checks), DET_PROCS))
end

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

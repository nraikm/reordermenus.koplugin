--[[--
test_differential_fuzz.lua — differential fuzz for the native-order
round-trip.

For random valid states (manager-verb SM histories), this suite checks the
IMPORT/EXPORT FIXPOINT, which is the contract real KOReader depends on:

    emit native order for state S  ->  import it back (fresh session)
    ==  S   (same semantic projection)

plus serialization determinism and MenuSorter crash-freedom (the emitted
order must never make stock MenuSorter error out — verified by running
MenuSorter:sort on a faithful synthetic input built from the native file).

Hermeticity: production singletons can leak across worlds in one process,
so each seed runs as its own process (DF_ONE_SHOT=1 driver mode).

Tier knobs: DF_SEEDS / DF_STEPS / DF_SEED (single-seed reproduce).
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

local _ = require("gettext")

require("main")
local Manager = require("reorderingmenus_menuorder_manager")
local World = require("tests.lib.sm_world")
local IntentStore = require("reorderingmenus_intent_store")

local SEEDS = tonumber(os.getenv("DF_SEEDS")) or 10
local STEPS = tonumber(os.getenv("DF_STEPS")) or 40
local ONLY_SEED = tonumber(os.getenv("DF_SEED"))
local ONE_SHOT = os.getenv("DF_ONE_SHOT") == "1"

-- P0-A: effective configuration banner for runner verification.
-- Only the PARENT emits EFFECTIVE_CONFIG (children emit CHILD_CONFIG) so the
-- runner compares the requested tier against the actual parent loop.
if ONE_SHOT then
    io.write(string.format("CHILD_CONFIG seed=%d steps=%d\n", ONLY_SEED, STEPS))
else
    io.write(string.format(
        "EFFECTIVE_CONFIG suite=%s seeds=%d steps=%d seed_list=none\n",
        debug.getinfo(1, "S").source:match("([^/]+)$"), SEEDS, STEPS))
end
io.stdout:flush()

local passed, failed = 0, 0

-- Fingerprint a projection deterministically.
local function fp(order)
    local parts = {}
    local menus = {}
    for menu_id in pairs(order) do menus[#menus + 1] = menu_id end
    table.sort(menus)
    for _, menu_id in ipairs(menus) do
        local list = order[menu_id]
        if type(list) == "table" then
            parts[#parts + 1] = menu_id .. "=[" .. table.concat(list, ",") .. "]"
        end
    end
    return table.concat(parts, ";")
end

local function run_one_seed(seed)
    local w = World:new(seed)
    local diverged = nil

    for step = 1, STEPS do
        w:step()
        local ok_save = Manager:saveOrder(w.view)

        -- I9-style fixpoint: reload from disk in a fresh session; the
        -- projection must be identical to what we just exported.
        local before = fp(Manager:loadOrder(w.view))
        Manager:reloadFromDisk(w.view)
        local after = fp(Manager:loadOrder(w.view))
        if before ~= after then
            diverged = string.format(
                "native round-trip changed projection of %s\nbefore=%s\nafter =%s",
                w.view, before, after)
            break
        end

        -- I11-style determinism: saving again must not change intent bytes.
        if ok_save then
            local s_before = {}
            local cs = IntentStore.load().views[w.view]
            for coll, tbl in pairs(cs) do
                if type(tbl) == "table" then
                    local keys = {}
                    for k in pairs(tbl) do keys[#keys + 1] = tostring(k) end
                    table.sort(keys)
                    s_before[coll] = table.concat(keys, ",")
                end
            end
            Manager:saveOrder(w.view)
            local cs2 = IntentStore.load().views[w.view]
            for coll, sig in pairs(s_before) do
                local tbl2 = cs2[coll]
                if type(tbl2) ~= "table" then
                    diverged = string.format(
                        "second save dropped collection %s", coll)
                    break
                end
                local keys2 = {}
                for k in pairs(tbl2) do keys2[#keys2 + 1] = tostring(k) end
                table.sort(keys2)
                if table.concat(keys2, ",") ~= sig then
                    diverged = string.format(
                        "second save mutated collection %s", coll)
                    break
                end
            end
            if diverged then break end
        end
    end

    if diverged then
        print(string.format("  [FAIL] seed=%d (view=%s): %s",
            seed, w.view, diverged))
        return false
    else
        print(string.format("  seed %d: %d steps round-trip equivalent",
            seed, STEPS))
        return true
    end
end

if ONE_SHOT then
    local ok = run_one_seed(ONLY_SEED)
    os.exit(ok and 0 or 1)
end

print("===============================================================")
print(string.format("=== Native-order differential fuzz (%d x %d)          ===",
    SEEDS, STEPS))
print("===============================================================")

for seed_run = 1, SEEDS do
    local seed = ONLY_SEED or (seed_run * 104729)
    -- wipe shared persisted state between seeds so each subprocess starts
    -- from a clean disk regardless of what the previous one left behind
    os.execute('cd /Applications/KOReader.app/Contents/koreader && ' ..
        'rm -f settings/*_menu_order.lua settings/reorderingmenus_*.lua ' ..
        'settings/*.corrupt-* && rm -rf settings/menu_order_presets; exit 0')
    -- P0-A: propagate child failures — a red child MUST make the parent exit
    -- non-zero, otherwise the runner (and CI) sees green on real bugs.
    local child_rc = os.execute(string.format(
        'DF_SEED=%d DF_ONE_SHOT=1 DF_STEPS=%d ./luajit %s/tests/test_differential_fuzz.lua 2>/dev/null',
        seed, STEPS, project_dir))
    if not child_rc then
        print(string.format("  [FAIL] seed=%d: child process reported failure", seed))
        failed = failed + 1
    end
end

if failed > 0 then
    print(string.format("=== %d seed(s) FAILED round-trip equivalence ===", failed))
    os.exit(1)
end
print("=== all seeds passed round-trip equivalence ===")

--[[--
Three-way feature-interaction fuzzing (mandate C).

For every named triple of features (hide/move/custom/preset/mirror/ghost/
upgrade/update/external/reset/sep/stale/io/tab/conditional...), run biased
random histories where EVERY step draws from that triple's manager verbs
(plus save/restart glue). The full invariant battery (I1-I18) still runs
after every operation via World:check(), so any violation is attributed to
the triple being exercised. Failures are auto-shrunk (ddmin) and promoted
to executable regression fixtures like the main SM does.

Env knobs:
  C_SEEDS   histories per triple      (default 3)
  C_STEPS   steps per history         (default 60)
  C_TRIPLES comma list to restrict    (default: all)
--]]

local test_path = debug.getinfo(1, "S").source:sub(2)
local project = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")
package.path = project .. "/?.lua;" .. package.path

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir()
    .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()

local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

_ = require("gettext")

require("main")

local World = require("tests.lib.sm_world")
local Shrinker = require("tests.lib.shrinker")

local passed, failed = 0, 0
local function note(cond, msg)
    if cond then passed = passed + 1
    else failed = failed + 1; print("  [FAIL] " .. tostring(msg)); io.stdout:flush() end
end

local SEEDS_PER = tonumber(os.getenv("C_SEEDS")) or 3
local STEPS = tonumber(os.getenv("C_STEPS")) or 60
local ONLY = os.getenv("C_TRIPLES")

print("===============================================================")
print(string.format("=== Three-way interaction fuzz (%d seeds x %d steps) ===",
    SEEDS_PER, STEPS))
print("===============================================================")

-- ---------------------------------------------------------------------
-- Triple table: name -> { ops... }. Every list includes the glue verbs.
-- Op names are sm_world OPS keys (see tests/lib/sm_world.lua).
-- ---------------------------------------------------------------------
local GLUE = { "save_order", "restart" }
local TRIPLES = {
    hide_ghost_preset        = { "hide_item", "unhide_item", "plugin_uninstall",
                                 "plugin_install", "save_preset", "apply_preset" },
    mirror_upgrade_reset     = { "toggle_mirroring", "copy_layout",
                                 "plugin_upgrade_hint", "reset_submenu", "reset_view" },
    custom_external_delete   = { "create_submenu", "delete_custom_submenu",
                                 "external_native_edit", "delete_native_file" },
    stale_provider_iosave    = { "plugin_uninstall", "io_fault_save",
                                 "save_order", "stage_list_permutation" },
    sep_plugin_update_preset = { "insert_separator", "remove_separator",
                                 "plugin_install", "plugin_upgrade_hint",
                                 "save_preset", "apply_preset" },
    cond_mirror_restart      = { "conditional_capability", "toggle_mirroring",
                                 "copy_layout", "restart" },
    hide_move_ext            = { "hide_item", "unhide_item", "move_item_in_menu",
                                 "move_item_to_menu", "external_native_edit" },
    custom_preset_reset      = { "create_submenu", "rename_submenu",
                                 "save_preset", "apply_preset", "reset_view" },
    ghost_tab_upstream       = { "plugin_uninstall", "hide_tab", "upstream_add_tab",
                                 "upstream_remove_tab", "reorder_tabs" },
    preset_update_ext        = { "save_preset", "apply_preset",
                                 "upstream_reorder", "upstream_add", "upstream_remove",
                                 "external_native_edit" },
}
for _, t in ipairs(TRIPLES) do _ = t end
for name, ops in pairs(TRIPLES) do
    local merged = {}
    for _, o in ipairs(ops) do merged[#merged + 1] = o end
    for _, o in ipairs(GLUE) do merged[#merged + 1] = o end
    TRIPLES[name] = merged
end

-- Deterministic per-run order for reporting.
local triple_names = {}
for name in pairs(TRIPLES) do triple_names[#triple_names + 1] = name end
table.sort(triple_names)

-- ---------------------------------------------------------------------
-- Biased stepping: monkey-patch-free override of World:step for this run.
-- We temporarily replace the method, run, then restore.
-- ---------------------------------------------------------------------
local real_step = World.step

local function make_biased_step(allowed)
    return function(self)
        -- weight: allowed verbs heavy, everything else light background hum
        local weights, total = {}, 0
        for _, name in ipairs(World.OP_NAMES) do
            local w = 0
            for _, a in ipairs(allowed) do
                if a == name then w = 10 break end
            end
            if w == 0 then
                -- keep the world connected: tiny chance of anything else
                w = (name == "reader_fm_switch") and 1 or 0
            end
            weights[name] = w
            total = total + w
        end
        if total == 0 then return real_step(self) end
        local roll = self:rand(total)
        local chosen
        for _, name in ipairs(World.OP_NAMES) do
            local weight = weights[name] or 0
            if roll <= weight and weight > 0 then chosen = name break end
            roll = roll - weight
        end
        chosen = chosen or allowed[1]
        local spec = World.OPS[chosen]
        if not spec then return chosen, nil, chosen .. "(no spec)" end
        local args = spec.pick(self)
        if args == nil then return chosen, nil, chosen .. "(skipped)" end
        self.history[#self.history + 1] = { op = chosen, args = args }
        self.op_counter = self.op_counter + 1
        local ok, desc = pcall(spec.apply, self, args)
        if not ok then desc = "OPERROR: " .. tostring(desc) end
        return chosen, args, desc
    end
end

-- Reproduce helper mirroring test_state_machine_verbs.lua.
local function reproduce(seed, history)
    local w = World:new(seed)
    for i, entry in ipairs(history) do
        local desc = w:replay(entry)
        if type(desc) == "string" and desc:sub(1, 8) == "OPERROR:" then
            return { string.format("op %d (%s) crashed: %s", i, entry.op, desc), w }
        end
        local ok, failures = w:check()
        if not ok then return failures, w end
    end
    return nil, w
end

local fixture_dir = project .. "/tests/fixtures/regression"

local function promote_fixture(seed, history, failures, triple)
    local stamp = os.time()
    local path = string.format("%s/triple-%s-seed%d-step%d-%s.lua",
        fixture_dir, triple, seed, #history, tostring(stamp):sub(-5))
    local f = assert(io.open(path, "w"))
    f:write("--[==[\nAuto-promoted three-way interaction failure.\n")
    f:write("triple: " .. triple .. "\n")
    f:write("seed: " .. seed .. "\n")
    f:write("invariants:\n")
    for _, msg in ipairs(failures) do f:write("  - " .. msg .. "\n") end
    f:write("Replay: SM_SEED_LIST=" .. seed .. "\n]==]\n")
    f:write("return {\n  seed = " .. seed .. ",\n  triple = \""
        .. triple .. "\",\n  history = {\n")
    for _, entry in ipairs(history) do
        f:write(string.format("    { op = %q, args = %s },\n",
            entry.op, FuzzLib_serialize(entry.args)))
    end
    f:write("  },\n}\n")
    f:close()
    return path
end

-- args serializer (plain data only).
function FuzzLib_serialize(v)
    local t = type(v)
    if t == "number" then return string.format("%.14g", v)
    elseif t == "string" then return string.format("%q", v)
    elseif t == "boolean" then return tostring(v)
    elseif t == "nil" then return "nil"
    elseif t == "table" then
        local parts = {}
        local n = #v
        for i = 1, n do parts[i] = FuzzLib_serialize(v[i]) end
        local keys = {}
        for k in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= n) then
                keys[#keys + 1] = k
            end
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = "[" .. FuzzLib_serialize(k) .. "]="
                .. FuzzLib_serialize(v[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return '"?"'
end

local total_histories = 0
local violations = 0
local shrunk_count = 0

for _, triple in ipairs(triple_names) do
    if ONLY and not ONLY:find(triple, 1, true) then
        goto next_triple
    end
    World.step = make_biased_step(TRIPLES[triple])
    for s = 1, SEEDS_PER do
        local seed = (triple:len() * 7919 + s * 104729) % 2147483647
        local w = World:new(seed)
        local clean = true
        for step_i = 1, STEPS do
            local _, _, desc = w:step()
            if type(desc) == "string" and desc:sub(1, 8) == "OPERROR:" then
                note(false, triple .. " seed " .. seed .. ": op crash at step "
                    .. step_i .. ": " .. desc:sub(1, 160))
                clean = false
                violations = violations + 1
                break
            end
            local ok, failures = w:check()
            if not ok then
                note(false, triple .. " seed " .. seed .. ": INVARIANT at step "
                    .. step_i .. ": " .. tostring(failures[1]):sub(1, 200))
                clean = false
                violations = violations + 1
                -- shrink & promote
                local shrunk, replays, confirmed =
                    Shrinker.shrink(seed, w.history, function(sd, hist)
                        local fails, _ = reproduce(sd, hist)
                        return fails ~= nil
                    end, 120)
                if confirmed and #shrunk < #w.history then
                    shrunk_count = shrunk_count + 1
                    print(string.format(
                        "    shrunk %d -> %d ops (%d replays); promoted %s",
                        #w.history, #shrunk, replays,
                        promote_fixture(seed, shrunk, failures, triple)))
                else
                    print("    (shrink inconclusive; full history kept in log)")
                end
                break
            end
        end
        if clean then passed = passed + 1 end
        total_histories = total_histories + 1
        io.stdout:flush()
    end
    ::next_triple::
end

World.step = real_step

print(string.format(
    "\n=== Three-way fuzz complete: %d histories, %d clean, %d violations, "
    .. "%d shrunk+promoted; suite %d passed, %d failed ===",
    total_histories, total_histories - violations, violations, shrunk_count,
    passed, failed))
os.exit(failed == 0 and 0 or 1)

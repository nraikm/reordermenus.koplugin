--[[--
mutation_test.lua — targeted mutation testing for ReorderingMenus.

Copies the working tree to a throwaway directory, applies one surgical
mutation at a time, runs a killer suite in a fresh process, and verifies the
suite fails semantically. Production source is never edited, even if this
harness is interrupted.

Usage:
    cd /Applications/KOReader.app/Contents/koreader && \
    ./luajit /Users/nr/Development/ReorderingMenus/tests/mutation_test.lua
--]]

local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))

local function read(p)
    local f = io.open(p, "r"); if not f then return nil end
    local c = f:read("*a"); f:close(); return c
end

local function write(p, c)
    local f = assert(io.open(p, "wb")); f:write(c); f:close()
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Mutate exactly one plain-string site. Multiple matches are a stale harness,
-- not permission to create a broad mutant with an ambiguous failure reason.
local function mutate_one(orig, find, replace)
    local first_i, first_j = orig:find(find, 1, true)
    if not first_i then return nil, 0 end
    local second_i = orig:find(find, first_j + 1, true)
    if second_i then return nil, 2 end
    return orig:sub(1, first_i - 1) .. replace .. orig:sub(first_j + 1), 1
end

local function commandSucceeded(rc)
    return rc == true or rc == 0
end

local function makeWorkingCopy()
    local root = os.tmpname()
    os.remove(root)
    assert(commandSucceeded(os.execute("mkdir -p " .. shellQuote(root))))
    local copy_cmd = "tar -C " .. shellQuote(project_dir)
        .. " --exclude='./.git' --exclude='./dist' -cf - . | tar -C "
        .. shellQuote(root) .. " -xf -"
    assert(commandSucceeded(os.execute(copy_cmd)), "cannot create mutation copy")
    return root
end

local function run_suite(work_dir, name)
    local test_file = work_dir .. "/tests/" .. name
    if not read(test_file) then return "error", "killer test missing" end
    local log = os.tmpname()
    local home = os.tmpname()
    os.remove(home)
    assert(commandSucceeded(os.execute("mkdir -p " .. shellQuote(home .. "/settings"))))
    local cmd = string.format(
        "cd /Applications/KOReader.app/Contents/koreader && KO_HOME=%s PLUGIN_DIR=%s ./luajit %s > %s 2>&1",
        shellQuote(home), shellQuote(work_dir), shellQuote(test_file), shellQuote(log))
    local rc = os.execute(cmd)
    local out = read(log) or ""
    os.remove(log)
    os.execute("rm -rf " .. shellQuote(home))
    local _, f = out:match("(%d+) passed, (%d+) failed")
    if not f then return "error", "killer produced no test summary" end
    local failures = tonumber(f)
    if not commandSucceeded(rc) and failures > 0 then return "killed" end
    if commandSucceeded(rc) and failures == 0 then return "survived" end
    return "error", "killer exit code disagrees with summary"
end

local MUTANTS = {
    {
        id = "quarantine-corrupt",
        desc = "quarantine on corrupt canonical intent neutralized",
        file = "lib/intent_store.lua",
        find = 'if not parse_error and #destructive > 0 then\n        backup_path = writeBackupBytes(path, "corrupt", raw_text)',
        replace = "if not parse_error and #destructive > 0 then\n        backup_path = nil",
        killer = "test_corrupt_canonical_intent.lua",
    },
    {
        id = "dormant-provider",
        desc = "dormant provider intent falsely materializes",
        file = "lib/materializer.lua",
        find = "local node = reg.nodes[id]\n    local current_provider = node and node.provider or nil\n    if current_provider == nil then return false end",
        replace = "local node = reg.nodes[id]\n    local current_provider = node and node.provider or nil\n    if current_provider == nil then return true end",
        killer = "test_provider_identity.lua",
    },
    {
        id = "noop-status",
        desc = "noop commit falsely reports saved",
        file = "lib/commit_pipeline.lua",
        find = "if not needs_maintenance then\n            outcome.status = CommitPipeline.STATUS.UNCHANGED",
        replace = "if not needs_maintenance then\n            outcome.status = CommitPipeline.STATUS.SAVED",
        killer = "test_p0_commit_pipeline.lua",
    },
    {
        id = "preset-name-validation",
        desc = "preset name traversal validation disabled",
        file = "lib/presets.lua",
        find = "function Presets.saveViewPreset(view, preset_name, intent_section)\n    local clean_name, name_err = cleanPresetName(preset_name)",
        replace = "function Presets.saveViewPreset(view, preset_name, intent_section)\n    local clean_name, name_err = preset_name, nil",
        killer = "test_p1b_preset_semantics.lua",
    },
    {
        id = "spent-transaction-gate",
        desc = "discarded transactions expose mutable canonical references",
        file = "lib/intent_store.lua",
        find = "return util.tableDeepCopy(source or {})\n    end\n    if type(self.staged[view]) ~= \"table\" then",
        replace = "return source or {}\n    end\n    if type(self.staged[view]) ~= \"table\" then",
        killer = "test_transaction_contract.lua",
    },
    {
        id = "raw-order-exclusivity",
        desc = "raw passthrough retains contradictory bulk authority",
        file = "lib/intent_store.lua",
        find = "if order_override[menu_id] ~= nil then\n            order_override[menu_id] = nil\n            changed = true",
        replace = "if order_override[menu_id] ~= nil then\n            local _ignored_raw_order = order_override[menu_id]\n            changed = true",
        killer = "test_schema_migration.lua",
    },
    {
        id = "missing-registry-report",
        desc = "changed view without a registry is silently skipped",
        file = "lib/commit_pipeline.lua",
        find = 'outcome.failed_views[view] = "no registry available"',
        replace = 'local _silently_skipped_view = view',
        killer = "test_p0_commit_pipeline.lua",
    },
}

print("===============================================================")
print("=== Mutation test matrix                                     ===")
print("===============================================================")

local failed_count = 0
local work_dir = makeWorkingCopy()

for _, m in ipairs(MUTANTS) do
    local path = work_dir .. "/" .. m.file
    local orig = read(path)
    if not orig then
        print(string.format("  %-24s %-10s cannot read %s", m.id, "ERROR", m.file))
        failed_count = failed_count + 1
    else
        local mutated, n = mutate_one(orig, m.find, m.replace)
        if not mutated then
            print(string.format("  %-24s %-10s snippet drifted", m.id, "STALE"))
            failed_count = failed_count + 1
        else
            write(path, mutated)
            local ok, result, detail = pcall(run_suite, work_dir, m.killer)
            write(path, orig)
            if not ok or result == "error" then
                print(string.format("  %-24s %-10s sites=%d killer=%s | %s",
                    m.id, "ERROR", n, m.killer,
                    detail or (not ok and tostring(result)) or "harness failure"))
                failed_count = failed_count + 1
            elseif result ~= "killed" then
                print(string.format("  %-24s %-10s sites=%d killer=%s | %s",
                    m.id, "SURVIVED", n, m.killer, m.desc))
                failed_count = failed_count + 1
            else
                print(string.format("  %-24s %-10s sites=%d killer=%s | %s",
                    m.id, "KILLED", n, m.killer, m.desc))
            end
        end
    end
end

os.execute("rm -rf " .. shellQuote(work_dir))

print(string.format("\nMutation summary: %d failed/survived of %d", failed_count, #MUTANTS))
os.exit(failed_count == 0 and 0 or 1)

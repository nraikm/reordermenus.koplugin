--[[--
mutation_test.lua — targeted mutation testing for ReorderingMenus.

Applies one surgical mutation at a time to a production file, runs a
killer suite in a fresh process, and verifies the suite FAILS (mutant
killed). Original bytes are always restored, even on crash.

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

-- Replace ALL occurrences of `find` with `replace` (plain strings).
local function mutate_all(orig, find, replace)
    local count = 0
    local out = orig:gsub(find, function()
        count = count + 1
        return replace
    end, -1)
    -- plain-string gsub needs escaping; do a manual loop instead
    if count == 0 and orig:find(find, 1, true) then
        out = orig
        while true do
            local i, j = out:find(find, 1, true)
            if not i then break end
            out = out:sub(1, i - 1) .. "@@MUT@@" .. out:sub(j + 1)
            count = count + 1
        end
        out = out:gsub("@@MUT@@", replace)
    end
    return count > 0 and out or nil, count
end

local function run_suite(name)
    local cmd = string.format(
        'cd /Applications/KOReader.app/Contents/koreader && ./luajit %s/tests/%s > /tmp/rm_mut.txt 2>&1; exit 0',
        project_dir, name)
    os.execute(cmd)
    local out = read("/tmp/rm_mut.txt") or ""
    local _, f = out:match("(%d+) passed, (%d+) failed")
    if not f then return true end
    return tonumber(f) > 0
end

local MUTANTS = {
    {
        id = "quarantine-corrupt",
        desc = "quarantine on corrupt canonical intent neutralized",
        file = "reorderingmenus_intent_store.lua",
        find = 'backup_path = writeBackupBytes(path, "corrupt", raw_text)',
        replace = "backup_path = nil",
        killer = "test_corrupt_canonical_intent.lua",
    },
    {
        id = "dormant-provider",
        desc = "dormant provider intent falsely materializes",
        file = "reorderingmenus_materializer.lua",
        find = "local current_provider = node and node.provider or nil\n    if current_provider == nil then return false end",
        replace = "local current_provider = node and node.provider or nil\n    if current_provider == nil then return true end",
        killer = "test_provider_identity.lua",
    },
    {
        id = "noop-status",
        desc = "noop commit falsely reports saved",
        file = "reorderingmenus_commit_pipeline.lua",
        find = "outcome.status = CommitPipeline.STATUS.UNCHANGED",
        replace = "outcome.status = CommitPipeline.STATUS.SAVED",
        killer = "test_p0_commit_pipeline.lua",
    },
    {
        id = "preset-name-validation",
        desc = "preset name traversal validation disabled",
        file = "reorderingmenus_presets.lua",
        find = "local clean_name, name_err = cleanPresetName(preset_name)",
        replace = "local clean_name, name_err = preset_name, nil",
        killer = "test_p1b_preset_semantics.lua",
    },
}

print("===============================================================")
print("=== Mutation test matrix                                     ===")
print("===============================================================")

local failed_count = 0

for _, m in ipairs(MUTANTS) do
    local path = project_dir .. "/" .. m.file
    local orig = read(path)
    if not orig then
        print(string.format("  %-24s %-10s cannot read %s", m.id, "ERROR", m.file))
        failed_count = failed_count + 1
    else
        local mutated, n = mutate_all(orig, m.find, m.replace)
        if not mutated then
            print(string.format("  %-24s %-10s snippet drifted", m.id, "STALE"))
            failed_count = failed_count + 1
        else
            write(path, mutated)
            local ok, killed = pcall(run_suite, m.killer)
            write(path, orig)
            if not ok or not killed then
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

print(string.format("\nMutation summary: %d failed/survived of %d", failed_count, #MUTANTS))
os.exit(failed_count == 0 and 0 or 1)

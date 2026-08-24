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
        id = "quarantine-all",
        desc = "every canonical-problem quarantine call neutralized",
        file = "intent_store.lua",
        find = "last_backup_path = quarantine(path, raw_text)",
        replace = "last_backup_path = nil",
        killer = "test_corrupt_canonical_intent.lua",
    },
}

print("===============================================================")
print("=== Mutation test matrix                                     ===")
print("===============================================================")

for _, m in ipairs(MUTANTS) do
    local path = project_dir .. "/" .. m.file
    local orig = read(path)
    if not orig then
        print(string.format("  %-24s %-10s cannot read %s", m.id, "ERROR", m.file))
    else
        local mutated, n = mutate_all(orig, m.find, m.replace)
        if not mutated then
            print(string.format("  %-24s %-10s snippet drifted", m.id, "STALE"))
        else
            write(path, mutated)
            local killed = run_suite(m.killer)
            write(path, orig)
            print(string.format("  %-24s %-10s sites=%d killer=%s | %s",
                m.id, killed and "KILLED" or "SURVIVED", n, m.killer, m.desc))
        end
    end
end

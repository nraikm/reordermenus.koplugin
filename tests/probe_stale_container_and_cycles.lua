--[[--
Probe 2b: corrected cycles / airbag-loss / duplicate-id probes.
Run:  ./run_tests.sh tests/probe_stale_container_and_cycles.lua
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"), "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
local MENUSORTER_PATH = "frontend/ui/menusorter.lua"

local function loadStock()
    local chunk = assert(loadfile(MENUSORTER_PATH))
    local env = setmetatable({ require = require }, { __index = _G })
    setfenv(chunk, env)
    return chunk()
end

local BUDGET = 3e8
local function withBudget(fn)
    local hit_limit = false
    local prev = debug.sethook(function()
        hit_limit = true
        error("__BUDGET__", 0)
    end, "", 1e6)
    local ok, res = pcall(fn)
    debug.sethook(prev)
    if hit_limit then return false, "HANG" end
    if ok then return true, "ok", res end
    return false, "CRASH: " .. tostring(res):gsub("\n.*", ""), nil
end

local function find(node, id, seen)
    seen = seen or {}
    if seen[node] then return nil end
    seen[node] = true
    for _, e in pairs(node) do
        if type(e) == "table" then
            if e.id == id then return e end
            if type(e.sub_item_table) == "table" then
                local r = find(e.sub_item_table, id, seen)
                if r then return r end
            end
        end
    end
end

local function countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

print("===============================================================")
print("=== Probe 2b: stale shapes, cycles, airbag loss, dup ids ======")
print("===============================================================")

-- A2) Inspect the STALE-SHAPE result tree: what did X become?
print("\n--- A2) stale order[X] while X arrives as a leaf: tree shape ---")
do
    local order = {
        ["KOMenu:menu_buttons"] = { "main" },
        main = { "x" },
        x = { "old_child" },
    }
    local items = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = "Main" },
        x = { text = "Ex (now a LEAF)", callback = function() end },
        old_child = { text = "Old child" },
        late = { text = "Late", sorting_hint = "x" },
    }
    local stock = loadStock()
    local ok, verdict, tree = withBudget(function() return stock:sort(items, order) end)
    local xnode = ok and tree and find(tree, "x")
    local ochild = ok and tree and find(tree, "old_child")
    print(string.format("  stock=%s", verdict))
    if xnode then
        print(string.format("  X rendered: has_sub_item_table=%s children=%d callback_kept=%s",
            tostring(xnode.sub_item_table ~= nil),
            xnode.sub_item_table and #xnode.sub_item_table or -1,
            tostring(xnode.callback ~= nil)))
    end
    if ochild then
        print(string.format("  old_child rendered as orphan with text=%q",
            tostring(ochild.text)))
    end
    print("  => stale order row converts a LEAF into an EMPTY SUBMENU;",
        "\n     removed children reappear as 'NEW:' orphans (silent shape corruption)")
end

-- B) findById against a PLACED tree containing a sub_item_table cycle.
print("\n--- B) orphan hint resolution vs placed cyclic tree ---")
do
    local order = {
        ["KOMenu:menu_buttons"] = { "main" },
        main = { "a" },
        a = { "b" },
        b = { "c" },
    }
    local items = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = "Main" },
        a = { text = "A" },
        b = { text = "B" },
        c = { text = "C" },
    }
    local stock = loadStock()
    local ok, verdict, tree = withBudget(function() return stock:sort(items, order) end)
    print(string.format("  build: %s", verdict))
    local bnode = ok and tree and find(tree, "b")
    local mainnode = ok and tree and find(tree, "main")
    print(string.format("  located nodes: b=%s main=%s",
        tostring(bnode ~= nil), tostring(mainnode ~= nil)))
    if bnode and mainnode then
        bnode.sub_item_table = { mainnode } -- cycle: b -> main -> a -> b ...
        local s2 = loadStock()
        local ok2, verdict2 = withBudget(function()
            return s2:findById(tree, "id_exists_nowhere")
        end)
        print(string.format("  stock findById over cyclic tree => %s", verdict2))
        -- same lookup through the PLUGIN-guarded sorter:
        local guarded_ok, guarded_verdict = withBudget(function()
            return require("ui/menusorter"):findById(tree, "id_exists_nowhere")
        end)
        print(string.format("  plugin-loaded sorter (same proc, unguarded findById) => %s",
            guarded_verdict))
    end
end

-- C) AIRBAG INPUT LOSS, measured precisely.
print("\n--- C) airbag retry input after stock consumed placed refs ---")
do
    local order = {
        ["KOMenu:menu_buttons"] = { "main", "second" },
        main = { "m1" },
        second = { "s1" },
    }
    local original = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = "Main" },
        m1 = { text = "M1" },
        second = { text = "Second" },
        s1 = { text = "S1" },
        boom = { text = "Boom", sorting_hint = "no_such_target" },
    }
    print(string.format("  keys before any sort: %d", countKeys(original)))
    local stock = loadStock()
    local ok, err = pcall(stock.sort, stock, original, order)
    print(string.format("  first pass ok=%s (%s)", tostring(ok),
        ok and "-" or tostring(err):match("menusorter%.lua:%d+")))
    print(string.format("  keys in item_table AFTER crashed pass: %d (placed refs consumed)",
        countKeys(original)))
    for k in pairs(original) do print("    surviving key: " .. tostring(k)) end
    -- What would a sanitized retry produce?
    local clean_items, clean_order = KoreaderAdapter._probeSanitizeForRetry(original, order)
    print(string.format("  sanitized retry input keys: %d", countKeys(clean_items)))
    for k in pairs(clean_items) do print("    retry sees: " .. tostring(k)) end
    print("  => retry can only ever render the crashing orphan itself;")
    print("     every item placed before the fault is missing from retry output.")
end

-- D) Duplicate id from ONE provider (double write into captured table).
print("\n--- D) duplicate contributions ---")
do
    -- One provider writing the same key twice into the capture table:
    -- last write wins, first is invisible to every downstream stage.
    local captured = {}
    local writes = 0
    local w = {
        name = "dup_plugin",
        addToMainMenu = function(_, mi)
            writes = writes + 1
            mi.ghost_id = { text = "write " .. writes }
        end,
    }
    w.addToMainMenu(w, captured)
    w.addToMainMenu(w, captured)
    print(string.format("  same provider, 2 addToMainMenu calls -> captured.ghost_id.text=%q (first write UNRECOVERABLE)",
        tostring(captured.ghost_id.text)))

    -- Two providers contributing one id: attribution must be deterministic.
    local regs, providers = KoreaderAdapter.collectLiveRegistrations({
        menu = { registered_widgets = {
            { name = "zeta", addToMainMenu = function(_, mi)
                mi.shared_id = { text = "from zeta", sorting_hint = "tools" }
            end },
            { name = "alpha", addToMainMenu = function(_, mi)
                mi.shared_id = { text = "from alpha", sorting_hint = "search" }
            end },
        } },
    })
    print(string.format("  two providers, shared id -> attributed=%s hint=%s colliding=%s",
        tostring(providers.shared_id),
        tostring(regs.shared_id and regs.shared_id.sorting_hint),
        regs.shared_id and regs.shared_id.colliding_providers
            and table.concat(regs.shared_id.colliding_providers, ",") or "-"))

    -- Equal names from two widgets (two dirs shipping identical _meta name):
    local regs2, providers2 = KoreaderAdapter.collectLiveRegistrations({
        menu = { registered_widgets = {
            { name = "twin", addToMainMenu = function(_, mi)
                mi.twin_id = { text = "twin one", sorting_hint = "hint_one" }
            end },
            { name = "twin", addToMainMenu = function(_, mi)
                mi.twin_id = { text = "twin two", sorting_hint = "hint_two" }
            end },
        } },
    })
    print(string.format("  EQUAL widget names -> attributed=%s hint=%s reported_as_collision=%s (tiebreak undefined: first-seen wins)",
        tostring(providers2.twin_id),
        tostring(regs2.twin_id and regs2.twin_id.sorting_hint),
        tostring(regs2.twin_id and regs2.twin_id.colliding_providers ~= nil)))
end

print("\nProbe 2b complete.")

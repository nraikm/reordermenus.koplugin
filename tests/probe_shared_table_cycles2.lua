--[[--
Probe 3b: does a shared submenu table produce a self-referential RENDERED
tree, and does stock findById then hang? Correct BFS over array parts.
Run:  ./run_tests.sh tests/probe_shared_table_cycles2.lua
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"), "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local MENUSORTER_PATH = "frontend/ui/menusorter.lua"
local function loadStock()
    local chunk = assert(loadfile(MENUSORTER_PATH))
    local env = setmetatable({ require = require }, { __index = _G })
    setfenv(chunk, env)
    return chunk()
end
local BUDGET = 3e8
local function withBudget(fn)
    local hit = false
    local prev = debug.sethook(function()
        hit = true
        error("__BUDGET__", 0)
    end, "", 1e6)
    local ok, res = pcall(fn)
    debug.sethook(prev)
    if hit then return false, "HANG" end
    if ok then return true, "ok", res end
    return false, "CRASH", nil
end

-- BFS by identity over the rendered bar; returns node with .id == wanted.
local function bfs(root, wanted)
    local seen = { [root] = true }
    local queue = { root }
    while #queue > 0 do
        local node = table.remove(queue, 1)
        if type(node) ~= "table" then
            -- skip
        else
            if node.id == wanted then return node end
            for _, child in ipairs(node) do
                if type(child) == "table" and not seen[child] then
                    seen[child] = true
                    queue[#queue + 1] = child
                end
            end
            if type(node.sub_item_table) == "table" and not seen[node.sub_item_table] then
                seen[node.sub_item_table] = true
                queue[#queue + 1] = node.sub_item_table
                for _, child in ipairs(node.sub_item_table) do
                    if type(child) == "table" and not seen[child] then
                        seen[child] = true
                        queue[#queue + 1] = child
                    end
                end
            end
        end
    end
end

print("=== Probe 3b: shared submenu table -> rendered cycle? ===")
do
    local shared = {
        text = "Shared",
        sub_item_table = { { id = "child", text = "Child" } },
    }
    local order = {
        ["KOMenu:menu_buttons"] = { "main" },
        main = { "alpha", "beta" },
        alpha = { "a_child" },
        beta = { "b_child" },
    }
    local items = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = "Main" },
        alpha = shared,
        beta = shared,
        a_child = { text = "A child" },
        b_child = { text = "B child" },
    }
    local stock = loadStock()
    local ok, verdict, tree = withBudget(function()
        return stock:sort(items, order)
    end)
    print(string.format("build: %s (%s)", verdict, tostring(ok)))
    if ok and type(tree) == "table" then
        local anode = bfs(tree, "alpha")
        local bnode = bfs(tree, "beta")
        print(string.format("alpha node=%s beta node=%s SAME_TABLE=%s",
            tostring(anode ~= nil), tostring(bnode ~= nil),
            tostring(anode ~= nil and anode == bnode)))
        if anode then
            print(string.format("alpha.self_as_sub=%s alpha.inner_sub_is_self=%s",
                tostring(anode.sub_item_table == anode),
                tostring(anode.sub_item_table ~= nil
                    and anode.sub_item_table.sub_item_table == anode)))
            -- Now: findById over this rendered tree (stock semantics).
            local s2 = loadStock()
            local ok2, v2 = withBudget(function()
                return s2:findById(tree, "definitely_absent_id")
            end)
            print(string.format("stock findById over rendered tree => %s", v2))
            -- plugin guard world: same lookup through require("ui/menusorter")
            local guarded = require("ui/menusorter")
            local ok3, v3 = withBudget(function()
                return guarded:findById(tree, "definitely_absent_id")
            end)
            print(string.format("plugin-process findById (unguarded fn) => %s", v3))
            -- And a full sort WITH an orphan hint against the poisoned tree:
            local s3 = loadStock()
            local poisoned_items = {
                ["KOMenu:menu_buttons"] = {},
                main = { text = "Main" },
                m1 = { text = "M1" },
                late = { text = "Late", sorting_hint = "main" },
            }
            -- NOTE: findById only runs for hints; reachable 'main' short-
            -- circuits before deep walk. Use a hint that misses instead:
            poisoned_items.late.sorting_hint = "absent_target"
            local ok4, v4 = withBudget(function()
                return s3:sort(poisoned_items, {
                    ["KOMenu:menu_buttons"] = { "main" },
                    main = { "m1" },
                })
            end)
            print(string.format("sort with missing-hint orphan (clean tree) => %s", v4))
        end
    end
end
print("done.")

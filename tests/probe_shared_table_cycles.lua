--[[--
Probe 3: shared-table submenus, orphan->orphan ordering, throwing funcs.
Run:  ./run_tests.sh tests/probe_shared_table_cycles.lua
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
    return false, "CRASH: " .. tostring(res):gsub("\n.*", ""), nil
end

print("===============================================================")
print("=== Probe 3: shared tables, orphan ordering, throwing funcs ====")
print("===============================================================")

-- A) ONE table object contributed under TWO submenu ids (classic provider
--    bug: `local sub = {...}; menu_items.a = sub; menu_items.b = sub`).
--    Stock attaches menu_table[a] into menu_table[b]'s slot and vice versa
--    in the sub_menus loop -> the SAME table becomes its own sub_item_table.
print("\n--- A) same table under two submenu ids ---")
do
    local shared = { text = "Shared" }
    shared.sub_item_table = { { text = "Child", id = "child" } }
    local order = {
        ["KOMenu:menu_buttons"] = { "main" },
        main = { "alpha", "beta" },
        alpha = { "a_child" },
        beta = { "b_child" },
    }
    local items = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = "Main" },
        alpha = shared, -- same object!
        beta = shared,  -- same object!
        a_child = { text = "A child" },
        b_child = { text = "B child" },
    }
    local stock = loadStock()
    local ok, verdict, tree = withBudget(function() return stock:sort(items, order) end)
    print(string.format("  build: %s", verdict))
    if ok and tree then
        -- is the rendered tree now self-referential?
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
                    for i = 1, (e.sub_item_table and #e.sub_item_table or 0) do
                        -- array children of sub_item_table
                    end
                end
            end
        end
        local anode = find(tree, "alpha")
        if anode and anode.sub_item_table then
            local inner = anode.sub_item_table
            local self_ref = inner == anode
                or (inner.sub_item_table == anode)
                or (inner.sub_item_table and inner.sub_item_table.sub_item_table == anode)
            print(string.format("  alpha.sub_item_table self-reference: %s",
                tostring(self_ref)))
            -- the money shot: does findById hang on this tree now?
            local s2 = loadStock()
            local ok2, verdict2 = withBudget(function()
                return s2:findById(tree, "nothing_called_this")
            end)
            print(string.format("  findById over shared-table tree => %s", verdict2))
            -- would the plugin's own tree-walks hang too? (menu_titles, semantic walks)
            local ok3, verdict3 = withBudget(function()
                local seen = {}
                local function walk(n)
                    if seen[n] then return end
                    seen[n] = true
                    for _, e in pairs(n) do
                        if type(e) == "table" then walk(e) end
                    end
                end
                walk(tree)
                return "walked"
            end)
            print(string.format("  naive seen-set walk => %s", tostring(verdict3)))
        end
    end
end

-- B) orphan -> orphan hint: resolution depends on orderedPairs ALPHABETICAL
--    order of orphan ids. Rename a plugin and its crash appears/vanishes.
print("\n--- B) orphan->orphan hint: alphabetical luck ---")
do
    local function world(first, second)
        local order = {
            ["KOMenu:menu_buttons"] = { "main" },
            main = { "m1" },
        }
        local items = {
            ["KOMenu:menu_buttons"] = {},
            main = { text = "Main" },
            m1 = { text = "M1" },
            [first] = { text = "First orphan" }, -- plain orphan, lands in bar
            [second] = { text = "Second orphan", sorting_hint = first },
        }
        local stock = loadStock()
        return withBudget(function() return stock:sort(items, order) end)
    end
    local ok1, v1 = world("aaa_target", "zzz_hinter")
    local ok2, v2 = world("zzz_target", "aaa_hinter")
    print(string.format("  target sorts FIRST  (%s <- %s): %s",
        "aaa_target", "zzz_hinter", v1))
    print(string.format("  target sorts SECOND (%s <- %s): %s",
        "zzz_target", "aaa_hinter", v2))
    print("  => same structural shape, crash decided by ALPHABETICAL ORDER of ids")
end

-- C) text_func / enabled_func that throw: where does the plugin touch them?
print("\n--- C) throwing text_func during plugin title collection ---")
do
    local MenuTitles = dofile(project_dir .. "/menu_titles.lua")
    local item = {
        text_func = function() error("boom from provider") end,
        text = nil,
    }
    local ok, title = pcall(function()
        return MenuTitles.resolveTitle and MenuTitles.resolveTitle(item, "some_id") or MenuTitles.titleFor(item, "some_id")
    end)
    print(string.format("  menu_titles direct call: ok=%s (%s)",
        tostring(ok), ok and tostring(title) or tostring(title):gsub("\n.*", "")))
    -- inspect what functions menu_titles actually exposes for the report
    local names = {}
    for k, v in pairs(MenuTitles) do
        if type(v) == "function" then names[#names + 1] = k end
    end
    table.sort(names)
    print("  menu_titles functions: " .. table.concat(names, ", "))
end

print("\nProbe 3 complete.")

--[[--
Empirical probe: stock MenuSorter vs the full malformed sorting_hint target
matrix (review Areas 1-2). NOT a regression suite yet - it records what the
INSTALLED stock sorter actually does for each shape, plus what the plugin's
classifier says about the same input, so fallback policy rests on evidence.

Run:  ./run_tests.sh tests/probe_sorting_hint_matrix.lua
Each case loads a PRIVATE sandbox copy of frontend/ui/menusorter.lua (stock,
no guards), so cases cannot pollute each other. A debug.sethook instruction
budget converts would-be INFINITE LOOPS into a catchable "HANG" verdict -
pcall alone cannot see those, and a hang is worse than a crash.
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"), "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local KoreaderAdapter = require("koreader_adapter")

local SEP = "----------------------------"
local MENUSORTER_PATH = os.getenv("KOREADER_DIR")
    and (os.getenv("KOREADER_DIR") .. "/frontend/ui/menusorter.lua")
    or "frontend/ui/menusorter.lua"

local function loadStock()
    local chunk = assert(loadfile(MENUSORTER_PATH))
    local env = setmetatable({ require = require }, { __index = _G })
    setfenv(chunk, env)
    return chunk()
end

-- Execute fn under an instruction budget; returns ok, verdict, result.
local BUDGET = 3e8 -- ~0.5-2s of luajit instructions
local function withBudget(fn)
    local hit_limit = false
    local prev = debug.sethook(function()
        hit_limit = true
        error("__BUDGET__", 0)
    end, "", 1e6)
    local ok, res = pcall(fn)
    debug.sethook(prev)
    if hit_limit then return false, "HANG", nil end
    if ok then return true, "ok", res end
    return false, "CRASH: " .. tostring(res):gsub("\n.*", ""), nil
end

-- Deep structural fingerprint that tolerates cycles (bounded depth).
local function fp(v, depth)
    depth = depth or 0
    local t = type(v)
    if t ~= "table" then return t .. ":" .. tostring(v) end
    if depth > 12 then return "<deep>" end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for i = 1, math.min(#v, 64) do parts[#parts + 1] = fp(v[i], depth + 1) end
    for _, k in ipairs(keys) do
        if not tonumber(k) then
            parts[#parts + 1] = k .. "=" .. fp(v[k], depth + 1)
        end
    end
    return "[" .. table.concat(parts, ";") .. "]"
end

local function baseWorld(hint_value)
    -- One placed container "main" with a leaf; one orphan carrying the hint.
    local order = {
        ["KOMenu:menu_buttons"] = { "main" },
        main = { "m1" },
    }
    local items = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = "Main" },
        m1 = { text = "One" },
        orphan = { text = "Orphan", sorting_hint = hint_value },
    }
    return order, items
end

local CASES = {
    { name = "reachable_container (control)", hint = "main" },
    { name = "reachable_leaf",                hint = "m1" },
    { name = "separator_id",                  hint = SEP },
    { name = "itself",                        hint = "orphan" },
    { name = "another_orphan",                hint = "second_orphan",
      extra_items = { second_orphan = { text = "Second" } } },
    { name = "custom_submenu_in_order_only",  special = "custom_submenu" },
    { name = "numeric_hint",                  hint = 42 },
    { name = "empty_string_hint",             hint = "" },
    { name = "table_hint",                    hint = { "main" } },
    { name = "boolean_false_hint",            hint = false },
    { name = "disabled_target (Error G)",     hint = "gone_tab", disabled = { "gone_tab" } },
}

print("===============================================================")
print("=== Probe: stock MenuSorter vs malformed sorting_hint targets ===")
print("===============================================================")

local findings = {}
local function record(class, stock_verdict, klass)
    findings[#findings + 1] = { case = class, stock = stock_verdict, classifier = klass }
end

for _, case in ipairs(CASES) do
    local order, items = baseWorld(case.hint)
    if case.disabled then order["KOMenu:disabled"] = case.disabled end
    if case.extra_items then
        for k, v in pairs(case.extra_items) do items[k] = v end
    end
    if case.special == "custom_submenu" then
        -- Order lists it as a container but no provider supplies the item
        -- (the exact hole the plugin's custom-submenu synthesis fills).
        order.custom_sub = { "cs_child" }
        order.main = { "m1", "custom_sub" }
        items.cs_child = { text = "Child" }
    end

    -- Classify BEFORE stock consumes placed references from items: the
    -- production guard inspects the pristine world pre-sort.
    local klass_before = KoreaderAdapter.classifyHintTarget(
        case.hint == nil and "nonstring_nil_probe" or case.hint,
        order, "orphan", items)

    local stock = loadStock()
    local ok, verdict, result = withBudget(function()
        return stock:sort(items, order)
    end)

    local detail = ""
    if ok and type(result) == "table" then
        local f = fp(result)
        -- where did the orphan land?
        local where = "dropped"
        local function scan(node, path)
            for _, e in ipairs(node) do
                if type(e) == "table" then
                    if e.id == "orphan" then where = path end
                    if type(e.sub_item_table) == "table" then
                        scan(e.sub_item_table, path .. ">" .. tostring(e.id))
                    end
                    if #e > 0 and e.id ~= "orphan" then
                        scan(e, path .. ">" .. tostring(e.id) .. "(array)")
                    end
                end
            end
        end
        scan(result, "bar")
        detail = " landed_at=" .. where
        if where ~= "dropped" then
            local o = fp(items.orphan or { gone = true })
            detail = detail .. " orphan_ref_intact=" .. tostring(o:find("Orphan") ~= nil)
        end
        if f:find("sub_item_table=%[1=table:id=orphan%]") then
            detail = detail .. " SWALLOWED_INTO_LEAF_ARRAY"
        end
    elseif verdict:find("^HANG") then
        detail = " INFINITE_LOOP (findById cycle/unbounded)"
    end
    print(string.format("  %-34s stock=%-58s classifier=%s%s",
        case.name, verdict,
        tostring(klass_before),
        detail))
    record(case.name, verdict)
end

-- Extra probe: hint -> menu that CHANGES SHAPE (submenu becomes leaf between
-- rebuilds). Old native files keep order[X]; provider now ships X as a leaf.
print("\n--- shape-change: order[X] retained while X arrives as a LEAF ---")
do
    local order = {
        ["KOMenu:menu_buttons"] = { "main" },
        main = { "x" },
        x = { "old_child" }, -- stale: X used to be a submenu
    }
    local items = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = "Main" },
        x = { text = "Ex (now a leaf)" }, -- provider changed shape
        old_child = { text = "Old child" },
        late = { text = "Late", sorting_hint = "x" },
    }
    local stock = loadStock()
    local ok, verdict, result = withBudget(function() return stock:sort(items, order) end)
    local cyc = ok and result
        and fp(result):find("sub_item_table=%[.-id=x") ~= nil
    print(string.format("  shape_change_submenu_to_leaf  stock=%s self_cycle=%s",
        verdict, tostring(cyc == true)))
    -- And: does the resulting tree poison a SUBSEQUENT findById (hang)?
    if ok and result then
        local s2 = loadStock()
        local r2 = s2:sort({
            ["KOMenu:menu_buttons"] = {}, main = { text = "Main" },
            m1 = { text = "One" },
        }, {
            ["KOMenu:menu_buttons"] = { "main" }, main = { "m1" },
        })
        local poisoned = withBudget(function()
            -- any orphan hint resolution walking the CYCLIC tree:
            return require("ui/menusorter"):findById(result, "never_found_anywhere")
        end)
        print(string.format("  findById against cyclic tree      => %s",
            poisoned and "returned" or tostring(select(2, poisoned))))
    end
end

print(string.format("\nProbe complete: %d cases recorded.", #findings))

--[[--
Probe 3c: self-referential sub_item_table -> findById infinite loop?
Run:  ./run_tests.sh tests/probe_selfref_hang.lua
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local MENUSORTER_PATH = "frontend/ui/menusorter.lua"
local function loadStock()
    local chunk = assert(loadfile(MENUSORTER_PATH))
    local env = setmetatable({ require = require }, { __index = _G })
    setfenv(chunk, env)
    return chunk()
end
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

-- Provider contributes a PLACED submenu whose sub_item_table chain loops
-- back to itself (transitively - the realistic typo/misuse shape).
local selfref = { text = "Loop B" }
local inner = { text = "Loop child", sub_item_table = selfref } -- child -> back
selfref.sub_item_table = { inner }

local order = {
    ["KOMenu:menu_buttons"] = { "main" },
    main = { "loop_b" },
    loop_b = { "inner" },
}
local items = {
    ["KOMenu:menu_buttons"] = {},
    main = { text = "Main" },
    loop_b = selfref,
}
-- drop the order row trick: keep it simple, loop_b is the container itself
order.loop_b = nil
order.main = { "loop_b" }

local stock = loadStock()
local ok, verdict, tree = withBudget(function() return stock:sort(items, order) end)
print("build:", verdict)

if ok and tree then
    -- Now ANY orphan hint resolution must walk this tree via findById:
    local order2 = {
        ["KOMenu:menu_buttons"] = { "main2" },
        main2 = { "m2" },
    }
    local items2 = {
        ["KOMenu:menu_buttons"] = {},
        main2 = { text = "Other view" },
        m2 = { text = "M2" },
        late = { text = "Late", sorting_hint = "nowhere_to_be_found" },
    }
    -- findById runs against menu_table["KOMenu:menu_buttons"] of ITS OWN sort
    -- call, so simulate exactly: poisoned tree is the BAR being searched.
    local s2 = loadStock()
    local ok2, v2 = withBudget(function()
        -- monkey-see: replicate stock's orphan branch against our poisoned bar
        local found = s2:findById(tree, "absent_hint_target")
        return found
    end)
    print("findById(poisoned bar, absent id) =>", v2)
end

-- Variant: orphan whose ARRAY PART makes stock synthesize sub_item_table,
-- then hints somewhere reachable (orphaned-submenu attach path).
do
    local order = {
        ["KOMenu:menu_buttons"] = { "main" },
        main = { "m1" },
    }
    local items = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = "Main" },
        m1 = { text = "M1" },
        weird_orphan = { text = "Weird", sorting_hint = "main",
            [1] = { text = "array child" } },
    }
    local s3 = loadStock()
    local ok3, v3, tree3 = withBudget(function() return s3:sort(items, order) end)
    print("orphan-with-array-part + reachable hint =>", v3,
        tree3 and "rendered" or "")
    if ok3 and tree3 then
        -- did the synthesized sub_item_table survive under main?
        local function scan(node, depth)
            for _, e in ipairs(node) do
                if type(e) == "table" then
                    if e.id == "weird_orphan" then
                        print("  weird_orphan rendered with children:",
                            e.sub_item_table and #e.sub_item_table or 0)
                    end
                    if depth < 4 and type(e.sub_item_table) == "table" then
                        scan(e.sub_item_table, depth + 1)
                    end
                end
            end
        end
        scan(tree3, 0)
    end
end
print("done.")

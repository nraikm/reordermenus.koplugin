--[[--
Probe 4: FULL production guard stack vs a stale-container hint.
Installs the real guards exactly like main.lua does, then sorts a world
where order[X] survived but item_table[X] is gone (provider shape change /
uninstalled provider), and an orphan hints at X.

Expected if safe: guard strips the hint, menu builds normally.
Feared:           guard passes it, stock crashes mid-orphan-loop leaving
                  __orderedIndex on item_table, airbag retries from consumed
                  inputs and "succeeds" with a gutted menu + junk row.

Run:  ./run_tests.sh tests/probe_airbag_end_to_end.lua
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"), "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
KoreaderAdapter.installMenuSorterGuards() -- hint guard + custom submenu guard + airbag
local MenuSorter = require("ui/menusorter")

local order = {
    ["KOMenu:menu_buttons"] = { "main", "tools" },
    main = { "m1", "x" },   -- x listed under main (stale row)
    tools = { "t1" },
    x = { "old_child_a", "old_child_b" }, -- stale container row
}
local items = {
    ["KOMenu:menu_buttons"] = {},
    main = { text = "Main" },
    m1 = { text = "M1" },
    tools = { text = "Tools" },
    t1 = { text = "T1" },
    late = { text = "Late plugin", sorting_hint = "x" },
    -- NOTE: no item_table.x - provider ships x as leaf elsewhere or is gone
}

print("=== Probe 4: production guard stack vs stale-container hint ===")
local ok, result = pcall(function()
    return MenuSorter:mergeAndSort(nil, items, order)
end)
print(string.format("mergeAndSort ok=%s", tostring(ok)))
if ok and type(result) == "table" then
    local found, junk = {}, nil
    local function scan(node, path)
        for _, e in ipairs(node) do
            if type(e) == "table" then
                if e.id then found[#found + 1] = e.id end
                if e == items.__orderedIndex then junk = "raw __orderedIndex array rendered" end
                if type(e.sub_item_table) == "table" then
                    scan(e.sub_item_table, path .. ">" .. tostring(e.id))
                end
            elseif type(e) == "table" then
                junk = "raw table row"
            end
        end
    end
    for _, top in ipairs(result) do
        if type(top) == "table" then
            if top.id then found[#found + 1] = top.id end
            if type(top.sub_item_table) == "table" then scan(top.sub_item_table, tostring(top.id)) end
        end
    end
    table.sort(found)
    print(string.format("rendered ids (%d): %s", #found, table.concat(found, ",")))
    print(string.format("expected ids    : %s",
        "KOMenu-less bar should show main,m1,tools,t1 (+NEW: late fallback if stripped)"))
    print(string.format("junk row present: %s", tostring(junk ~= nil)))
    print(string.format("__orderedIndex leaked onto item_table: %s",
        tostring(items.__orderedIndex ~= nil)))
elseif not ok then
    print("crash surfaced to caller:", tostring(result):gsub("\n.*", ""))
end

-- Control: same world WITHOUT the stale row (x absent from order entirely):
print("\n--- control: identical world minus stale order[x] ---")
do
    local order2 = {
        ["KOMenu:menu_buttons"] = { "main", "tools" },
        main = { "m1" },
        tools = { "t1" },
    }
    local items2 = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = "Main" },
        m1 = { text = "M1" },
        tools = { text = "Tools" },
        t1 = { text = "T1" },
        late = { text = "Late plugin", sorting_hint = "x" },
    }
    local ok2, result2 = pcall(function()
        return MenuSorter:mergeAndSort(nil, items2, order2)
    end)
    print(string.format("control ok=%s", tostring(ok2)))
    if ok2 and type(result2) == "table" then
        local ids = {}
        local function walk(n)
            for _, e in ipairs(n) do
                if type(e) == "table" then
                    ids[#ids + 1] = tostring(e.id or "?") .. (type(e.text) == "string"
                        and "(" .. e.text .. ")" or "")
                    if type(e.sub_item_table) == "table" then walk(e.sub_item_table) end
                end
            end
        end
        walk(result2)
        print("  rendered: " .. table.concat(ids, ", "))
    end
end
print("done.")

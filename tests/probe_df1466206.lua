-- Reproduce differential fuzz seed 1466206 with verbose before/after.
dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
package.path = "/Users/nr/Development/ReorderingMenus/?.lua;/Users/nr/Development/ReorderingMenus/tests/?.lua;" .. package.path
local World = require("tests.lib.sm_world")
local Manager = require("reorderingmenus_menuorder_manager")
local IntentStore = require("reorderingmenus_intent_store")

local seed = tonumber(arg and arg[1]) or 1466206
local STEPS = 40

local function fp(order)
    local parts = {}
    local menus = {}
    for menu_id in pairs(order) do menus[#menus + 1] = menu_id end
    table.sort(menus)
    for _, menu_id in ipairs(menus) do
        local list = order[menu_id]
        if type(list) == "table" then
            parts[#parts + 1] = menu_id .. "=[" .. table.concat(list, ",") .. "]"
        end
    end
    return table.concat(parts, ";")
end

local w = World:new(seed)
for step = 1, STEPS do
    w:step()
    local ok_save = Manager:saveOrder(w.view)
    local view = w.view
    local before = fp(Manager:loadOrder(view))
    Manager:reloadFromDisk(view)
    local after = fp(Manager:loadOrder(view))
    if before ~= after then
        print(string.format("DIVERGED at step %d view=%s save_ok=%s", step, tostring(view), tostring(ok_save)))
        print("BEFORE: " .. before)
        print("AFTER : " .. after)
        -- canonical intent snapshot
        local cs = IntentStore.load().views[view]
        for coll, tbl in pairs(cs) do
            if type(tbl) == "table" and next(tbl) then
                print("intent." .. coll .. ":")
                for k, v in pairs(tbl) do print("   ", tostring(k), tostring(type(v) == "table" and "table" or v)) end
            end
        end
        os.exit(2)
    end
end
print("no divergence in", STEPS, "steps")

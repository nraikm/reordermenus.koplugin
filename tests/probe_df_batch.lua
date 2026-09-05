-- Reproduce differential fuzz seeds with the EXACT suite harness (World via
-- tests/lib/fuzz_lib like the suite does), 40 steps, looping until divergence.
dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))
package.path = project_dir .. "/?.lua;" .. project_dir .. "/tests/?.lua;" .. package.path

local World = require("tests.lib.sm_world")
local Manager = require("lib.menuorder_manager")
local IntentStore = require("lib.intent_store")

local STEPS = 40
local seeds = { 314187, 523645, 628374, 733103, 1152019, 1361477, 1466206, 1570935, 1675664, 1780393 }

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

for _, seed in ipairs(seeds) do
    local w = World:new(seed)
    local diverged = false
    for step = 1, STEPS do
        w:step()
        Manager:saveOrder(w.view)
        local view = w.view
        local before = fp(Manager:loadOrder(view))
        Manager:reloadFromDisk(view)
        local after = fp(Manager:loadOrder(view))
        if before ~= after then
            print(string.format("seed=%d DIVERGED step=%d view=%s", seed, step, tostring(view)))
            print("BEFORE: " .. before)
            print("AFTER : " .. after)
            diverged = true
            break
        end
    end
    if not diverged then print("seed=" .. seed .. " clean in " .. STEPS) end
end

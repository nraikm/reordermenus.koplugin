-- Diff-dump the exact divergence: capture intent before/after reload.
dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))
package.path = project_dir .. "/?.lua;" .. project_dir .. "/tests/?.lua;" .. package.path
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
local _ = require("gettext")
require("main")
local Manager = require("lib.menuorder_manager")
local World = require("tests.lib.sm_world")
local IntentStore = require("lib.intent_store")

local SEED = tonumber(arg and arg[1]) or 1466206
local STEPS = tonumber(arg and arg[2]) or 200

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

local function dump_intent(view, tag)
    local cs = IntentStore.view(view)
    print(tag .. " intent for " .. view .. ":")
    for coll in ipairs({}) do end
    for _, coll in ipairs({ "hidden", "hidden_order", "parent_override",
            "position_override", "order_override", "raw_override",
            "separators", "custom_menus", "sequence_eras" }) do
        local c = cs[coll]
        if type(c) == "table" and next(c) ~= nil then
            for k, v in pairs(c) do
                local vs
                if type(v) == "table" then
                    vs = "{"
                    for k2, v2 in pairs(v) do
                        vs = vs .. tostring(k2) .. "=" .. tostring(type(v2) == "table" and "<t>" or v2) .. ","
                    end
                    vs = vs .. "}"
                else
                    vs = tostring(v)
                end
                print(string.format("  %s[%s] = %s", coll, tostring(k), vs))
            end
        end
    end
end

local w = World:new(SEED)
for step = 1, STEPS do
    local desc = w:step()
    Manager:saveOrder(w.view)
    local view = w.view
    local before = fp(Manager:loadOrder(view))
    dump_intent(view, string.format("STEP%d pre-reload (op=%s)", step, tostring(desc)))
    Manager:reloadFromDisk(view)
    local after = fp(Manager:loadOrder(view))
    if before ~= after then
        print(string.format("DIVERGED step=%d op=%s", step, tostring(desc)))
        dump_intent(view, "POST-reload")
        -- diff menus
        local function parse(s)
            local t = {}
            for m in s:gmatch("[^;]+") do
                local k = m:match("^([^=]+)=%[")
                local v = m:match("=%[(.*)%]$")
                t[k] = v
            end
            return t
        end
        local b, a = parse(before), parse(after)
        for k in pairs(b) do
            if b[k] ~= a[k] then
                print("MENU:", k)
                print("  B:", b[k])
                print("  A:", tostring(a[k]))
            end
        end
        break
    end
end
print("done")

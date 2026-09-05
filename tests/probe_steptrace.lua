-- Step-trace seed 1466206 to catch the exact step where round-trip diverges.
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

local SEED = 1466206
local STEPS = tonumber(arg and arg[1]) or 60

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

local w = World:new(SEED)
for step = 1, STEPS do
    local desc = w:step()
    Manager:saveOrder(w.view)
    local view = w.view
    local before = fp(Manager:loadOrder(view))
    Manager:reloadFromDisk(view)
    local after = fp(Manager:loadOrder(view))
    if before ~= after then
        print(string.format("DIVERGED at step %d view=%s op=%s", step, view, tostring(desc)))
        -- diff per menu
        local function parse(s)
            local t = {}
            for m in s:gmatch("[^;]+") do
                local k, v = m:match("^([^=]+)=%%[(.*)%%]$")
                if not k then k, v = m:match("^([^=]+)=%%[(.*)%%]$"), nil end
                if k and v then t[k] = v else
                    k = m:match("^([^=]+)=")
                    v = m:sub(#k + 3, -2)
                    t[k] = v
                end
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

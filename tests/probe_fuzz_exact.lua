-- Drive the world with restarts like the fuzzer does, and check the round
-- trip after every step (the fuzz harness itself). Print the last 3 ops.
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
local Manager = require("menuorder_manager")
local World = require("tests.lib.sm_world")

local SEED = tonumber(arg and arg[1]) or 1466206
local STEPS = 200

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
local history = {}
for step = 1, STEPS do
    local desc = w:step()
    Manager:saveOrder(w.view)
    local view = w.view
    local before = fp(Manager:loadOrder(view))
    Manager:reloadFromDisk(view)
    local after = fp(Manager:loadOrder(view))
    if before ~= after then
        print(string.format("DIVERGED step=%d view=%s op=%s", step, view, tostring(desc)))
        os.exit(2)
    end
end
print("clean", STEPS)

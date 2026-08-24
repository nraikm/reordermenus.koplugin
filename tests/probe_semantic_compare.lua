dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = "/Users/nr/Development/ReorderingMenus/tests/probe_semantic_compare.lua"
local project_dir = "/Users/nr/Development/ReorderingMenus"
package.path = project_dir .. "/?.lua;" .. package.path
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
require("main")
local World = require("tests.lib.sm_world")

-- fixture A: stage_list_permutation + reset_submenu
-- fixture B: move_item_in_menu (drag) + upstream ops... use 87109 (move + delete_native_file)
for _, fname in ipairs({"seed-712710-step-8-reset_submenu.lua", "seed-87109-step-102-reset_submenu.lua"}) do
    local fx = dofile(project_dir .. "/tests/fixtures/regression/" .. fname)
    local w = World:new(fx.seed)
    for _, e in ipairs(fx.history) do w:replay(e) end
    -- dump projection of the affected menu(s)
    local order = w:projection(w.view)
    print("== " .. fname .. " view=" .. w.view)
    for menu, list in pairs(order) do
        if type(list) == "table" and menu ~= "KOMenu:menu_buttons"
            and menu ~= "KOMenu:disabled" and menu ~= "KOMenu:custom_submenus" then
            print(menu .. " = [" .. table.concat(list, ", ") .. "]")
        end
    end
end

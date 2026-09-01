-- Bisect: does stageList-into-custom-submenu persist on reader vs filemanager?
dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))
package.path = project_dir .. "/?.lua;" .. package.path
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
do
    local _sd = DataStorage:getSettingsDir()
    for _, n in ipairs({ "reader_menu_order.lua", "filemanager_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua",
        "reorderingmenus_state.lua" }) do pcall(os.remove, _sd .. "/" .. n) end
end

local Mgr = require("menuorder_manager")

for _, view in ipairs({ "reader", "filemanager" }) do
    local ok, sub_id = Mgr:createSubmenu(view, "tools", "Bisect " .. view)
    local staged = Mgr:stageList(view, sub_id, { "go_to" })
    local kids = {}
    for _, r in ipairs(Mgr:getMenuItems(view, sub_id) or {}) do
        kids[#kids+1] = type(r) == "table" and (r.id or "?") or tostring(r)
    end
    local saved = Mgr:saveOrder(view)
    local kids2 = {}
    for _, r in ipairs(Mgr:getMenuItems(view, sub_id) or {}) do
        kids2[#kids2+1] = type(r) == "table" and (r.id or "?") or tostring(r)
    end
    -- Fresh read from disk
    print(string.format("%s: create=%s stage=%s pre_save=[%s] saved=%s post_save=[%s]",
        view, tostring(ok ~= false), tostring(staged),
        table.concat(kids, ","), tostring(saved), table.concat(kids2, ",")))
end

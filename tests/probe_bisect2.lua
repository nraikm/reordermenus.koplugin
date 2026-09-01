-- Bisect 2: which guard drops go_to on filemanager? Instrument reconcileMembership.
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
local Materializer = require("materializer")
local Registry = require("registry")

-- Peek at the session internals via a fresh reconcile-free path:
-- create submenu, then manually evaluate what effectiveParent says for go_to.
for _, view in ipairs({ "reader", "filemanager" }) do
    local ok, sub_id = Mgr:createSubmenu(view, "tools", "B2 " .. view)
    -- What does the DEFAULT derivation (empty intent) say about go_to here?
    local s_ok, s = pcall(function()
        return Mgr.sessions and Mgr.sessions[view]
    end)
    -- sessions is module-private; use the public projection instead:
    local parent_now = Mgr:getParentMenu(view, "go_to")
    print(string.format("%s: created=%s go_to_parent_now=%s",
        view, tostring(ok ~= false), tostring(parent_now)))
end

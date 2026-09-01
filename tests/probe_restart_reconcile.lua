-- Probe: post-restart reconcile in isolation (KOReader env bootstrapped)
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

local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local ReorderingMenus = require("main")
local UIScreens = require("ui_screens")
local Mgr = require("menuorder_manager")

local view = "filemanager"
local mock_ui_fm = { menu = nil }

local fm_menu2 = FileManagerMenu:new{ ui = mock_ui_fm }
mock_ui_fm.menu = fm_menu2
fm_menu2.registered_widgets.fresh_plugin_stub = {
    addToMainMenu = function(self, menu_items)
        menu_items.fresh_plugin_item = {
            text = "Freshly installed plugin",
            sorting_hint = "tools",
            callback = function() end,
        }
    end,
}
local plugin2 = ReorderingMenus:new{ ui = mock_ui_fm }
plugin2.ui = mock_ui_fm
fm_menu2:registerToMainMenu(plugin2)
UIScreens:reconcileRegisteredItems(plugin2, view, true)

print("getParentMenu:", tostring(Mgr:getParentMenu(view, "fresh_plugin_item")))

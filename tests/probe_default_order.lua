dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = "/Users/nr/Development/ReorderingMenus/tests/probe_default_order.lua"
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
local Manager = require("reorderingmenus_menuorder_manager")
print("setting default = [" .. table.concat(Manager:getDefaultOrder("filemanager")["setting"] or {}, ", ") .. "]")

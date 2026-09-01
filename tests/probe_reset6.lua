--[[--
probe_reset6.lua — resetOrder leaves a reserved-only file on disk?
Check the exact sequence of disk states.
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
local _ = require("gettext")
require("main")

local MenuOrderManager = require("menuorder_manager")
local IntentStore = require("intent_store")
local NativeWriter = require("native_writer")
local UIScreens = require("ui_screens")

local view = "reader"
local sd = DataStorage:getSettingsDir()
local ORDER_FILE = sd .. "/" .. view .. "_menu_order.lua"

os.remove(ORDER_FILE)
os.remove(sd .. "/reorderingmenus_intent.lua")
os.remove(sd .. "/reorderingmenus_materialization.lua")
IntentStore.load(true); NativeWriter._resetCaches()
MenuOrderManager:dropSessionState(view)

local function launch()
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, view, false)
end
launch()
MenuOrderManager:setItemHidden(view, "calibre", true, "tools")
MenuOrderManager:saveOrder(view)

local lfs = require("libs/libkoreader-lfs")
print("pre-reset file=" .. tostring(lfs.attributes(ORDER_FILE, "mode")))

MenuOrderManager:resetOrder(view)
print("post-reset file=" .. tostring(lfs.attributes(ORDER_FILE, "mode")))

-- What does the file hold if it exists?
if lfs.attributes(ORDER_FILE, "mode") then
    local f = io.open(ORDER_FILE, "r")
    print("--- file content:")
    print(f:read("*a"))
    f:close()
end

-- Second reset (idempotence): does the reserved-only file get removed now?
MenuOrderManager:resetOrder(view)
print("post-reset-2 file=" .. tostring(lfs.attributes(ORDER_FILE, "mode")))

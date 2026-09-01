--[[--
probe_p1c.lua — what does the dense fixture actually import? And what does
the persisted v0->v2 intent file look like?
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

local Manager = require("menuorder_manager")
local IntentStore = require("intent_store")
local NativeWriter = require("native_writer")
local UIScreens = require("ui_screens")
local KoreaderAdapter = require("koreader_adapter")

local sd = DataStorage:getSettingsDir()
local VIEW = "filemanager"
local FX = project_dir .. "/tests/fixtures/historical"

for _, f in ipairs({ "filemanager_menu_order.lua", "reader_menu_order.lua",
    "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua",
    "reorderingmenus_state.lua" }) do os.remove(sd .. "/" .. f) end
IntentStore.load(true); NativeWriter._resetCaches()
Manager:dropSessionState(VIEW)

local src = io.open(FX .. "/dense-era_filemanager_menu_order.lua", "r")
local bytes = src:read("*a"); src:close()
local dst = io.open(sd .. "/filemanager_menu_order.lua", "w")
dst:write(bytes); dst:close()

local ui = { menu = { registered_widgets = {} } }
UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)

print("P1 hidden records:")
for k, v in pairs(IntentStore.view(VIEW).hidden) do
    print("  hid " .. k .. " origin=" .. tostring(v.origin))
end
print("P1 more_tools projection:")
for i, id in ipairs(Manager:getMenuItems(VIEW, "more_tools")) do
    print("  mt[" .. i .. "]=" .. tostring(id))
end

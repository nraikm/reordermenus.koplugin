--[[--
probe_t7b.lua — what does the legacy import record for the swapped help list?
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

local view = "filemanager"
local sd = DataStorage:getSettingsDir()
local ORDER_FILE = sd .. "/" .. view .. "_menu_order.lua"

os.remove(ORDER_FILE); os.remove(sd .. "/reorderingmenus_intent.lua")
os.remove(sd .. "/reorderingmenus_materialization.lua")
IntentStore.load(true); NativeWriter._resetCaches()
MenuOrderManager:dropSessionState(view)

local function launch()
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, view, false)
end
launch()
MenuOrderManager:saveOrder(view)

-- swap two adjacent non-separator rows in help
local order_now = MenuOrderManager:loadOrder(view)
local lst = order_now.help or {}
print("help before swap (" .. #lst .. "):")
for i, id in ipairs(lst) do print("  [" .. i .. "]=" .. tostring(id)) end
for i = 1, #lst - 1 do
    if lst[i] ~= "----------------------------" and lst[i + 1] ~= "----------------------------" then
        lst[i], lst[i + 1] = lst[i + 1], lst[i]
        print("swapped positions " .. i .. "," .. (i+1))
        break
    end
end
local dump = require("dump")
local fh = io.open(ORDER_FILE, "w")
fh:write("return " .. dump(order_now, nil, true)); fh:close()

NativeWriter._resetCaches(); MenuOrderManager:dropSessionState(view)
IntentStore.load(true); launch()   -- imports the external help swap

print("CANONICAL after import:")
local sec = IntentStore.view(view)
for id in pairs(sec.order_override) do print("  oo key: " .. tostring(id)) end
for id in pairs(sec.position_override) do print("  po key: " .. tostring(id)) end

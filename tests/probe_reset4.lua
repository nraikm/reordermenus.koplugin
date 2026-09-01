--[[--
probe_reset4.lua — after reset, what's on disk and why does the file exist?
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
os.remove(sd .. "/" .. view .. "_menu_order.lua")
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

print("sidecar BEFORE reset:")
local rec = NativeWriter.getRecord(view)
if rec then
    print("  structure keys: " .. (rec.structure and "table" or "nil"))
    for k in pairs(rec.structure or {}) do print("    skey: " .. tostring(k)) end
end

MenuOrderManager:resetOrder(view)

print("file exists after reset=" ..
    tostring(require("libs/libkoreader-lfs").attributes(
        sd .. "/" .. view .. "_menu_order.lua", "mode")))
rec = NativeWriter.getRecord(view)
print("sidecar AFTER reset:")
if rec then
    print("  structure=" .. (rec.structure and "table" or "nil"))
    if rec.structure then
        for k, v in pairs(rec.structure) do
            print(string.format("    skey=%s n=%d", tostring(k),
                type(v) == "table" and #v or -1))
        end
    end
else
    print("  no record")
end

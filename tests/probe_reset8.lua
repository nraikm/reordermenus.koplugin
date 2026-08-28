--[[--
probe_reset8.lua — resetOrder: does the file get re-created by the
checkpoint write AFTER the remove? Sequence: remove -> writeView(empty)
-> stripEmptyReservedMaps consults PREVIOUS record (non-empty disabled
from hide save) -> returns false (keep reserved keys!) -> has_content=true
-> file REWRITTEN with empty reserved maps. That's the residue.
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

local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local IntentStore = require("reorderingmenus_intent_store")
local NativeWriter = require("reorderingmenus_native_writer")
local UIScreens = require("reorderingmenus_ui_screens")
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")

local view = "reader"
local sd = DataStorage:getSettingsDir()
local ORDER_FILE = sd .. "/" .. view .. "_menu_order.lua"
local lfs = require("libs/libkoreader-lfs")

os.remove(ORDER_FILE); os.remove(sd .. "/reorderingmenus_intent.lua")
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

print("pre-reset exists=" ..
    tostring(lfs.attributes(ORDER_FILE, "mode") == "file"))
print("pre-reset record.structure disabled=" ..
    tostring(NativeWriter.getRecord(view).structure
        and next(NativeWriter.getRecord(view).structure["KOMenu:disabled"])))

MenuOrderManager:resetOrder(view)

local rec = NativeWriter.getRecord(view)
print("post-reset record.structure = " .. tostring(rec and rec.structure ~= nil))
if rec and rec.structure then
    for k, v in pairs(rec.structure) do
        print(string.format("  %s n=%d", k, type(v) == "table" and #v or -1))
    end
end
print("post-reset file exists=" ..
    tostring(lfs.attributes(ORDER_FILE, "mode") == "file"))

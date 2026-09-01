--[[-- probe_mirror_hij2.lua — tab-hide edge: shared menu id in both views. --]]
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
local util = require("util")

local sd = DataStorage:getSettingsDir()
local function wipe_all()
    for _, f in ipairs({ "filemanager_menu_order.lua", "reader_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        os.remove(sd .. "/" .. f)
    end
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}
    Manager.recent_moves.reader = {}
    Manager:dropSessionState("filemanager")
    Manager:dropSessionState("reader")
end

print("\n=== P4: hide FM tab 'setting' (id exists as reader MENU) ===")
wipe_all()
Manager:setMirroringEnabled(true)
Manager:setItemHidden("filemanager", "setting", true, "main")
print("FM disabled has setting: " ..
    tostring(util.arrayContains(Manager:getDisabledItems("filemanager") or {}, "setting")))
print("reader disabled has setting: " ..
    tostring(util.arrayContains(Manager:getDisabledItems("reader") or {}, "setting")))
print("reader hidden rec: " ..
    tostring(IntentStore.view("reader").hidden.setting ~= nil))

print("\n=== P5: unhide path symmetric ===")
Manager:setItemHidden("filemanager", "setting", false, nil)
print("FM disabled has setting: " ..
    tostring(util.arrayContains(Manager:getDisabledItems("filemanager") or {}, "setting")))
print("reader disabled has setting: " ..
    tostring(util.arrayContains(Manager:getDisabledItems("reader") or {}, "setting")))
print("reader hidden rec: " ..
    tostring(IntentStore.view("reader").hidden.setting ~= nil))
wipe_all()
print("done")

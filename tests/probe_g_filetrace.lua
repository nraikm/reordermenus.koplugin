--[[
probe_g_filetrace.lua — trace the intent file bytes around a failed live reload.
Answers: is the record ever written? Is it later removed/overwritten?
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

local sd = DataStorage:getSettingsDir()
local VIEW = "filemanager"
local INTENT_PATH = sd .. "/reorderingmenus_intent.lua"

local function wipe_all()
    for _, f in ipairs({ "filemanager_menu_order.lua", "reader_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua",
        "reorderingmenus_intent.lua.unparsable", "reorderingmenus_intent.lua.corrupt",
        "reorderingmenus_intent.lua.unsupported" }) do
        os.remove(sd .. "/" .. f)
    end
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}
    Manager.recent_moves.reader = {}
    Manager:dropSessionState(VIEW)
    Manager:dropSessionState("reader")
end

local function dump(tag)
    local f = io.open(INTENT_PATH, "r")
    if not f then print(tag .. ": <no intent file>"); return end
    local body = f:read("*a"); f:close()
    print(tag .. ": len=" .. #body .. " has_opds=" .. tostring(body:find("opds", 1, true) ~= nil))
    print(tag .. " BODY>>> " .. body:gsub("%s+", " ") .. " <<<")
end

print("== scenario G3 replica with byte trace ==")
wipe_all()
dump("T0 after wipe")

local ui = { menu = { registered_widgets = {}, onTapCloseMenu = function() end } }
UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)
Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
dump("T1 after stage")

package.loaded["apps/filemanager/filemanagermenu"] = {
    new = function(_, opts)
        return { ui = opts.ui, registered_widgets = {},
            setUpdateItemTable = function() error("injected reconstruction crash") end }
    end }
local ok_call, call_err = pcall(function()
    return UIScreens:saveAndApply({ ui = ui }, VIEW, true)
end)
package.loaded["apps/filemanager/filemanagermenu"] = nil
print("saveAndApply escaped?", not ok_call and ("YES: " .. tostring(call_err)) or "no")
dump("T2 after saveAndApply(reload failed)")

-- control: identical flow, healthy reload
wipe_all()
dump("C0 after wipe")
local ui2 = { menu = { registered_widgets = {}, onTapCloseMenu = function() end } }
UIScreens:reconcileRegisteredItems({ ui = ui2 }, VIEW, false)
Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
UIScreens:saveAndApply({ ui = ui2 }, VIEW, true)
dump("C1 after saveAndApply(healthy)")

wipe_all()
print("probe done")

--[[--
probe_reset3.lua — after resetOrder, what does the FRESH staging hold?
isCustomized reads through ensureTxn (staging). If resetOrder's funnel
committed the emptied section but ensureTxn() afterwards re-opened a txn
that stages from... canonical. So staged should be empty too.
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

local MenuOrderManager = require("lib.menuorder_manager")
local IntentStore = require("lib.intent_store")
local NativeWriter = require("lib.native_writer")
local UIScreens = require("lib.ui_screens")

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

MenuOrderManager:resetOrder(view)

-- What does isCustomized see? Dump the staged view it consults.
local staged = MenuOrderManager:stagedView(view)
print("STAGED view contents:")
for coll, v in pairs(staged) do
    local t = type(v)
    if t == "table" then
        print("  " .. tostring(coll) .. " table next=" .. tostring(next(v)))
    else
        print("  " .. tostring(coll) .. " = " .. tostring(v))
    end
end
print("isCustomized=" .. tostring(MenuOrderManager:isCustomized(view)))
print("adapter.isCustomized=" ..
    tostring(require("lib.koreader_adapter").isCustomized(view)))

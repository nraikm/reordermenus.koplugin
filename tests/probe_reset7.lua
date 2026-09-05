--[[--
probe_reset7.lua — minimal repro of the reset residue:
hide calibre, save, resetOrder -> is the file gone?
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

local view = "reader"
local sd = DataStorage:getSettingsDir()
local ORDER_FILE = sd .. "/" .. view .. "_menu_order.lua"
local lfs = require("libs/libkoreader-lfs")
print("settings=" .. sd)

-- NO launch(), no UI: just intent + save + reset.
os.remove(ORDER_FILE)
os.remove(sd .. "/reorderingmenus_intent.lua")
os.remove(sd .. "/reorderingmenus_materialization.lua")
IntentStore.load(true); NativeWriter._resetCaches()
MenuOrderManager:dropSessionState(view)

-- hide + save WITHOUT any registry session: use a minimal reg through
-- saveOrder? saveOrder needs a session. Use launch via ui_screens.
local UIScreens = require("lib.ui_screens")
local function launch()
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, view, false)
end
launch()
MenuOrderManager:setItemHidden(view, "calibre", true, "tools")
MenuOrderManager:saveOrder(view)

-- Manually replicate materializeView's empty-section branch to see which
-- step re-creates the file:
local section = {
    hidden = {}, hidden_order = {}, parent_override = {},
    position_override = {}, order_override = {}, sequence_eras = {},
    custom_menus = {}, separators = {}, raw_override = {}, tab_order = nil,
}
local Materializer = require("lib.materializer")
local Validator = require("lib.validator")
local graph = Materializer.resolve(MenuOrderManager and nil or nil, section)

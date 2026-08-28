--[[--
probe_b2trace.lua — replicate B2 with per-save disk-state tracing.
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

local Manager = require("reorderingmenus_menuorder_manager")
local IntentStore = require("reorderingmenus_intent_store")
local NativeWriter = require("reorderingmenus_native_writer")
local UIScreens = require("reorderingmenus_ui_screens")

local VIEW = "filemanager"
local sd = DataStorage:getSettingsDir()
local ORDER_FILE = sd .. "/" .. VIEW .. "_menu_order.lua"
local lfs = require("libs/libkoreader-lfs")

-- minimal replicas of the suite's helpers
local function wipe()
    os.remove(ORDER_FILE); os.remove(sd .. "/reorderingmenus_materialization.lua")
    os.remove(sd .. "/reorderingmenus_intent.lua")
    IntentStore.load(true); NativeWriter._resetCaches()
    Manager:dropSessionState(VIEW)
    package.loaded["ui/elements/" .. VIEW .. "_menu_order"] = nil
    Manager.orders[VIEW] = nil
    Manager.default_orders[VIEW] = nil
    Manager.recent_moves[VIEW] = {}
end

local function make_stub(widget_name, item_id, hint)
    return {
        name = widget_name,
        addToMainMenu = function(self, menu_items)
            menu_items[item_id] = {
                text = "Stub " .. item_id,
                sorting_hint = hint,
                callback = function() end,
            }
        end,
    }
end

local function launch(widgets)
    local ui = { menu = { registered_widgets = widgets or {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, true)
end
local function disable_project() Manager:dropSessionState(VIEW) end
local function enable_project()
    IntentStore.load(true); NativeWriter._resetCaches()
end

local HINT_HOME = "more_tools"
wipe()
local p_old = make_stub("ghostprov", "ghost_row", HINT_HOME)
launch({ p_old })
Manager:moveItemToMenu(VIEW, "ghost_row", HINT_HOME, "tools")
Manager:saveOrder(VIEW)

disable_project(); enable_project()
launch({})
Manager:saveOrder(VIEW)
print("B1 file exists=" .. tostring(lfs.attributes(ORDER_FILE, "mode") == "file"))

disable_project(); enable_project()
local p_beta = make_stub("betaprov", "ghost_row", HINT_HOME)
launch({ p_beta })
print("B2 parent=" .. tostring(Manager:getParentMenu(VIEW, "ghost_row")))
print("B2 pre-save file=" .. tostring(lfs.attributes(ORDER_FILE, "mode") == "file"))
Manager:saveOrder(VIEW)
print("B2 post-save file=" .. tostring(lfs.attributes(ORDER_FILE, "mode") == "file"))
local rec = NativeWriter.getRecord(VIEW)
print("B2 record.structure=" .. tostring(rec and rec.structure ~= nil))

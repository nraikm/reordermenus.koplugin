--[[--
probe_b2h.lua — B2: after beta-era sync + save, what's in the file and
what does the projection show for ghost_row? (full trace)
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

local Manager = require("lib.menuorder_manager")
local IntentStore = require("lib.intent_store")
local NativeWriter = require("lib.native_writer")
local UIScreens = require("lib.ui_screens")

local VIEW = "filemanager"
local sd = DataStorage:getSettingsDir()
local ORDER_FILE = sd .. "/" .. VIEW .. "_menu_order.lua"
local lfs = require("libs/libkoreader-lfs")

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

disable_project(); enable_project(); launch({})
Manager:saveOrder(VIEW)

disable_project(); enable_project()
launch({ make_stub("betaprov", "ghost_row", HINT_HOME) })
print("B2 parent after launch=" ..
    tostring(Manager:getParentMenu(VIEW, "ghost_row")))

-- What does the file hold BEFORE the save?
print("file exists pre-save=" ..
    tostring(lfs.attributes(ORDER_FILE, "mode") == "file"))

-- The save itself: does it emit?
local ok = Manager:saveOrder(VIEW)
print("save ok=" .. tostring(ok))
print("file exists post-save=" ..
    tostring(lfs.attributes(ORDER_FILE, "mode") == "file"))
if lfs.attributes(ORDER_FILE, "mode") then
    local f = dofile(ORDER_FILE)
    local tools = f["tools"] or {}
    print("tools n=" .. #tools)
    for i, id in ipairs(tools) do
        print(string.format("  tools[%d]=%s", i, tostring(id)))
    end
end

--[[--
probe_p7dbg.lua — replicate P7 step by step; dump canonical vs staged vs
projection at each boundary.
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

local sd = DataStorage:getSettingsDir()
local VIEW = "filemanager"

-- minimal wipe (like wipe_all)
for _, f in ipairs({ "filemanager_menu_order.lua", "reader_menu_order.lua",
    "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua",
    "reorderingmenus_state.lua" }) do os.remove(sd .. "/" .. f) end
local lfs = require("libs/libkoreader-lfs")
for entry in lfs.dir(sd) do
    if entry:find("^reorderingmenus_intent%.lua%.corrupt") then
        os.remove(sd .. "/" .. entry)
    end
end
Manager:dropSessionState(VIEW); Manager:dropSessionState("reader")
IntentStore.load(true)

print("EPOCH after initial load: " .. IntentStore.storeEpoch())

-- plant the P7 payload
local AtomicWriter = require("lib.atomic_writer")
AtomicWriter.writeTable(sd .. "/reorderingmenus_intent.lua", {
    version = 2,
    views = {
        filemanager = {
            hidden = {}, hidden_order = {},
            parent_override = {}, position_override = {},
            order_override = { search =
                { "wikipedia_lookup", "opds", "search_settings",
                  "dictionary_lookup", "dictionary_lookup_history" } },
            custom_menus = {}, separators = {}, raw_override = {},
        },
        reader = {},
    },
    meta = { mirror_changes = false, hidden_in_place = true,
             generation = 0, view_generations = {} },
})

Manager:dropSessionState(VIEW)
print("EPOCH pre-load: " .. IntentStore.storeEpoch())
local st = IntentStore.load(true)
print("EPOCH post-load: " .. IntentStore.storeEpoch())
print("canonical oo.search[1]=" ..
    tostring(st.views.filemanager.order_override.search[1]))

local ui = { menu = { registered_widgets = {} } }
UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)

local staged = Manager:stagedView(VIEW)
print("STAGED oo.search[1]=" ..
    tostring(staged.order_override and staged.order_override.search
        and staged.order_override.search[1] or "NIL"))

local items = Manager:getMenuItems(VIEW, "search")
print("PROJECTION search[1..3]: " .. tostring(items[1]) .. ", "
    .. tostring(items[2]) .. ", " .. tostring(items[3]))

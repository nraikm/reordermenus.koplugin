--[[--
probe_m7dbg.lua — why does the rotated search level not import?
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
local KoreaderAdapter = require("koreader_adapter")

local sd = DataStorage:getSettingsDir()
local VIEW = "filemanager"

for _, f in ipairs({ VIEW .. "_menu_order.lua", "reader_menu_order.lua",
    "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
    os.remove(sd .. "/" .. f)
end
IntentStore.load(true); NativeWriter._resetCaches()
Manager:dropSessionState(VIEW)

local function launch()
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)
end
launch(); Manager:saveOrder(VIEW)

local defaults = KoreaderAdapter.getDefaultOrder(VIEW)
local function without_seps(list)
    local out = {}
    for _, id in ipairs(list or {}) do
        if id ~= "----------------------------" then out[#out + 1] = id end
    end
    return out
end
local function rotated(menu_id)
    local ids = without_seps(defaults[menu_id])
    local head = table.remove(ids, 1)
    table.insert(ids, head)
    return ids
end

KoreaderAdapter.writeNativeOrder(VIEW, {
    search = rotated("search"),
    main = (function()
        local ids = without_seps(defaults.main)
        local out = {}
        for i = #ids, 1, -1 do out[#out + 1] = ids[i] end
        return out
    end)(),
})

Manager:dropSessionState(VIEW); IntentStore.load(true)
NativeWriter._resetCaches(); launch()

print("canonical oo.search? " ..
    tostring(IntentStore.view(VIEW).order_override.search ~= nil))
if IntentStore.view(VIEW).order_override.search then
    for i, id in ipairs(IntentStore.view(VIEW).order_override.search) do
        print("  oo[" .. i .. "]=" .. id)
    end
end
print("observed rotation:")
for _, id in ipairs(rotated("search")) do print("  exp: " .. id) end

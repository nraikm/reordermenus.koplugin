--[[--
probe_historical_dense2.lua — reader dense fixture vs current defaults.
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
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")

local sd = DataStorage:getSettingsDir()
local fx = project_dir .. "/tests/fixtures/historical"

for _, f in ipairs({ "filemanager_menu_order.lua", "reader_menu_order.lua",
    "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua",
    "reorderingmenus_state.lua" }) do
    os.remove(sd .. "/" .. f)
end
IntentStore.load(true); NativeWriter._resetCaches()
Manager:dropSessionState("filemanager"); Manager:dropSessionState("reader")

local src = io.open(fx .. "/dense-era_reader_menu_order.lua", "r")
local bytes = src:read("*a"); src:close()
local dst = io.open(sd .. "/reader_menu_order.lua", "w")
dst:write(bytes); dst:close()

local ui = { menu = { registered_widgets = {} } }
UIScreens:reconcileRegisteredItems({ ui = ui }, "reader", false)

local sec = IntentStore.view("reader")
print("PROBE reader order_override keys:")
for k in pairs(sec.order_override) do print("  oo: " .. k) end
print("PROBE hidden:")
for k in pairs(sec.hidden) do print("  hid: " .. k) end

-- which fixture keys are unknown to current defaults?
local defaults = KoreaderAdapter.getDefaultOrder("reader")
local native = KoreaderAdapter.readNativeOrder("reader")
print("PROBE fixture keys not in current defaults:")
for k in pairs(native) do
    if defaults[k] == nil and not NativeWriter.RESERVED[k] then
        print("  unknown level: " .. k)
    end
end
print("PROBE known-level diffs:")
for k in pairs(defaults) do
    if type(defaults[k]) == "table" then
        local d, n = defaults[k], native[k] or {}
        if #d ~= #n then
            print(string.format("  %s: len default=%d fixture=%d", k, #d, #n))
        else
            for i = 1, #d do
                if d[i] ~= n[i] then
                    print(string.format("  %s: first diff at %d (%s vs %s)",
                        k, i, tostring(d[i]), tostring(n[i])))
                    break
                end
            end
        end
    end
end
os.remove(sd .. "/reader_menu_order.lua")
print("PROBE done")

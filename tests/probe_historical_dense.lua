--[[--
probe_historical_dense.lua — how does CURRENT code classify the real
dense-era backup files (pre-sparse design output, no sidecar)?
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
local KoreaderAdapter = require("lib.koreader_adapter")

local sd = DataStorage:getSettingsDir()
local fx = project_dir .. "/tests/fixtures/historical"

for _, view in ipairs({ "filemanager", "reader" }) do
    for _, f in ipairs({ "filemanager_menu_order.lua", "reader_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua",
        "reorderingmenus_state.lua" }) do
        os.remove(sd .. "/" .. f)
    end
end
IntentStore.load(true); NativeWriter._resetCaches()
Manager:dropSessionState("filemanager"); Manager:dropSessionState("reader")

-- copy the dense-era file into place
local src = io.open(fx .. "/dense-era_filemanager_menu_order.lua", "r")
local bytes = src:read("*a"); src:close()
local dst = io.open(sd .. "/filemanager_menu_order.lua", "w")
dst:write(bytes); dst:close()

local ui = { menu = { registered_widgets = {} } }
UIScreens:reconcileRegisteredItems({ ui = ui }, "filemanager", false)

local sec = IntentStore.view("filemanager")
print("PROBE order_override keys:")
for k in pairs(sec.order_override) do print("  oo: " .. k) end
print("PROBE hidden:")
for k in pairs(sec.hidden) do print("  hid: " .. k) end
print("PROBE parent_override:")
for k in pairs(sec.parent_override) do print("  po: " .. k .. " -> " ..
    tostring(sec.parent_override[k].parent)) end
print("PROBE raw_override:")
for k in pairs(sec.raw_override) do print("  raw: " .. k) end
print("PROBE projection search[1..4]:")
local items = Manager:getMenuItems("filemanager", "search")
for i = 1, math.min(4, #items) do print("  " .. i .. ": " .. tostring(items[i])) end
print("PROBE parent(opds)=" .. tostring(Manager:getParentMenu("filemanager", "opds")))
print("PROBE main[1..3]:")
items = Manager:getMenuItems("filemanager", "main")
for i = 1, math.min(3, #items) do print("  " .. i .. ": " .. tostring(items[i])) end

-- compare fixture vs current defaults per key
local defaults = KoreaderAdapter.getDefaultOrder("filemanager")
local native = KoreaderAdapter.readNativeOrder("filemanager")
print("PROBE default-vs-fixture diffs:")
for k in pairs(defaults) do
    if type(defaults[k]) == "table" then
        local d = defaults[k]
        local n = native[k] or {}
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
for k in pairs(native) do
    if defaults[k] == nil and not NativeWriter.RESERVED[k] then
        print("  " .. k .. ": NOT IN CURRENT DEFAULTS")
    end
end
os.remove(sd .. "/filemanager_menu_order.lua")
print("PROBE done")

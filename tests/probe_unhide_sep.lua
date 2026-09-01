-- Minimal: hide a stock-resident item adjacent to a divider, unhide, save,
-- reload, compare. Uses the REAL setting menu (stock separator before
-- taps_and_gestures).
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

local view = "filemanager"
local function fp()
    local o = Manager:loadOrder(view)
    return table.concat(o.setting or {}, ",")
end

print("baseline setting:", fp())

-- 1. hide a mid-list item (network sits after the stock divider)
Manager:setItemHidden(view, "network", true, "setting")
Manager:saveOrder(view)
print("after hide   :", fp())
print("separators in intent:")
for k, v in pairs(IntentStore.view(view).separators or {}) do
    print("  ", k, v.parent, tostring(v.after))
end

-- 2. external-edit style round trip that DOUBLES the divider (as the fuzzer's
--    imported file showed), then import it.
local KoreaderAdapter = require("koreader_adapter")
local path = KoreaderAdapter.getNativePath(view)
local f = assert(io.open(path, "r"))
local content = f:read("*a") ; f:close()
local native = load(content:gsub('^%-%-[^\n]*\n', ''))()
local s = {}
for i, x in ipairs(native.setting) do
    table.insert(s, x)
    if x == "----------------------------" and (native.setting[i+1] == "taps_and_gestures") then
        table.insert(s, "----------------------------")
    end
end
native.setting = s
KoreaderAdapter.writeNativeOrder(view, native)
Manager:reloadFromDisk(view)
Manager:saveOrder(view)
print("after ext-import doubling:", fp())
for k, v in pairs(IntentStore.view(view).separators or {}) do
    print("  sep:", k, v.parent, tostring(v.after))
end

-- 3. unhide network (the fuzz op) then round-trip
Manager:setItemHidden(view, "network", false)
Manager:saveOrder(view)
print("after unhide :", fp())
Manager:reloadFromDisk(view)
local b = fp()
Manager:saveOrder(view)
local a = fp()
Manager:reloadFromDisk(view)
local c = fp()
print("unhide roundtrip:", b == a, a == c)
if b ~= a then print("B:", b); print("A:", a) end

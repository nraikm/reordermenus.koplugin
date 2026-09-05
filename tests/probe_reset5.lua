--[[--
probe_reset5.lua — trace writeView during reset: what does graphToNative
emit and why does the reserved-only file survive?
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

local Materializer = require("lib.materializer")
local Validator = require("lib.validator")
local NativeWriter = require("lib.native_writer")
local KoreaderAdapter = require("lib.koreader_adapter")
local Registry = require("lib.registry")

local view = "reader"
local sd = DataStorage:getSettingsDir()

-- Simulate the reset-time state: empty intent, previous emission had a
-- non-empty disabled set.
local defaults = dofile("/Applications/KOReader.app/Contents/koreader/frontend/ui/elements/reader_menu_order.lua")
local reg = Registry.buildFromData(defaults, {}, {})

-- previous record: structure WITH non-empty disabled (as after hide save)
local prev_structure = {
    tools = { "calibre" },
    ["KOMenu:disabled"] = { "calibre" },
    ["KOMenu:custom_submenus"] = {},
}
-- Reproduce stripEmptyReservedMaps decision:
local native = {
    ["KOMenu:disabled"] = {},
    ["KOMenu:custom_submenus"] = {},
}
print("reserved-only? " ..
    tostring((function()
        for key in pairs(native) do
            if not NativeWriter.RESERVED[key] then return false end
        end
        return true
    end)()))
local record = { structure = prev_structure }
local previous = record and record.structure
for _, key in ipairs({ "KOMenu:disabled", "KOMenu:custom_submenus" }) do
    local value = type(previous) == "table" and previous[key] or nil
    print(string.format("prev[%s] is table-nonempty=%s",
        key, tostring(type(value) == "table" and next(value) ~= nil)))
end

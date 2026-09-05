--[[--
probe_m7diff.lua — what does infer_list_change say about the rotation?
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

local SemanticDiff = require("lib.semantic_diff")

local defaults = dofile("/Applications/KOReader.app/Contents/koreader/frontend/ui/elements/filemanager_menu_order.lua")
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

local old = defaults.search
local new = rotated("search")
print("old (" .. #old .. "): " .. table.concat(old, ","))
print("new (" .. #new .. "): " .. table.concat(new, ","))

local d = SemanticDiff.infer_list_change(old, new)
print("kind=" .. tostring(d and d.kind))
if d then
    for k, v in pairs(d) do
        if type(v) == "table" then
            print("  " .. k .. " = [" .. table.concat(v, ",") .. "]")
        else
            print("  " .. k .. " = " .. tostring(v))
        end
    end
end

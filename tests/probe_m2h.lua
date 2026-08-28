--[[--
probe_m2h.lua — after FIX-3, the pristine save leaves NO record at all
(clearRecord removes it). recordNeedsMaterialization then stays true
forever: every later save re-runs the maintenance branch, but the
checkpoint is never established, so the first external edit classifies as
"legacy" instead of "external". Verify and fix by writing a real empty
emission checkpoint (structure=nil, writer_version stamped) instead of
clearing.
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
CanvasContext = require("device") -- placeholder no-op
CanvasContext = require("document/canvascontext")
local _ = require("gettext")

print("probe loaded")

--[[--
probe_t7d.lua — T7 under KO_HOME isolation: which import mode fires and why.
--]]

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
print("settings dir = " .. DataStorage:getSettingsDir())

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))
package.path = project_dir .. "/?.lua;" .. package.path

local DataStorage2 = require("datastorage")
print("settings dir after setupkoenv = " .. DataStorage2:getSettingsDir())

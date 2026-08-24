--[[--
probe_dumpfmt.lua — what does the persisted intent file's header look like?
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

local AtomicWriter = require("reorderingmenus_atomic_writer")
local IntentStore = require("reorderingmenus_intent_store")

local sd = DataStorage:getSettingsDir()
os.remove(sd .. "/reorderingmenus_intent.lua")
IntentStore.load(true)
IntentStore.view("filemanager")  -- touch
IntentStore.save()

local f = io.open(sd .. "/reorderingmenus_intent.lua", "r")
local body = f:read("*a"); f:close()
print("HEAD:")
print(body:sub(1, 400))

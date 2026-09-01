--[[
probe_e_reset_sweep.lua — does resetOrder(fm) COMMIT unsaved reader staging?
Prints every line explicitly.
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

local sd = DataStorage:getSettingsDir()
local VIEW = "filemanager"

for _, f in ipairs({ "filemanager_menu_order.lua", "reader_menu_order.lua",
    "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
    os.remove(sd .. "/" .. f)
end
IntentStore.load(true); NativeWriter._resetCaches()
Manager.recent_moves.filemanager = {}
Manager.recent_moves.reader = {}
Manager:dropSessionState(VIEW); Manager:dropSessionState("reader")

local function reader_dirt_canon() return IntentStore.view("reader").hidden.book_status ~= nil end

print("step A: gen=" .. IntentStore.generation())
Manager:setItemHidden("reader", "book_status", true, nil)
print("step B: reader staged dirt; canon_reader_has_dirt=" ..
    tostring(reader_dirt_canon()) .. " gen=" .. IntentStore.generation())

-- inspect intent file directly
local f = io.open(sd .. "/reorderingmenus_intent.lua", "r")
print("step B2: intent file exists on disk? " .. tostring(f ~= nil))
if f then f:close() end

local ok = Manager:resetOrder(VIEW)
print("step C: resetOrder(fm)=" .. tostring(ok) ..
    " canon_reader_has_dirt=" .. tostring(reader_dirt_canon()) ..
    " gen=" .. IntentStore.generation())

f = io.open(sd .. "/reorderingmenus_intent.lua", "r")
local body = f and f:read("*a") or ""
if f then f:close() end
print("step C2: DISK carries reader dirt after reset? " ..
    tostring(body:find("book_status", 1, true) ~= nil))

os.exit(0)

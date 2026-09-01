--[[
probe_e_durability.lua — minimal reproduction for E1d/E5b failures.

Question: when a child transaction commits (calibre hidden) and we later
force-reload from disk, why is the record gone?

Distinguishes:
  (a) commit never wrote the record to disk,
  (b) a later write overwrote the file,
  (c) IntentStore.load() repair strips the record and rewrites the file.
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

local sd = DataStorage:getSettingsDir()
local VIEW = "filemanager"
local INTENT = sd .. "/reorderingmenus_intent.lua"

local function wipe_all()
    for _, f in ipairs({ "filemanager_menu_order.lua", "reader_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        os.remove(sd .. "/" .. f)
    end
    os.execute("rm -rf " .. sd .. "/menu_order_presets")
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}
    Manager.recent_moves.reader = {}
    Manager:dropSessionState(VIEW)
    Manager:dropSessionState("reader")
end

local function file_has(pattern)
    local f = io.open(INTENT, "r")
    if not f then return "NO FILE" end
    local body = f:read("*a")
    f:close()
    return body:find(pattern, 1, true) ~= nil
end

local function canon()
    local h = IntentStore.view(VIEW).hidden or {}
    local parts = {}
    for k, v in pairs(h) do
        parts[#parts+1] = k .. "(" .. tostring(v.origin) .. ")"
    end
    return table.concat(parts, ",")
end

print("== E1 replica ==")
wipe_all()
print("[1] after wipe:          gen=", IntentStore.generation(),
    " file_has_calibre=", tostring(file_has("calibre")))

Manager:backupOrder(VIEW)                                   -- parent opens
Manager:setItemHidden(VIEW, "history", true, "main")        -- parent staged
print("[2] parent staged:       gen=", IntentStore.generation(),
    " canon=", canon(), " file_has_calibre=", tostring(file_has("calibre")))

Manager:backupOrder(VIEW)                                   -- child opens
Manager:setItemHidden(VIEW, "calibre", true, "more_tools")  -- child staged
local ok = Manager:saveOrder(VIEW)                          -- child saves
print("[3] child saved ok=", ok, "  gen=", IntentStore.generation(),
    " canon=", canon(), " file_has_calibre=", tostring(file_has("calibre")))

local restored = Manager:restoreOrder(VIEW)                 -- parent discards
print("[4] parent discarded (", restored, "): gen=", IntentStore.generation(),
    " canon=", canon(), " file_has_calibre=", tostring(file_has("calibre")))

Manager:dropSessionState(VIEW)
local _, problems = IntentStore.load(true)
local plist = {}
for _, p in ipairs(problems or {}) do
    plist[#plist+1] = p.kind .. "/" .. tostring(p.collection) .. "/" .. tostring(p.key)
end
print("[5] after load(true):    gen=", IntentStore.generation(),
    " canon=", canon(), " file_has_calibre=", tostring(file_has("calibre")))
print("    problems=", #plist, table.concat(plist, " | "))

print("")
print("== E5 replica (preset applied from nested context) ==")
wipe_all()
Manager:setItemHidden(VIEW, "screensaver", true, "screen")
Manager:saveOrder(VIEW)
print("[1] baseline:            gen=", IntentStore.generation(), " canon=", canon())
print("    savePreset:", Manager:savePreset(VIEW, "ProbeNested"))

Manager:backupOrder(VIEW)                                   -- outer editor
Manager:setItemHidden(VIEW, "history", true, "main")        -- outer staged
print("[2] outer staged:        gen=", IntentStore.generation(), " canon=", canon())

print("    loadPreset:", Manager:loadPreset(VIEW, "ProbeNested"))
print("[3] preset applied:      gen=", IntentStore.generation(), " canon=", canon(),
    " file_has_screensaver=", tostring(file_has("screensaver")))

print("    restoreOrder:", Manager:restoreOrder(VIEW))
print("[4] outer discarded:     gen=", IntentStore.generation(), " canon=", canon(),
    " file_has_screensaver=", tostring(file_has("screensaver")))

Manager:dropSessionState(VIEW)
local _, problems2 = IntentStore.load(true)
local plist2 = {}
for _, p in ipairs(problems2 or {}) do
    plist2[#plist2+1] = p.kind .. "/" .. tostring(p.collection) .. "/" .. tostring(p.key)
end
print("[5] after load(true):    gen=", IntentStore.generation(), " canon=", canon(),
    " file_has_screensaver=", tostring(file_has("screensaver")))
print("    problems=", #plist2, table.concat(plist2, " | "))

wipe_all()
print("probe done")

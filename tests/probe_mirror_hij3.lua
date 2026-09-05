--[[-- probe_mirror_hij3.lua — P1 refined: what does the mirror stage when the
destination is FM-only? staged vs committed, before and after saves. --]]
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

local sd = DataStorage:getSettingsDir()
local function wipe_all()
    for _, f in ipairs({ "filemanager_menu_order.lua", "reader_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        os.remove(sd .. "/" .. f)
    end
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}
    Manager.recent_moves.reader = {}
    Manager:dropSessionState("filemanager")
    Manager:dropSessionState("reader")
end

local function rec(v)
    if type(v) ~= "table" then return tostring(v) end
    local p = {}
    for k, val in pairs(v) do
        p[#p+1] = tostring(k) .. "=" .. (type(val) == "table"
            and "{" .. rec(val) .. "}" or tostring(val))
    end
    return "{" .. table.concat(p, ",") .. "}"
end

print("\n=== P1b: staged mirror record for FM-only destination ===")
wipe_all()
Manager:setMirroringEnabled(true)
Manager:setLiveRegistrations("reader",
    { mir_p1 = { sorting_hint = "more_tools" } }, { mir_p1 = "prov_r" })
Manager:setLiveRegistrations("filemanager",
    { mir_p1 = { sorting_hint = "more_tools" } }, { mir_p1 = "prov_f" })
Manager:reconcileRegisteredItems("reader",
    { mir_p1 = { sorting_hint = "more_tools" } }, { mir_p1 = "prov_r" })
Manager:reconcileRegisteredItems("filemanager",
    { mir_p1 = { sorting_hint = "more_tools" } }, { mir_p1 = "prov_f" })
Manager:saveOrder("reader"); Manager:saveOrder("filemanager")

print("pre-move  reader staged po: " .. rec(Manager:stagedView("reader").parent_override.mir_p1))
print("pre-move  reader commtd po: " .. rec(IntentStore.view("reader").parent_override.mir_p1))

local ok = Manager:moveItemToMenu("filemanager", "mir_p1", "more_tools", "filemanager_settings")
print("move ok=" .. tostring(ok))
print("post-move reader staged po: " .. rec(Manager:stagedView("reader").parent_override.mir_p1))
print("post-move reader commtd po: " .. rec(IntentStore.view("reader").parent_override.mir_p1))

print("gen before saves: fm=" .. IntentStore.generation("filemanager")
    .. " reader=" .. IntentStore.generation("reader"))
Manager:saveOrder("filemanager")
print("after fm save:   fm=" .. IntentStore.generation("filemanager")
    .. " reader=" .. IntentStore.generation("reader"))
print("post-fmsave reader commtd po: " .. rec(IntentStore.view("reader").parent_override.mir_p1))
print("reader projected parent: " .. tostring(Manager:getParentMenu("reader", "mir_p1")))
local r_list = Manager:getMenuItems("reader", "more_tools")
local found = false
for _, id in ipairs(r_list) do if id == "mir_p1" then found = true end end
print("mir_p1 visible in reader more_tools: " .. tostring(found))
Manager:saveOrder("reader")
print("post-readersave reader commtd po: " .. rec(IntentStore.view("reader").parent_override.mir_p1))
wipe_all()
print("done")

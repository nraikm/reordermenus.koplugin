dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = "/Users/nr/Development/ReorderingMenus/tests/probe_bug3.lua"
local project_dir = "/Users/nr/Development/ReorderingMenus"
package.path = project_dir .. "/?.lua;" .. package.path
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
require("main")
local Manager = require("reorderingmenus_menuorder_manager")

Manager:setLiveRegistrations("filemanager", {}, {})
Manager:setLiveRegistrations("reader", {}, {})
Manager:refreshRegistry("filemanager"); Manager:refreshRegistry("reader")

local menu = "taps_and_gestures"
local items = Manager:getMenuItems("filemanager", menu)
local nonsep = {}
for _, id in ipairs(items) do if id ~= Manager.SEPARATOR_ID then nonsep[#nonsep+1]=id end end
local rev = {}
for i=#nonsep,1,-1 do rev[#rev+1]=nonsep[i] end
Manager:stageList("filemanager", menu, rev)
Manager:restoreItemDefault("filemanager", nonsep[1])
Manager:resetOrder("filemanager")

-- bypass ALL caches: what does Materializer say with truly empty intent?
local Registry = require("reorderingmenus_registry")
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
local reg = Registry.buildFromData(KoreaderAdapter.getDefaultOrder("filemanager"), KoreaderAdapter.collectLiveRegistrations(nil))
local g = Materializer.resolve(reg, Materializer.emptyIntent())
print("pure resolve taps:", table.concat(g.lists["taps_and_gestures"] or {}, ","))
print("manager says     :", table.concat(Manager:getMenuItems("filemanager", menu), ","))
local IntentStore = require("reorderingmenus_intent_store")
local cs = IntentStore.view("filemanager")
for coll, tbl in pairs(cs) do
    if type(tbl)=="table" then
        local n=0; for _ in pairs(tbl) do n=n+1 end
        if n>0 then
            print("CANONICAL", coll, n)
            for k,v in pairs(tbl) do print("   ", coll, k, type(v)=="table" and require("dump")(v):gsub("%s+"," "):sub(1,80) or tostring(v)) break end
        end
    end
end

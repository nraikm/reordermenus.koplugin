--[[--
probe_tab_unhide_paths.lua — does the Hidden Items Manager path restore tabs?

UI paths that un-hide things:
  A) Tab reorder dialog / editor checkbox -> Manager:setTabHidden(view,id,false)
  B) Hidden Items Manager rows iterate getDisabledItems(view), which INCLUDES
     hidden tabs, and call Manager:setItemHidden(view,id,false)

If B leaves a parent_override {parent="KOMenu:menu_buttons"} record instead of
clearing the hidden record like A does, does the tab actually come back?
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
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
require("main")

local Manager = require("menuorder_manager")
local IntentStore = require("intent_store")
local KoreaderAdapter = require("koreader_adapter")

local function wipe()
    local sd = KoreaderAdapter.getSettingsDir()
    os.remove(KoreaderAdapter.getNativePath("filemanager"))
    os.remove(KoreaderAdapter.getNativePath("reader"))
    os.remove(sd .. "/reorderingmenus_intent.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    Manager:resetOrder("filemanager"); Manager:resetOrder("reader")
    Manager:dropSessionState("filemanager"); Manager:dropSessionState("reader")
    IntentStore.load(true)
end

local function tabbar()
    return table.concat(Manager:loadOrder("filemanager")["KOMenu:menu_buttons"] or {}, ",")
end

print("baseline bar:", tabbar())

-- Path A: hide then unhide via setTabHidden
wipe()
Manager:setTabHidden("filemanager", "setting", true)
print("A hide ok:", Manager:isItemHidden("filemanager", "setting"),
      "| bar:", tabbar())
Manager:setTabHidden("filemanager", "setting", false)
local sec = IntentStore.load().views.filemanager
local recs = {}
for k in pairs(sec.hidden or {}) do recs[#recs+1] = k end
print("A unhide -> visible:", not Manager:isItemHidden("filemanager", "setting"),
      "| residual hidden records:", #recs, "| bar:", tabbar())
print("A save:", Manager:saveOrder("filemanager"), "| bar after save:", tabbar())
sec = IntentStore.load().views.filemanager
local po = {}
for k, v in pairs(sec.parent_override or {}) do po[#po+1] = k .. "->" .. tostring(v.parent) end
print("A canonical parent_override:", table.concat(po, " ") == "" and "(none)" or table.concat(po, " "))

-- Path B: hide then unhide via setItemHidden (what showHiddenItemsManager does)
wipe()
Manager:setTabHidden("filemanager", "setting", true)
print("\nB hide ok:", Manager:isItemHidden("filemanager", "setting"),
      "| disabled list contains setting:",
      (function()
          for _, id in ipairs(Manager:getDisabledItems("filemanager")) do
              if id == "setting" then return true end
          end
          return false
      end)())
Manager:setItemHidden("filemanager", "setting", false)   -- manager-row path
print("B unhide -> visible flag:", not Manager:isItemHidden("filemanager", "setting"),
      "| bar NOW:", tabbar())
print("B save:", Manager:saveOrder("filemanager"), "| bar after save:", tabbar())
Manager:dropSessionState("filemanager"); IntentStore.load(true)  -- restart sim
print("B bar after RESTART:", tabbar())
sec = IntentStore.load().views.filemanager
po = {}
for k, v in pairs(sec.parent_override or {}) do po[#po+1] = k .. "->" .. tostring(v.parent) end
print("B canonical parent_override:",
    table.concat(po, " ") == "" and "(none)" or table.concat(po, " "))
for k in pairs(sec.hidden or {}) do print("B residual hidden record:", k) end

-- Path C: what the SM fixture saw - unhide_all BEFORE any save, then check
wipe()
Manager:setTabHidden("filemanager", "setting", true)
Manager:setItemHidden("filemanager", "setting", false)
print("\nC unsave-path visible flag:", not Manager:isItemHidden("filemanager", "setting"),
      "| bar NOW:", tabbar())
print("C save:", Manager:saveOrder("filemanager"), "| bar after save:", tabbar())
print("probe done")

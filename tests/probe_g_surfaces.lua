--[[
probe_g_surfaces.lua — observe actual behavior under each of the four
live-reload failure injections before codifying them in the G suite.

Surfaces:
  G1 Reader reload:    apps/reader/modules/readermenu :new throws
  G2 FM reload:        apps/filemanager/filemanagermenu :new throws
  G3 reconstruction:   menu builds but setUpdateItemTable throws
  G4 refresh callback: success toast (showNotice) throws after commit
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

local Manager = require("lib.menuorder_manager")
local IntentStore = require("lib.intent_store")
local NativeWriter = require("lib.native_writer")
local UIScreens = require("lib.ui_screens")

local sd = DataStorage:getSettingsDir()
local VIEW = "filemanager"

local function wipe_all()
    for _, f in ipairs({ "filemanager_menu_order.lua", "reader_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        os.remove(sd .. "/" .. f)
    end
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}
    Manager.recent_moves.reader = {}
    Manager:dropSessionState(VIEW)
    Manager:dropSessionState("reader")
end

local function intent_file_has(pat)
    local f = io.open(sd .. "/reorderingmenus_intent.lua", "r")
    if not f then return false end
    local body = f:read("*a"); f:close()
    return body:find(pat, 1, true) ~= nil
end

local function native_has_opds_in_tools()
    local f = io.open(sd .. "/filemanager_menu_order.lua", "r")
    if not f then return "NO FILE" end
    local body = f:read("*a"); f:close()
    -- crude section check: tools = { ... "opds" ... }
    -- quoted-key format: ["tools"] = { ... }
    local tools = body:match('%["tools"%]%s*=%s*%{(.-)%}')
    return tools and tools:find("opds", 1, true) ~= nil or false
end

-- minimal fm-shaped ui: menu container present, no document => FM branch
local function fm_ui()
    return {
        menu = {
            registered_widgets = {},
            onTapCloseMenu = function() end,
        },
    }
end

print("== baseline healthy saveAndApply ==")
wipe_all()
local ui = fm_ui()
UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)
Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
local ok, path = UIScreens:saveAndApply({ ui = ui }, VIEW, true)
print("saveAndApply ok=", ok, " needs_restart=", tostring(UIScreens.needs_restart))
print("native opds-in-tools=", tostring(native_has_opds_in_tools()))

for _, scenario in ipairs({
    { name = "G1 reader-module-throws", reader = true,
      inject = function()
          package.loaded["apps/reader/modules/readermenu"] =
              { new = function() error("injected reader reload crash") end }
      end,
      restore = function()
          package.loaded["apps/reader/modules/readermenu"] = nil
      end },
    { name = "G2 fm-module-throws", reader = false,
      inject = function()
          package.loaded["apps/filemanager/filemanagermenu"] =
              { new = function() error("injected fm reload crash") end }
      end,
      restore = function()
          package.loaded["apps/filemanager/filemanagermenu"] = nil
      end },
    { name = "G3 reconstruction-throws", reader = false,
      inject = function()
          package.loaded["apps/filemanager/filemanagermenu"] = {
              new = function(_, opts)
                  return {
                      ui = opts.ui,
                      registered_widgets = {},
                      setUpdateItemTable = function()
                          error("injected live menu reconstruction crash")
                      end,
                  }
              end }
      end,
      restore = function()
          package.loaded["apps/filemanager/filemanagermenu"] = nil
      end },
}) do
    print("")
    print("== " .. scenario.name .. " ==")
    wipe_all()
    local ui2 = fm_ui()
    UIScreens:reconcileRegisteredItems({ ui = ui2 }, VIEW, false)
    Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
    local gen_before = IntentStore.generation()

    scenario.inject()
    local ok_call, call_err = pcall(function()
        return UIScreens:saveAndApply({ ui = ui2 }, VIEW, true)
    end)
    scenario.restore()

    print("saveAndApply escaped?", not ok_call and ("YES: " .. tostring(call_err)) or "no",
        " returned=", ok_call and tostring(ok_call) .. "," .. tostring(select(2, pcall(function() return true end)) or "") or "-")
    print("generation:", gen_before, "->", IntentStore.generation())
    print("canon parent_override.opds:",
        tostring(IntentStore.view(VIEW).parent_override.opds ~= nil))
    print("intent file has opds:", tostring(intent_file_has("opds")))
    print("native opds-in-tools=", tostring(native_has_opds_in_tools()))
    print("needs_restart=", tostring(UIScreens.needs_restart))

    Manager:dropSessionState(VIEW); IntentStore.load(true)
    print("fresh getParentMenu(opds)=", tostring(Manager:getParentMenu(VIEW, "opds")))
    local gen_after_fresh = IntentStore.generation()
    Manager:saveOrder(VIEW)
    print("re-save after fresh build changed gen?",
        gen_after_fresh ~= IntentStore.generation())
end

-- G4: success-toast throws after the commit
print("")
print("== G4 showNotice-throws ==")
wipe_all()
local ui3 = fm_ui()
UIScreens:reconcileRegisteredItems({ ui = ui3 }, VIEW, false)
Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
local gen_before = IntentStore.generation()
local real_notice = UIScreens.showNotice
UIScreens.showNotice = function() error("injected refresh callback crash") end
local ok_call, call_err = pcall(function()
    return UIScreens:saveAndApply({ ui = ui3 }, VIEW, false)  -- non-silent => notice
end)
UIScreens.showNotice = real_notice
print("saveAndApply escaped?", not ok_call and ("YES: " .. tostring(call_err)) or "no")
print("generation:", gen_before, "->", IntentStore.generation())
print("canon parent_override.opds:",
    tostring(IntentStore.view(VIEW).parent_override.opds ~= nil))
print("intent file has opds:", tostring(intent_file_has("opds")))
print("native opds-in-tools=", tostring(native_has_opds_in_tools()))
print("needs_restart=", tostring(UIScreens.needs_restart))
Manager:dropSessionState(VIEW); IntentStore.load(true)
print("fresh getParentMenu(opds)=", tostring(Manager:getParentMenu(VIEW, "opds")))

wipe_all()
print("probe done")

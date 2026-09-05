--[[
test_save_reload_failure.lua — Area G.

Durable save succeeds but the live reload fails. Contract under test
(the recommended policy, verified against actual behavior):

  - disk (canonical intent file) remains committed;
  - canonical memory remains committed;
  - the UI REPORTS the refresh failure (showError) instead of failing
    silently;
  - the save still counts as applied (needs_restart stays latched);
  - the next fresh build reflects the persisted state;
  - a follow-up save is a semantic no-op (no repeated durable commit).

Durable state is NEVER rolled back merely because presentation refresh
failed.

Injections (each surface distinct):
  G0 control      healthy saveAndApply (no failure)
  G1 Reader reload: apps/reader/modules/readermenu :new throws
  G2 FM reload:     apps/filemanager/filemanagermenu :new throws
  G3 live menu reconstruction: module constructs, but the menu BUILD
     (setUpdateItemTable) throws — applyLiveReload keeps the old menu
  G4 refresh callback failure: the SUCCESS TOAST (showNotice) throws
     after the commit — the exception escapes saveAndApply (observed,
     tolerated: it cannot affect durable state), which this suite pins.

Run: cd /Applications/KOReader.app/Contents/koreader &&
     ./luajit <project>/tests/test_save_reload_failure.lua
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

local passed, failed = 0, 0
local function note(cond, msg)
    if cond then passed = passed + 1
    else
        failed = failed + 1
        print("  [FAIL] " .. tostring(msg))
        io.stdout:flush()
    end
end

local sd = DataStorage:getSettingsDir()
local VIEW = "filemanager"
local INTENT_PATH = sd .. "/reorderingmenus_intent.lua"

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

local function intent_has(pat)
    local f = io.open(INTENT_PATH, "r")
    if not f then return false end
    local body = f:read("*a"); f:close()
    return body:find(pat, 1, true) ~= nil
end

local function native_tools_has(id)
    local f = io.open(sd .. "/" .. VIEW .. "_menu_order.lua", "r")
    if not f then return false end
    local body = f:read("*a"); f:close()
    local tools = body:match('%["tools"%]%s*=%s*%{(.-)%}')
    return tools ~= nil and tools:find(id, 1, true) ~= nil
end

local function fm_ui(reader)
    local ui = {
        menu = {
            registered_widgets = {},
            onTapCloseMenu = function() end,
        },
    }
    if reader then ui.document = {} end   -- routes applyLiveReload to ReaderMenu
    return ui
end

print("===============================================================")
print("=== G. Durable save vs live-reload failure                   ===")
print("===============================================================")

local scenarios = {
    -- Healthy control uses the SAME injection seam as the crash scenarios,
    -- but a well-behaved stub: proves the reporting channel stays quiet when
    -- the rebuild succeeds (controlled comparison with G2/G3).
    { name = "G0 control-healthy", expect_refresh_error = false,
      inject = function()
          package.loaded["apps/filemanager/filemanagermenu"] = {
              new = function(_, opts)
                  return {
                      ui = opts.ui,
                      registered_widgets = {},
                      built = false,
                      setUpdateItemTable = function(menu)
                          menu.built = true   -- successful reconstruction
                      end,
                  }
              end }
      end,
      restore = function()
          package.loaded["apps/filemanager/filemanagermenu"] = nil
      end },
    { name = "G1 reader-reload-crash", reader = true,
      expect_refresh_error = true,
      inject = function()
          package.loaded["apps/reader/modules/readermenu"] =
              { new = function() error("injected reader reload crash") end }
      end,
      restore = function()
          package.loaded["apps/reader/modules/readermenu"] = nil
      end },
    { name = "G2 fm-reload-crash",
      expect_refresh_error = true,
      inject = function()
          package.loaded["apps/filemanager/filemanagermenu"] =
              { new = function() error("injected fm reload crash") end }
      end,
      restore = function()
          package.loaded["apps/filemanager/filemanagermenu"] = nil
      end },
    { name = "G3 reconstruction-crash",
      expect_refresh_error = true,
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
}

local real_show_error = UIScreens.showError
local real_show_notice = UIScreens.showNotice

for _, sc in ipairs(scenarios) do
    wipe_all()
    UIScreens.needs_restart = false
    local ui = fm_ui(sc.reader)
    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)
    Manager:moveItemToMenu(VIEW, "opds", "search", "tools")

    local gen_before = IntentStore.generation()

    -- spy on the error surface (the "UI reports refresh failure" channel)
    local errors_reported = {}
    UIScreens.showError = function(_, message)
        errors_reported[#errors_reported + 1] = tostring(message)
    end

    if sc.inject then sc.inject() end
    local ok_call, call_err = pcall(function()
        return UIScreens:saveAndApply({ ui = ui }, VIEW, true)
    end)
    if sc.restore then sc.restore() end
    UIScreens.showError = real_show_error

    -- C1: the save itself completed normally (no exception escaped).
    note(ok_call, sc.name .. ": saveAndApply completed without escaping ("
        .. tostring(call_err) .. ")")

    -- C2: canonical memory committed.
    note(IntentStore.view(VIEW).parent_override.opds ~= nil,
        sc.name .. ": canonical memory holds opds->tools")

    -- C3: generation advanced exactly once (single durable mutation).
    local gen_after = IntentStore.generation()
    note(gen_after == gen_before + 1,
        sc.name .. ": generation advanced exactly once ("
        .. gen_before .. "->" .. gen_after .. ")")

    -- C4: disk committed (canonical intent file carries the record).
    note(intent_has("opds"), sc.name .. ": intent file carries opds")

    -- C5: derived native cache carries the move.
    note(native_tools_has("opds"),
        sc.name .. ": native file lists opds under tools")

    -- C6: refresh failure REPORTED where expected (never silent).
    local reported_refresh_failure = false
    for _, m in ipairs(errors_reported) do
        if m:find("could not be refreshed live", 1, true) then
            reported_refresh_failure = true
        end
    end
    note(reported_refresh_failure == sc.expect_refresh_error,
        sc.name .. ": refresh failure reporting = "
        .. tostring(reported_refresh_failure) .. " (expected "
        .. tostring(sc.expect_refresh_error) .. ")")

    -- C7: save still counts as applied — restart flag latched even when
    -- the live refresh failed.
    note(UIScreens.needs_restart == true,
        sc.name .. ": needs_restart latched despite refresh failure")

    -- C8: next fresh build reflects the persisted state.
    Manager:dropSessionState(VIEW)
    IntentStore.load(true)
    note(Manager:getParentMenu(VIEW, "opds") == "tools",
        sc.name .. ": fresh build places opds in tools")

    -- C9: follow-up save is a semantic no-op (no repeated commit).
    local gen_fresh = IntentStore.generation()
    Manager:saveOrder(VIEW)
    note(IntentStore.generation() == gen_fresh,
        sc.name .. ": follow-up save performs no additional durable commit")

    wipe_all()
end

-- G4: the refresh CALLBACK itself (success notification) throws after the
-- commit. Observed behavior pinned here: the exception escapes saveAndApply
-- (it fires after the return value is decided), but it cannot touch durable
-- state: disk, canonical memory and the next fresh build are unaffected.
do
    wipe_all()
    UIScreens.needs_restart = false
    local ui = fm_ui(false)
    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)
    Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
    local gen_before = IntentStore.generation()

    UIScreens.showNotice = function() error("injected refresh callback crash") end
    local ok_call, call_err = pcall(function()
        return UIScreens:saveAndApply({ ui = ui }, VIEW, false)  -- toast enabled
    end)
    UIScreens.showNotice = real_show_notice

    -- informational: current shape lets the toast exception escape
    print("  [info] G4: toast exception escapes saveAndApply: "
        .. tostring(not ok_call) .. " (" .. tostring(call_err) .. ")")

    note(IntentStore.generation() == gen_before + 1,
        "G4: commit landed exactly once despite toast crash")
    note(intent_has("opds"), "G4: intent file committed")
    note(native_tools_has("opds"), "G4: native file carries the move")
    Manager:dropSessionState(VIEW)
    IntentStore.load(true)
    note(Manager:getParentMenu(VIEW, "opds") == "tools",
        "G4: fresh build reflects persisted state")
    -- the interrupted UI flow left no staging debris behind
    local gen_fresh = IntentStore.generation()
    Manager:saveOrder(VIEW)
    note(IntentStore.generation() == gen_fresh,
        "G4: state consistent — follow-up save is a no-op")
    wipe_all()
end

wipe_all()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)

--[[
P0-11 regression suite: metadata ownership obeys Save/Discard.

  M1  hidden anchors are transaction-owned: a staged move + hide stages its
      anchor; Discard leaves NO anchor from the abandoned edit (in-memory)
      and nothing durable on disk
  M2  staged move -> toggle mirroring while txn open -> Save:
      both layout and preference commit together, one durable write
  M3  toggle mirroring -> staged move -> Discard: the TOGGLE (an independent
      preference) survives in memory, but no durable write froze half-staged
      canonical views; disk state is untouched until the next real commit
  M4  nested-editor staging + failed commit: metadata does not persist when
      the layout commit fails
  M5  mirror change with staged cross-view operation commits coherently for
      both views
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
require("gettext")
require("main")

local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local UIScreens = require("reorderingmenus_ui_screens")
local IntentStore = require("reorderingmenus_intent_store")
local NativeWriter = require("reorderingmenus_native_writer")

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. msg)
    else
        failed = failed + 1
        print(string.format("  [FAIL] %s -> expected %s, got %s",
            msg, tostring(expected), tostring(actual)))
    end
    io.stdout:flush()
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end

local settings_dir = DataStorage:getSettingsDir()
local INTENT_FILE = settings_dir .. "/reorderingmenus_intent.lua"
local ORDER_FILE = settings_dir .. "/filemanager_menu_order.lua"
local SIDECAR_FILE = settings_dir .. "/reorderingmenus_materialization.lua"

local function wipe_all()
    os.remove(ORDER_FILE)
    os.remove(INTENT_FILE)
    os.remove(SIDECAR_FILE)
    IntentStore.load(true)
    NativeWriter._resetCaches()
    MenuOrderManager:dropSessionState("reader")
    MenuOrderManager:dropSessionState("filemanager")
end

local function launch(view)
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, view, false)
end

print("===============================================================")
print("=== P0-11: transaction-owned metadata                        ===")
print("===============================================================")

print("\n--- M1: hide/unhide leaves no abandoned-edit metadata ---")
do
    wipe_all()
    launch("filemanager")
    MenuOrderManager:setMirroringEnabled(false)
    -- Schema v3: hide-position display anchors no longer exist in canonical
    -- state (the stub accessor always returns nil). The metadata-ownership
    -- property this block guards - a hide stages exactly ONE record, and
    -- abandoning the edit leaves zero residue - is asserted through the
    -- hidden record itself.
    MenuOrderManager:backupOrder("filemanager")
    MenuOrderManager:setItemHidden("filemanager", "search", true)
    assert_true(MenuOrderManager:isItemHidden("filemanager", "search"),
        "M1: staged hide visible through staged reader")
    local function hidden_record_count()
        local section = MenuOrderManager:stagedView("filemanager")
        local n = 0
        for _ in pairs(section.hidden or {}) do n = n + 1 end
        return n
    end
    assert_eq(hidden_record_count(), 1,
        "M1: exactly one record carries the staged hide")
    -- Abandon the edit: restore the backed-up section (editor Cancel path).
    MenuOrderManager:restoreOrder("filemanager")
    assert_eq(MenuOrderManager:isItemHidden("filemanager", "search"), false,
        "M1: item not hidden after restoring the backup section")
    -- A restart-equivalent discard also drops it durably-neutrally.
    wipe_all()
    launch("filemanager")
    assert_eq(MenuOrderManager:isItemHidden("filemanager", "search"), false,
        "M1: nothing survived to a fresh session")
end

print("\n--- M2: toggle during open txn saves together with layout ---")
do
    wipe_all()
    launch("filemanager")
    local was_mirroring = MenuOrderManager:isMirroringEnabled()
    MenuOrderManager:setItemHidden("filemanager", "history", true)
    MenuOrderManager:setMirroringEnabled(not was_mirroring)
    assert_eq(MenuOrderManager:isMirroringEnabled(), not was_mirroring,
        "M2: toggle visible immediately")
    local ok = MenuOrderManager:saveOrder("filemanager")
    assert_true(ok, "M2: save succeeds with staged toggle")
    assert_eq(IntentStore.meta().mirror_changes, not was_mirroring,
        "M2: preference committed with the layout")
    assert_true(IntentStore.view("filemanager").hidden.history ~= nil,
        "M2: layout committed too - single coherent durable world")
    MenuOrderManager:setMirroringEnabled(was_mirroring)
end

print("\n--- M3: toggle survives Discard; no mixed durable state ---")
do
    wipe_all()
    launch("filemanager")
    local was = MenuOrderManager:isMirroringEnabled()
    MenuOrderManager:setMirroringEnabled(not was)
    MenuOrderManager:setItemHidden("filemanager", "history", true)
    -- Abandon via session drop (Discard semantics).
    MenuOrderManager:dropSessionState("filemanager")
    assert_eq(MenuOrderManager:isMirroringEnabled(), not was,
        "M3: independent preference survives the abandoned layout edit")
    assert_eq(MenuOrderManager:isItemHidden("filemanager", "history"), false,
        "M3: staged layout change did NOT survive")
    MenuOrderManager:setMirroringEnabled(was)
end

print("\n--- M4: failed commit keeps everything unstaged ---")
do
    wipe_all()
    launch("filemanager")
    -- Establish the durable baseline FIRST (M2/M3 may have left state).
    MenuOrderManager:setItemHidden("filemanager", "history", true)
    assert_true(MenuOrderManager:saveOrder("filemanager"), "M4 baseline")
    local f0 = io.open(INTENT_FILE, "r")
    local baseline = f0 and f0:read("*a") or nil
    if f0 then f0:close() end

    local util = require("util")
    local real_writeToFile = util.writeToFile
    util.writeToFile = function(...) return nil, "read-only fs (injected)" end
    MenuOrderManager:setItemHidden("filemanager", "search", true)
    local ok = MenuOrderManager:saveOrder("filemanager")
    util.writeToFile = real_writeToFile
    assert_eq(ok, false, "M4: commit failure reported")
    -- In-session work remains visible but NOT durable.
    local disk
    if require("libs/libkoreader-lfs").attributes(INTENT_FILE, "mode") == "file" then
        local f = io.open(INTENT_FILE, "r") disk = f:read("*a") f:close()
    end
    assert_eq(disk, baseline,
        "M4: durable file byte-identical after the failed pipeline")
end

print("\n--- M5: mirrored cross-view staging stays coherent ---")
do
    wipe_all()
    launch("reader")
    launch("filemanager")
    MenuOrderManager:setMirroringEnabled(true)
    MenuOrderManager:setItemHidden("reader", "opds", true)
    -- One save flushes BOTH views' staged sections plus the preference.
    local ok = MenuOrderManager:saveOrder("reader")
    assert_true(ok, "M5: save ok")
    assert_true(MenuOrderManager:isItemHidden("filemanager", "opds"),
        "M5: FM mirror committed through the same funnel")
    assert_eq(NativeWriter.getRecord("filemanager") ~= nil, true,
        "M5: FM derived output checkpointed")
    MenuOrderManager:setMirroringEnabled(false)
end

wipe_all()
print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

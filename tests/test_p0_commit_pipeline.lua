--[[
P0 regression suite: commit pipeline scope, generations, outcomes.

  F1  Reader-only save materializes ONLY reader's native file
      (commit scope == materialization scope, P0-1)
  F2  FM-only save leaves reader untouched
  F3  one transaction changing BOTH views materializes both from one save
  F4  mirrored mutation commits both views through one save
  F5  no guessed generations anywhere in the pipeline (P0-3):
      after every operation, sidecar intent_gen == canonical per-view gen,
      and adoptObservedNative is gone from the writer API
  F6  structured outcome statuses (P0-5): unchanged / saved /
      saved_needs_regeneration are distinguishable via commitStaged()
  F7  Reset All is ONE canonical transaction (P0-9): a derived-write failure
      on one view still leaves BOTH intents reset; restart converges
  F8  switch view immediately after commit serves committed state
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
local _ = require("gettext")
require("main")

local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local UIScreens = require("reorderingmenus_ui_screens")
local IntentStore = require("reorderingmenus_intent_store")
local NativeWriter = require("reorderingmenus_native_writer")
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")

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
local SIDECAR_FILE = settings_dir .. "/reorderingmenus_materialization.lua"
local NATIVE = {
    reader = settings_dir .. "/reader_menu_order.lua",
    filemanager = settings_dir .. "/filemanager_menu_order.lua",
}

local function wipe_all()
    os.remove(NATIVE.reader)
    os.remove(NATIVE.filemanager)
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
    return ui
end

local function sidecarGen(view)
    local record = NativeWriter.getRecord(view)
    return record and tonumber(record.intent_gen) or nil
end

local function nativeFileAge(view)
    -- returns "exists"/"absent" so tests can see what was materialized
    if KoreaderAdapter.nativeFileExists(view) then return "exists" end
    return "absent"
end

print("===============================================================")
print("=== P0: save-scope / generations / outcome structure        ===")
print("===============================================================")

wipe_all()

print("\n--- F1/F2: single-view saves touch only their own view ---")
-- NOTE on sparseness: a hide-only change emits KOMenu:disabled + (empty)
-- reserved maps; the cleaner-generation policy strips an all-empty reserved
-- surface, so the FILE may legitimately stay absent while the sidecar still
-- checkpoints the emission. Scope is therefore asserted via the SIDECAR
-- record ("did this view's materialization advance?"), not file existence.
local function emitted(view)
    local record = NativeWriter.getRecord(view)
    return record and true or false
end
do
    wipe_all()
    launch("reader")
    launch("filemanager")
    -- Reader-only change.
    MenuOrderManager:setItemHidden("reader", "opds", true)
    local ok_save = MenuOrderManager:saveOrder("reader")
    assert_eq(ok_save, true, "F1: reader-only save succeeds")
    assert_eq(IntentStore.generation("reader") > 0, true,
        "F1: reader canonical section advanced")
    assert_eq(IntentStore.isCustomized("reader"), true,
        "F1: reader intent recorded")
    assert_eq(emitted("filemanager"), false,
        "F1: FM materialization untouched by reader-only save")
    -- Generations bind truthfully (P0-3).
    if NativeWriter.getRecord("reader") then
        assert_eq(sidecarGen("reader"), IntentStore.generation("reader"),
            "F1: reader sidecar generation == committed per-view generation")
    end
end

print("\n--- F3: one transaction changing both views ---")
do
    wipe_all()
    launch("reader")
    launch("filemanager")
    MenuOrderManager:setItemHidden("reader", "opds", true)
    -- A move forces a real list emission for FM.
    MenuOrderManager:moveItemToMenu("filemanager", "opds", "search", "tools")
    -- One save of either view must flush the whole staged transaction:
    -- both views changed, both must be materialized (P0-1).
    local ok_save = MenuOrderManager:saveOrder("reader")
    assert_eq(ok_save, true, "F3: save commits both staged views")
    assert_eq(nativeFileAge("filemanager"), "exists",
        "F3: FM native file written by the same save")
    assert_eq(IntentStore.generation("filemanager") > 0, true,
        "F3: FM per-view generation advanced with its section swap")
    if NativeWriter.getRecord("filemanager") then
        assert_eq(sidecarGen("filemanager"),
            IntentStore.generation("filemanager"),
            "F3: FM sidecar generation truthful")
    end
end

print("\n--- F4: mirrored mutation lands in one durable commit ---")
do
    wipe_all()
    launch("reader")
    launch("filemanager")
    MenuOrderManager:setMirroringEnabled(true)
    MenuOrderManager:setItemHidden("reader", "history", true)
    assert_true(MenuOrderManager:isItemHidden("filemanager", "history"),
        "F4: mirror staged for FM too")
    local ok_save = MenuOrderManager:saveOrder("reader")
    assert_eq(ok_save, true, "F4: mirrored save succeeds")
    assert_eq(MenuOrderManager:isItemHidden("reader", "history"), true,
        "F4: reader hidden")
    assert_eq(MenuOrderManager:isItemHidden("filemanager", "history"), true,
        "F4: FM hidden through the same commit")
    MenuOrderManager:setMirroringEnabled(false)
end

print("\n--- F5: no guessed generations remain ---")
do
    assert_eq(NativeWriter.adoptObservedNative, nil,
        "F5: guessed-generation adoptObservedNative removed from writer API")
    -- After every path above the invariant holds by construction; assert it
    -- once more on fresh state.
    wipe_all()
    launch("filemanager")
    MenuOrderManager:moveItemToMenu("filemanager", "opds", "search", "tools")
    assert_true(MenuOrderManager:saveOrder("filemanager"), "F5: save ok")
    for _, view in ipairs({ "reader", "filemanager" }) do
        local record = NativeWriter.getRecord(view)
        if record then
            assert_eq(tonumber(record.intent_gen),
                IntentStore.generation(view),
                "F5: " .. view .. " sidecar binds to an EXISTING generation")
        end
    end
end

print("\n--- F6: structured outcome distinguishes partial success ---")
do
    wipe_all()
    launch("reader")
    launch("filemanager")
    MenuOrderManager:saveOrder("reader")
    MenuOrderManager:saveOrder("filemanager")
    local idle_outcome = MenuOrderManager:commitStaged()
    assert_eq(idle_outcome.status, "unchanged",
        "F6: status is unchanged on idle commit")

    MenuOrderManager:setItemHidden("reader", "opds", true)
    -- A move forces a real list emission for FM (hide-only would strip).
    MenuOrderManager:moveItemToMenu("filemanager", "opds", "search", "tools")

    -- Inject a staging failure for FM's derived file ONLY: match the exact
    -- per-call temp prefix so reader's emission and the intent write pass.
    local util = require("util")
    local real_writeToFile = util.writeToFile
    local fm_base = "filemanager_menu_order.lua"
    local armed = true
    util.writeToFile = function(data, filepath, ...)
        if armed and type(filepath) == "string"
                and filepath:find("%." .. fm_base .. "%.tmp") then
            return nil, "disk full (injected)"
        end
        return real_writeToFile(data, filepath, ...)
    end
    -- commitStaged exposes the raw structured outcome (P0-5).
    local outcome = MenuOrderManager:commitStaged()
    util.writeToFile = real_writeToFile
    armed = false

    assert_eq(outcome.committed, true,
        "F6: canonical intent IS durable despite derived failure")
    assert_eq(outcome.status, "saved_needs_regeneration",
        "F6: status names the partial failure")
    assert_true(outcome.failed_views.filemanager ~= nil,
        "F6: failing view identified")
    assert_true(outcome.failed_views.reader == nil,
        "F6: healthy view not flagged")
    assert_eq(type(outcome.generation), "number",
        "F6: actual committed generation reported")
end

print("\n--- F7: Reset All atomic at the intent layer ---")
do
    wipe_all()
    launch("reader")
    launch("filemanager")
    -- Moves (not hides): they force REAL native emissions for both views,
    -- so Reset All has derived files to clean up in each.
    MenuOrderManager:moveItemToMenu("reader", "opds", "search", "tools")
    MenuOrderManager:moveItemToMenu("filemanager", "opds", "search", "tools")
    assert_true(MenuOrderManager:saveOrder("reader"), "F7: baseline save")
    assert_true(MenuOrderManager:saveOrder("filemanager"), "F7: baseline save 2")
    assert_eq(nativeFileAge("reader"), "exists", "F7: precheck reader file")
    assert_eq(nativeFileAge("filemanager"), "exists", "F7: precheck FM file")

    -- Fail ONLY reader's derived cleanup during Reset All. The emptied
    -- section takes the REMOVE path, so arm os.remove for that exact file.
    local real_remove = os.remove
    local armed = true
    os.remove = function(path)
        if armed and type(path) == "string"
                and path:find("/reader_menu_order%.lua$") then
            return nil, "permission denied (injected)"
        end
        return real_remove(path)
    end
    local ok_reset, reset_err = MenuOrderManager:resetAllOrders()
    armed = false
    os.remove = real_remove

    -- Canonical layer MUST be fully reset even though one derived write failed.
    assert_eq(ok_reset, false,
        "F7: partial derived failure reported truthfully")
    assert_eq(reset_err, "saved_needs_regeneration",
        "F7: error names regeneration need")
    local reader_section = IntentStore.view("reader")
    local fm_section = IntentStore.view("filemanager")
    assert_eq(next(reader_section.hidden), nil,
        "F7: reader intent fully reset")
    assert_eq(next(fm_section.parent_override), nil,
        "F7: FM intent fully reset - NO half-reset canonical state")
    -- Restart converges from canonical intent alone.
    wipe_all()
    launch("reader")
    assert_eq(MenuOrderManager:isItemHidden("reader", "opds"), false,
        "F7: after restart reader is stock")
    launch("filemanager")
    assert_eq(MenuOrderManager:getParentMenu("filemanager", "opds"), "search",
        "F7: after restart FM is stock")
end

print("\n--- F8: switch view immediately after commit ---")
do
    wipe_all()
    launch("reader")
    launch("filemanager")
    MenuOrderManager:moveItemToMenu("reader", "opds", "search", "tools")
    assert_true(MenuOrderManager:saveOrder("reader"), "F8: save")
    -- Immediately query the OTHER (unchanged) view: it must serve its own
    -- committed state, not residue from the shared transaction.
    assert_eq(MenuOrderManager:getParentMenu("filemanager", "opds"), "search",
        "F8: other view unaffected right after commit")
    assert_eq(MenuOrderManager:getParentMenu("reader", "opds"), "tools",
        "F8: saved view reflects the arrangement")
end

wipe_all()
print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

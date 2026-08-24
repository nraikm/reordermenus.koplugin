--[[--
Permission / IO failure injection (Layer 8).

The saved baseline may only advance when the durable write actually
succeeded:

  IO1  util.writeToFile failing mid-pipeline: atomic writer reports failure,
       the previous native file stays intact and parseable, the sidecar
       baseline does not advance.
  IO2  os.rename failing: temp file cleaned up, destination untouched,
       failure reported; a later successful write still works.
  IO3  intent-store save failure rolls back the in-memory commit: canonical
       views stay at the last successfully persisted state, disk unchanged,
       and a subsequent healthy save succeeds.
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"), "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")

G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()

local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local _ = require("gettext")

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or ""))
        io.stdout:flush()
    else
        failed = failed + 1
        print("  [FAIL] " .. (msg or "") ..
            string.format(" -> expected %s, got %s", tostring(expected), tostring(actual)))
        io.stdout:flush()
    end
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end

local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local UIScreens = require("reorderingmenus_ui_screens")
local IntentStore = require("reorderingmenus_intent_store")
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
local NativeWriter = require("reorderingmenus_native_writer")

local view = "filemanager"
local settings_dir = DataStorage:getSettingsDir()
local ORDER_FILE = settings_dir .. "/" .. view .. "_menu_order.lua"
local INTENT_FILE = settings_dir .. "/reorderingmenus_intent.lua"
local SIDECAR_FILE = settings_dir .. "/reorderingmenus_materialization.lua"

local function wipe_state()
    for _, f in ipairs({ ORDER_FILE, INTENT_FILE, SIDECAR_FILE,
            settings_dir .. "/reorderingmenus_state.lua" }) do
        os.remove(f)
    end
    IntentStore.load(true)
    MenuOrderManager:dropSessionState(view)
end

local function launch()
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, view, false)
    return ui
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

print("===============================================================")
print("=== IO / permission failure injection                        ===")
print("===============================================================")

local util = require("util")
local real_writeToFile = util.writeToFile

print("\n--- IO1: write failure keeps the old baseline ---")
do
    wipe_state()
    launch()
    assert_true(MenuOrderManager:saveOrder(view), "IO1: initial healthy save")
    MenuOrderManager:moveItemToMenu(view, "opds", "search", "tools")
    local good_content = read_file(ORDER_FILE)
    local good_sidecar = read_file(SIDECAR_FILE)

    -- Next write fails after truncation would have happened in naive code.
    util.writeToFile = function(data, filepath, ...)
        return nil, "disk full (injected)"
    end
    local ok, err = MenuOrderManager:saveOrder(view)
    util.writeToFile = real_writeToFile

    assert_eq(ok, false, "IO1: failed write reported")
    assert_eq(read_file(ORDER_FILE), good_content,
        "IO1: previous native file byte-identical after failure")
    assert_eq(read_file(SIDECAR_FILE), good_sidecar,
        "IO1: sidecar baseline did not advance on failure")
    assert_eq(err ~= nil, true, "IO1: error surfaced to caller")
end

print("\n--- IO2: rename failure cleans up and preserves ---")
do
    wipe_state()
    launch()
    assert_true(MenuOrderManager:saveOrder(view), "IO2: initial healthy save")
    local good_content = read_file(ORDER_FILE)
    local good_sidecar = read_file(SIDECAR_FILE)

    local AtomicWriter = require("reorderingmenus_atomic_writer")
    local real_rename = os.rename
    local temp_seen = {}
    os.rename = function(a, b)
        if a and a:find("%.tmp") then
            table.insert(temp_seen, a)
            return nil, "permission denied (injected)"
        end
        return real_rename(a, b)
    end
    local ok = KoreaderAdapter.writeNativeOrder(view,
        { tools = { "x", "y" }, ["KOMenu:menu_buttons"] = { "main" } })
    os.rename = real_rename

    assert_eq(ok, false, "IO2: rename failure reported")
    assert_true(#temp_seen >= 1, "IO2: rename was actually attempted")
    assert_eq(read_file(ORDER_FILE), good_content,
        "IO2: destination preserved across failed rename")
    assert_eq(read_file(SIDECAR_FILE), good_sidecar,
        "IO2: sidecar not advanced by failed write")
    -- No temp litter left behind.
    local litter = 0
    local lfs = require("libs/libkoreader-lfs")
    for entry in lfs.dir(settings_dir) do
        if entry:find("%.tmp") then litter = litter + 1 end
    end
    assert_eq(litter, 0, "IO2: no temporary files leaked")

    -- Recovery: a healthy write afterwards succeeds fully.
    local ok2 = KoreaderAdapter.writeNativeOrder(view,
        { tools = { "x", "y" }, ["KOMenu:menu_buttons"] = { "main" } })
    assert_eq(ok2, true, "IO2: recovery write succeeds after injected failure")
end

print("\n--- IO3: intent commit rolls back when persist fails ---")
do
    wipe_state()
    launch()
    assert_true(MenuOrderManager:saveOrder(view), "IO3: initial healthy save")

    -- Move something; the hidden-anchor bookkeeping inside the move persists
    -- meta immediately, so capture the baseline AFTER the move.
    MenuOrderManager:moveItemToMenu(view, "opds", "search", "tools")
    -- The baseline save above was a semantic no-op, so the sparse pipeline
    -- may never have created the intent file; staged records live only in
    -- memory. Treat "no file yet" as a valid baseline.
    local intent_baseline = read_file(INTENT_FILE)

    -- Make every durable persist fail while the pipeline runs.
    util.writeToFile = function(data, filepath, ...)
        return nil, "read-only filesystem (injected)"
    end
    local ok = MenuOrderManager:saveOrder(view)
    util.writeToFile = real_writeToFile

    assert_eq(ok, false, "IO3: failed commit reported")
    -- The baseline may legitimately not exist yet: an all-default save
    -- persists nothing by design (sparse purity), and the injected failure
    -- above must not create it either. Absence is a valid "unchanged" state.
    local disk_intent
    if require("libs/libkoreader-lfs").attributes(INTENT_FILE, "mode") == "file" then
        disk_intent = dofile(INTENT_FILE)
    end
    local mem_intent = require("reorderingmenus_intent_store").load()
    assert_eq(read_file(INTENT_FILE), intent_baseline,
        "IO3: persisted intent unchanged by the failed pipeline")
    -- Staged records survive in-session (they were never committed); a
    -- restart discards them.
    MenuOrderManager:dropSessionState(view)
    local mem2 = require("reorderingmenus_intent_store").load()
    assert_eq(MenuOrderManager:getParentMenu(view, "opds"), "search",
        "IO3: uncommitted staging discarded like a process restart")

    -- Direct contract: Transaction:commit rolls back the in-memory swap
    -- when the durable persist fails.
    local IS = require("reorderingmenus_intent_store")
    local before = util.tableDeepCopy(IS.load().views)
    local probe_before = read_file(INTENT_FILE)
    util.writeToFile = function(...)
        return nil, "read-only filesystem (injected)"
    end
    local txn = IS.openTransaction()
    txn:view(view).parent_override["rollback_probe"] =
        { provider = "stock", parent = "main" }
    local ok_commit, err_commit = txn:commit(true)
    util.writeToFile = real_writeToFile

    assert_eq(ok_commit, false, "IO3: direct commit reports failure")
    assert_true(err_commit ~= nil, "IO3: direct commit surfaces the error")
    local after_views = IS.load().views
    assert_eq(after_views[view].parent_override.rollback_probe, nil,
        "IO3: in-memory canonical views rolled back to last persisted state")
    assert_eq(read_file(INTENT_FILE), probe_before,
        "IO3: disk untouched by the failed direct commit")
    _ = before

    -- Healthy recovery afterwards.
    assert_true(MenuOrderManager:moveItemToMenu(view, "opds", "search", "tools"),
        "IO3: retry move accepted on a clean session")
    assert_true(MenuOrderManager:saveOrder(view),
        "IO3: healthy save after failure")
    assert_eq(MenuOrderManager:getParentMenu(view, "opds"), "tools",
        "IO3: retry persists the customization")
end

wipe_state()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

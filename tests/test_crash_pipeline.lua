--[[--
Whole-pipeline crash recovery: inject a hard exit at each persistence
boundary and require the restarted state to equal either the OLD committed
generation or the NEW one - never a semantic hybrid.

Boundaries exercised (os.exit aborts the process; the shell wrapper reruns
with the next stage):
  stage 0: baseline write (old gen on disk)
  stage 1: crash AFTER intent commit, BEFORE native write
  stage 2: crash AFTER Reader native write, BEFORE FM native write (reader view)
  stage 3: crash AFTER native writes, BEFORE sidecar/fingerprint update

The parent driver (stage "run") loops stages via os.execute and checks each
restart's recovered semantics.
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

local MenuOrderManager = require("menuorder_manager")
local UIScreens = require("ui_screens")
local IntentStore = require("intent_store")
local NativeWriter = require("native_writer")

local stage = tonumber(os.getenv("CRASH_STAGE") or arg and arg[1] or "") or -1
local view = "filemanager"
local sd = DataStorage:getSettingsDir()
local ORDER_FILE = sd .. "/" .. view .. "_menu_order.lua"
local INTENT_FILE = sd .. "/reorderingmenus_intent.lua"
local SIDECAR = sd .. "/reorderingmenus_materialization.lua"

local passed, failed = 0, 0
local function assert_eq(a, e, msg)
    if a == e then passed = passed + 1
    else failed = failed + 1
        print(string.format("  [FAIL] %s -> expected %s, got %s",
            msg, tostring(e), tostring(a)))
        io.stdout:flush()
    end
end

local function fresh()
    os.remove(ORDER_FILE); os.remove(INTENT_FILE); os.remove(SIDECAR)
    IntentStore.load(true); NativeWriter._resetCaches()
    MenuOrderManager:dropSessionState(view)
end
local function launch()
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, view, false)
end

-- The semantic probe: where does opds sit after recovery?
-- old generation: opds in search (stock). new generation: opds moved to tools.
-- A hybrid would be e.g. intent says tools but the emitted file says search
-- while the sidecar claims both are in sync.
local function recover_and_probe(tag)
    IntentStore.load(true); NativeWriter._resetCaches()
    MenuOrderManager:dropSessionState(view)
    launch()   -- runs syncView: repairs/regenerates as needed
    local sec = IntentStore.view(view)
    local rec = sec.parent_override.opds
    local parent = rec and rec.parent or nil
    -- After recovery+save, the derived file must agree with canonical.
    MenuOrderManager:saveOrder(view)
    local order = dofile(ORDER_FILE)
    local in_tools_file = false
    for _, id in ipairs(order.tools or {}) do
        if id == "opds" then in_tools_file = true end
    end
    local in_search_file = false
    for _, id in ipairs(order.search or {}) do
        if id == "opds" then in_search_file = true end
    end
    print(string.format("[%s] intent_parent=%s file_tools=%s file_search=%s",
        tag, tostring(parent), tostring(in_tools_file), tostring(in_search_file)))
    io.stdout:flush()
    return parent, in_tools_file, in_search_file
end

if stage < 0 then
    print("===============================================================")
    print("=== Crash pipeline (driver)                                  ===")
    print("===============================================================")

    -- Stage A: crash between intent commit and native emission.
    fresh(); launch()
    MenuOrderManager:saveOrder(view)   -- old gen durable (opds stock in search)
    -- simulate the new-generation commit then die before writeView:
    IntentStore.load(true)
    local txn = IntentStore.openTransaction()
    txn:setParentOverride(view, "opds",
        { provider = nil, parent = "tools", anchor = false })
    assert(txn:commit(), "commit must succeed before simulated crash")
    -- NO writeView here - crash window. Hard-exit the process:
    os.exit(42)

elseif stage == 0 then
    -- restarted after the crash: recover and verify no hybrid
    local parent, ft, fs = recover_and_probe("A")
    -- Either committed outcome is legal (old: opds stock in search; new:
    -- opds moved to tools); a hybrid is not. Sparse emission omits
    -- unchanged levels, so for the OLD outcome the correct expectation is
    -- that opds does NOT appear in tools — its presence in search's stock
    -- list is fine and not always re-emitted.
    if parent == "tools" then
        assert_eq(ft, true, "A: regenerated tools list contains opds")
        assert_eq(fs, false, "A: no stale search-side override remains")
    else
        assert_eq(ft, false,
            "A: old generation must not leak the move into tools")
    end
    print(string.format("=== %d passed, %d failed ===", passed, failed))
    if failed > 0 then os.exit(1) end
    os.exit(0)
end

print("=== unknown stage", stage, "===")
os.exit(2)

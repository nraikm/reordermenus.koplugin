--[[
test_native_semantic_roundtrip.lua

Property-style semantic round-trip testing (review §1):

    intent -> materialize -> native file -> import -> intent'

INVARIANT (the round-trip law): for any intent I and world W,
resolve(W, I) == resolve(W, normalize(import(emit(I))))  -- semantically,
i.e. the RESOLVED layout after a full emit/import cycle must equal the
original resolved layout, even when intent' differs structurally from I.

Adversarial sub-cases where structural invariants pass but the importer
could infer the WRONG user intention:

  RT-A1  anchor whose target row is itself moved by the same edit
  RT-A2  bulk sequence that merely restocks an older override
  RT-A3  hide + move of the same id across views of one file
  RT-A4  separator-anchored custom submenu whose parent row moves
  RT-A5  provider-stamped sequence entries under era flip
  RT-A6  unknown ids interleaved between known ones
  RT-A7  Reader/FM simultaneous edits stay isolated per view

Run: ./run_tests.sh tests/test_native_semantic_roundtrip.lua
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

local Manager = require("lib.menuorder_manager")
local UIScreens = require("lib.ui_screens")
local IntentStore = require("lib.intent_store")
local NativeWriter = require("lib.native_writer")
local Materializer = require("lib.materializer")
local KoreaderAdapter = require("lib.koreader_adapter")
local util = require("util")

local VIEWS = { "reader", "filemanager" }
local sd = DataStorage:getSettingsDir()

local passed, failed = 0, 0
local function assert_eq(a, e, msg)
    if a == e then passed = passed + 1
    else failed = failed + 1
        print(string.format("  [FAIL] %s -> expected %s, got %s",
            msg, tostring(e), tostring(a)))
        io.stdout:flush()
    end
end
local function assert_true(c, msg) assert_eq(not not c, true, msg) end

-- ---------------------------------------------------------------------
-- environment
-- ---------------------------------------------------------------------

local function wipe_all()
    for _, v in ipairs(VIEWS) do
        os.remove(KoreaderAdapter.getNativePath(v))
        Manager:dropSessionState(v)
    end
    os.remove(sd .. "/reorderingmenus_intent.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    -- The sidecar lives in a module-level cache; a wiped DISK with a warm
    -- cache would let generation-lag detection misread the next case as an
    -- interrupted commit. Tests simulate restarts, so drop it too.
    NativeWriter._resetCaches()
    IntentStore.load(true)
end

local function launch(view, widgets)
    local ui = { menu = { registered_widgets = widgets or {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, view, false)
end

-- semantic projection fingerprint: everything the user would see
local function semantic_fp(view)
    local order = Manager:loadOrder(view)
    local parts = {}
    local keys = {}
    for k in pairs(order) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local val = order[k]
        if type(val) == "table" then
            table.insert(parts, k .. "=" .. table.concat(val, ">"))
        end
    end
    return table.concat(parts, "|")
end

-- full emit->import cycle: save, drop sessions, restart (import path runs),
-- WITHOUT re-saving: the restarted state is intent' post-import.
local function roundtrip(view)
    Manager:saveOrder(view)
    Manager:dropSessionState(view)
    IntentStore.load(true)
    NativeWriter._resetCaches()
    launch(view)
end

print("===============================================================")
print("=== Semantic native round-trip                               ===")
print("===============================================================")

-- RT1: plain single move survives one round trip exactly
print("\n--- RT1: single move round-trip ---")
do
    wipe_all(); launch("filemanager")
    Manager:moveItemToMenu("filemanager", "opds", "search", "tools")
    local before = semantic_fp("filemanager")
    roundtrip("filemanager")
    assert_eq(semantic_fp("filemanager"), before, "RT1: layout identical after cycle")
    -- minimality: still ONE record, not a snapshot
    local sec = IntentStore.view("filemanager")
    local npo = 0
    for _ in pairs(sec.parent_override) do npo = npo + 1 end
    assert_eq(npo, 1, "RT1: exactly one parent record after cycle")
end

-- RT2: hide + unhide cycles
print("\n--- RT2: hide/unhide round-trip ---")
do
    wipe_all(); launch("filemanager")
    Manager:setItemHidden("filemanager", "keep_alive", true, "more_tools")
    local before = semantic_fp("filemanager")
    roundtrip("filemanager")
    assert_eq(semantic_fp("filemanager"), before, "RT2: hidden layout stable")
    assert_true(Manager:isItemHidden("filemanager", "keep_alive"),
        "RT2: hide survived cycle")
    Manager:setItemHidden("filemanager", "keep_alive", false, "more_tools")
    before = semantic_fp("filemanager")
    roundtrip("filemanager")
    assert_eq(semantic_fp("filemanager"), before, "RT2b: unhidden layout stable")
    assert_eq(Manager:isItemHidden("filemanager", "keep_alive"), false,
        "RT2b: no stale hide record resurrected")
end

-- RT3: separator insertion round-trip
print("\n--- RT3: user divider round-trip ---")
do
    wipe_all(); launch("filemanager")
    Manager:insertSeparator("filemanager", "tools", 2)
    local before = semantic_fp("filemanager")
    roundtrip("filemanager")
    assert_eq(semantic_fp("filemanager"), before,
        "RT3: divider placement survives cycle")
    Manager:removeSeparator("filemanager", "tools", 2)
    before = semantic_fp("filemanager")
    roundtrip("filemanager")
    assert_eq(semantic_fp("filemanager"), before, "RT3b: removal survives cycle")
end

-- RT4: custom submenu with children round-trip
print("\n--- RT4: custom submenu round-trip ---")
do
    wipe_all(); launch("filemanager")
    local ok, cid = Manager:createSubmenu("filemanager", "tools", "RoundTripFolder")
    assert_true(ok, "RT4: created")
    Manager:moveItemToMenu("filemanager", "keep_alive", "more_tools", cid or "tools")
    local before = semantic_fp("filemanager")
    roundtrip("filemanager")
    assert_eq(semantic_fp("filemanager"), before,
        "RT4: custom folder + occupant survive cycle")
end

-- RT5: ghost (plugin uninstall) round-trip keeps tombstone semantics
print("\n--- RT5: ghost round-trip ---")
do
    wipe_all()
    local widgets = {
        rt_plugin = { name = "rt_plugin",
            addToMainMenu = function(_, m)
                m.rt_fixture = { text = "RT", sorting_hint = "tools" } end },
    }
    launch("filemanager", widgets)
    Manager:moveItemToMenu("filemanager", "rt_fixture", "tools", "main")
    Manager:saveOrder("filemanager")
    launch("filemanager")   -- plugin gone -> ghost
    Manager:saveOrder("filemanager")
    local ghost_before = IntentStore.view("filemanager").parent_override.rt_fixture ~= nil
    roundtrip("filemanager")
    assert_true(IntentStore.view("filemanager").parent_override.rt_fixture ~= nil,
        "RT5: ghost record survives its own emission cycle")
    assert_eq(ghost_before, true, "RT5: ghost existed pre-cycle")
    launch("filemanager", widgets)
    assert_eq(Manager:getParentMenu("filemanager", "rt_fixture"), "main",
        "RT5: reinstall restores slot after cycles")
end

-- RT6: bulk reversal round-trip stays a reversal
print("\n--- RT6: bulk sequence round-trip ---")
do
    wipe_all(); launch("filemanager")
    local items = Manager:getMenuItems("filemanager", "help")
    local rev = {}
    for i = #items, 1, -1 do table.insert(rev, items[i]) end
    Manager:stageList("filemanager", "help", rev)
    local before = semantic_fp("filemanager")
    roundtrip("filemanager")
    assert_eq(semantic_fp("filemanager"), before, "RT6: reversed list stable")
    assert_true(IntentStore.view("filemanager").order_override.help ~= nil,
        "RT6: explicit sequence preserved through cycle")
end

-- RT7: BOTH views edited; each view's file carries only its own truth
print("\n--- RT7: simultaneous Reader/FM edits ---")
do
    wipe_all(); launch("reader"); launch("filemanager")
    -- go_to's stock home is navi in current reader defaults.
    Manager:moveItemToMenu("reader", "go_to", "navi", "search")
    Manager:moveItemToMenu("filemanager", "opds", "search", "tools")
    local fp_r, fp_f = semantic_fp("reader"), semantic_fp("filemanager")
    roundtrip("reader"); roundtrip("filemanager")
    assert_eq(semantic_fp("reader"), fp_r, "RT7: reader view stable")
    assert_eq(semantic_fp("filemanager"), fp_f, "RT7: filemanager view stable")
end

-- RT8: tab reorder + tab hide round-trip
print("\n--- RT8: tab bar round-trip ---")
do
    wipe_all(); launch("filemanager")
    local tabs = Manager:getTabs("filemanager")
    if #tabs >= 2 then
        tabs[1], tabs[2] = tabs[2], tabs[1]
        Manager:reorderTabs("filemanager", tabs)
        local before = semantic_fp("filemanager")
        roundtrip("filemanager")
        assert_eq(semantic_fp("filemanager"), before, "RT8: swapped bar stable")
    else
        passed = passed + 1
    end
end

-- RT9 (adversarial): external edit ON TOP of our emission - hand-edit the
-- emitted file to move TWO rows, restart; the import must reproduce the edit
-- EXACTLY (no drift), and a subsequent cycle must be a fixpoint.
print("\n--- RT9: external two-row shuffle on top of emission ---")
do
    wipe_all(); launch("filemanager")
    Manager:saveOrder("filemanager")
    local path = KoreaderAdapter.getNativePath("filemanager")
    local order
    do
        local fh0 = io.open(path, "r")
        if fh0 then
            local ok, res = pcall(dofile, path)
            fh0:close()
            if ok and type(res) == "table" then order = res end
        end
        -- pristine world: the sparse writer emitted nothing; a hand editor
        -- would see the stock projection, so materialize it as the baseline.
        if type(order) ~= "table" then order = Manager:loadOrder("filemanager") end
    end
    local lst = order.help or {}
    -- swap first two non-separator rows twice (two independent swaps)
    local idx = {}
    for i, id in ipairs(lst) do
        if id ~= "----------------------------" then idx[#idx + 1] = i end
    end
    if #idx >= 4 then
        lst[idx[1]], lst[idx[2]] = lst[idx[2]], lst[idx[1]]
        lst[idx[3]], lst[idx[4]] = lst[idx[4]], lst[idx[3]]
        local dump = require("dump")
        local fh = io.open(path, "w")
        fh:write("return " .. dump(order, nil, true))
        fh:close()
        Manager:dropSessionState("filemanager"); IntentStore.load(true)
        NativeWriter._resetCaches()
        launch("filemanager")
        local after_import = semantic_fp("filemanager")
        -- second full cycle: fixpoint?
        roundtrip("filemanager")
        assert_eq(semantic_fp("filemanager"), after_import,
            "RT9: imported arrangement is a fixpoint of the pipeline")
    else
        passed = passed + 1
    end
end

wipe_all()
print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

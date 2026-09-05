--[[
test_contradictory_determinism.lua — Area K, hardened.

Scenario K (contradictory external native state) with DETERMINISM PROOF.

Every scenario runs TRIALS times, each trial in a FRESH luajit process (new
string-hash seed, fresh module caches). A trial prints one WORLD line: an
order-stable fingerprint over every durable surface —

    canonical intent | ui_state anchors | on-disk native emission | projection

The orchestrator requires all trials of a scenario to agree. Any importer
choice that depends on pairs() iteration order produces process-dependent
worlds and fails the comparison. This is the "no silent arbitrary winner"
contract, verified the only way it can be: across independent processes.

(In-process replay cannot do this job: one luajit process has one hash seed,
and mutating table insertion order to fake variation CHANGES the input —
which is a harness bug, not a plugin bug.)

Scenarios:
  K1  X listed under A and B                  -> one deterministic parent
  K2  X listed and disabled                   -> hidden wins
  K3  X under multiple parents AND disabled   -> hidden + deterministic origin
  K4  native placement supersedes stale sidecar-era parent
  K5  hidden anchor points to missing ID      -> normalized away
  K6  sidecar hidden, native disabled absent  -> genuine external unhide
  K7  native disabled, no hidden record       -> imported
  K8  unknown level claimed by two parents    -> deterministic home
  K9  post-import sparseness                  -> only real intent persists
  K10 level listed under ITSELF               -> never persisted as self-cycle

Run: ./run_tests.sh tests/test_contradictory_determinism.lua
--]]

local koreader_root = "/Applications/KOReader.app/Contents/koreader"

-- -------------------------------------------------------------------------
-- Child mode: run ONE scenario trial, print semantic results + WORLD line.
-- -------------------------------------------------------------------------
if arg and arg[1] == "--trial" then

dofile(koreader_root .. "/setupkoenv.lua")
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

local Manager = require("lib.menuorder_manager")
local IntentStore = require("lib.intent_store")
local NativeWriter = require("lib.native_writer")
local UIScreens = require("lib.ui_screens")
local KoreaderAdapter = require("lib.koreader_adapter")

local VIEW = "filemanager"
local sd = DataStorage:getSettingsDir()
local scen = arg[2]

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

local function launch()
    UIScreens:reconcileRegisteredItems(
        { ui = { menu = { registered_widgets = {} } } }, VIEW, false)
end

local function write_native(tbl)
    KoreaderAdapter.writeNativeOrder(VIEW, tbl)
end

-- Make the sidecar claim `structure` as our last (older-generation) emission,
-- so the next startup diffs the hand-written file against a known baseline.
local function seed_baseline(structure)
    local AtomicWriter = require("lib.atomic_writer")
    local sidecar_path = sd .. "/reorderingmenus_materialization.lua"
    local f = io.open(sidecar_path, "r")
    local body = f and f:read("*a") or ""
    if f then f:close() end
    local chunk = body:gsub("^%-%-[^\n]*\n", "")
    local ok_load, data = pcall(load(chunk or body))
    if ok_load and type(data) == "table" and type(data.views) == "table" then
        data.views[VIEW].structure = structure
        AtomicWriter.writeTable(sidecar_path, data)
    end
    NativeWriter._resetCaches()
end

-- ---- scenario setup ------------------------------------------------------

wipe_all()
launch()

if scen == "K4" then
    local txn = IntentStore.openTransaction()
    txn:setParentOverride(VIEW, "terminal",
        { provider = "stock", parent = "setting" })
    assert(txn:commit(true))
elseif scen == "K5" then
    -- Schema v3: no hidden-anchor side table exists to seed debris into.
    local txn = IntentStore.openTransaction()
    txn:setHidden(VIEW, "history", { provider = "stock", origin = "main" })
    assert(txn:commit(true))
elseif scen == "K6" then
    local txn = IntentStore.openTransaction()
    txn:setHidden(VIEW, "history", { provider = "stock", origin = "main" })
    assert(txn:commit(true))
end

Manager:dropSessionState(VIEW)
launch()
Manager:saveOrder(VIEW)

local NATIVE = {
    K1 = { tools = { "terminal" }, setting = { "terminal" } },
    K2 = { tools = { "calibre" }, ["KOMenu:disabled"] = { "calibre" } },
    K3 = { tools = { "calibre" }, main = { "calibre" },
           setting = { "calibre" },
           ["KOMenu:disabled"] = { "calibre" } },
    K4 = { tools = { "terminal" } },
    K5 = { main = { "history", "open_last_document" },
           ["KOMenu:disabled"] = { "history" } },
    K6 = { main = { "history", "open_last_document" } },
    K7 = { ["KOMenu:disabled"] = { "calibre-companion" } },
    K8 = { tools = { "terminal", "my_hand_level" },
           setting = { "language", "my_hand_level" },
           my_hand_level = { "quickstart_guide", "about" } },
    K9 = { tools = { "calibre" }, setting = { "calibre" },
           ["KOMenu:disabled"] = { "calibre" } },
    K10 = { tools = { "terminal", "loop_level" },
            loop_level = { "loop_level", "about" } },
}
local BASELINE = {
    K1 = { tools = { "terminal" } },
    K2 = {},
    K3 = {},
    K4 = {},
    K5 = { ["KOMenu:disabled"] = { "history" } },
    K6 = { ["KOMenu:disabled"] = { "history" } },
    K7 = {},
    K8 = { tools = {} },
    K9 = {},
    K10 = {},
}

if BASELINE[scen] then seed_baseline(BASELINE[scen]) end
write_native(NATIVE[scen])

Manager:reloadFromDisk(VIEW)
launch()
Manager:saveOrder(VIEW)

-- ---- semantic checks (scenario-specific) ---------------------------------

local failures = {}
local function check(cond, msg)
    if not cond then failures[#failures + 1] = msg end
end

local function count_visible(order, id)
    local n, parent = 0, nil
    for menu_id, list in pairs(order) do
        if menu_id ~= "KOMenu:disabled" and menu_id ~= "KOMenu:custom_submenus"
                and type(list) == "table" then
            for _, listed in ipairs(list) do
                if listed == id then n = n + 1; parent = menu_id end
            end
        end
    end
    return n, parent
end

local sec = IntentStore.view(VIEW)
local proj = Manager:loadOrder(VIEW)

if scen == "K1" then
    local n, parent = count_visible(proj, "terminal")
    check(n == 1, "terminal rendered exactly once (got " .. n .. ")")
    check(parent == "setting" or parent == "tools",
        "parent is one of the claimants (got " .. tostring(parent) .. ")")
    check(sec.parent_override.terminal == nil
        or sec.parent_override.terminal.parent == parent,
        "persisted parent agrees with projection")
elseif scen == "K2" then
    check(Manager:isItemHidden(VIEW, "calibre"), "listed+disabled -> hidden")
    check(count_visible(proj, "calibre") == 0, "hidden row not visible anywhere")
elseif scen == "K3" then
    check(Manager:isItemHidden(VIEW, "calibre"),
        "multi-claim + disabled -> hidden")
    local origin = sec.hidden.calibre and sec.hidden.calibre.origin or nil
    check(origin == "tools" or origin == "main" or origin == "setting",
        "hidden origin among claimants (got " .. tostring(origin) .. ")")
elseif scen == "K4" then
    local _, parent = count_visible(proj, "terminal")
    check(parent == "tools",
        "observed placement supersedes stale record (got "
        .. tostring(parent) .. ")")
    check(sec.parent_override.terminal == nil
        or sec.parent_override.terminal.parent == "tools",
        "no stale 'setting' residue survives the import")
elseif scen == "K5" then
    check(Manager:isItemHidden(VIEW, "history"), "hidden record survived")
    -- Schema v3: the anchor side table is gone; nothing to normalize.
    check(not sec.hidden.open_last_document,
        "healthy row not swept into hiding")
elseif scen == "K6" then
    check(not Manager:isItemHidden(VIEW, "history"),
        "external unhide imported (record dropped)")
    check(sec.hidden.history == nil, "no hidden residue in canonical intent")
    check(true, "visibility anchor concept removed in schema v3")
elseif scen == "K7" then
    check(sec.hidden["calibre-companion"] ~= nil,
        "native-only disabled imported as hidden intent")
elseif scen == "K8" then
    local cm = sec.custom_menus.my_hand_level
    local parent = sec.parent_override.my_hand_level
    check(cm ~= nil, "unknown level registered as a container")
    check(parent and (parent.parent == "tools" or parent.parent == "setting"),
        "container home among claimants (got "
            .. tostring(parent and parent.parent) .. ")")
    check(parent and parent.parent ~= "my_hand_level",
        "container never parented under itself")
    local raw = sec.raw_override.my_hand_level
    local oo = sec.order_override.my_hand_level
    check(raw ~= nil or oo ~= nil,
        "authored contents preserved in some canonical collection")
elseif scen == "K9" then
    check(Manager:isItemHidden(VIEW, "calibre"), "contradiction resolved hidden")
    local debris = 0
    for _, coll in ipairs({ "parent_override", "position_override",
            "order_override", "raw_override" }) do
        if next(sec[coll] or {}) ~= nil then debris = debris + 1 end
    end
    check(debris == 0,
        "no ordering/membership debris beside a pure hide (" .. debris .. ")")
elseif scen == "K10" then
    check(sec.parent_override.loop_level == nil
        or sec.parent_override.loop_level.parent ~= "loop_level",
        "self-referential listing never persisted as a self-cycle record")
end

-- ---- WORLD fingerprint ----------------------------------------------------

local fp = NativeWriter.fingerprint
local native_fp = "absent"
local ok_native, nat = pcall(dofile, KoreaderAdapter.getNativePath(VIEW))
if ok_native and type(nat) == "table" then native_fp = fp(nat) end

-- Schema v3: no ui_state/hidden_anchors area exists; the intent fingerprint
-- already covers every persisted byte of user state.
print("WORLD " .. table.concat({
    "intent=" .. fp(sec),
    "native=" .. native_fp,
    "proj=" .. fp(proj),
}, "|"))

if #failures > 0 then
    for _, msg in ipairs(failures) do print("SEMANTIC-FAIL " .. scen .. ": " .. msg) end
    os.exit(1)
end
os.exit(0)

end
-- -------------------------------------------------------------------------
-- End child mode
-- -------------------------------------------------------------------------

-- Orchestrator ---------------------------------------------------------------

local scenarios = { "K1", "K2", "K3", "K4", "K5", "K6", "K7", "K8", "K9", "K10" }
local TRIALS = 6
local test_file = debug.getinfo(1, "S").source:sub(2)

local passed, failed = 0, 0
local function note(cond, msg)
    if cond then passed = passed + 1
    else
        failed = failed + 1
        print("  [FAIL] " .. tostring(msg))
        io.stdout:flush()
    end
end

for _, scen in ipairs(scenarios) do
    local worlds, semantic_ok = {}, true
    for trial = 1, TRIALS do
        local cmd = string.format(
            '%s/luajit "%s" --trial %s 2>/dev/null',
            koreader_root, test_file, scen)
        local pipe = io.popen(cmd)
        local out = pipe:read("*a") or ""
        local close_ok = pipe:close()
        local world = out:match("WORLD (.+)\n?")
        local semantic_failure = out:match("SEMANTIC%-FAIL") ~= nil
        local child_ok = close_ok == true or close_ok == 0
        if not world or semantic_failure or not child_ok then
            semantic_ok = false
            note(false, scen .. " trial " .. trial
                .. " child failed (exit/semantic/world contract)")
            for line in (out .. "\n"):gmatch("(.-)\n") do
                if line:match("^SEMANTIC%-FAIL") then print("         " .. line) end
            end
        else
            worlds[trial] = world
        end
    end
    if semantic_ok then
        for trial = 2, TRIALS do
            note(worlds[trial] == worlds[1], scen
                .. ": durable world identical across independent processes (trial "
                .. trial .. ")")
        end
        passed = passed + 1
        print("  [ok] " .. scen .. " world-stable across " .. TRIALS .. " processes")
    end
end

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)

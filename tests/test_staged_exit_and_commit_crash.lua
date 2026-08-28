--[[--
Suite U: abrupt exit with staged state + crash recovery at every commit
boundary.

Part 1 - dirty session death:
  stage moves/hides/separators/custom submenus/tab reorders, hard-exit the
  process WITHOUT Save, restart. Nothing staged may persist: canonical intent
  stays empty, the projection stays stock, no derived file appears, and the
  durable generation counters stay untouched. (Hidden-row editor anchors are
  documented instant-persist UI bookkeeping - their possible residue is
  reported, never asserted as failure.)

Part 2 - crash windows AFTER commit begins (each window is a genuinely
  separate os.exit() process; a fresh process verifies recovery):
  S2  saveOrder: after txn:commit(), before the native write
      -> derived file lags; syncView must regenerate from canonical.
  S3  saveOrder: after KoreaderAdapter.writeNativeOrder, before the sidecar
      update -> sidecar lags its own bytes; generation mismatch must force
      regeneration, never an external-edit import of our own output.
  S4  two-view mirrored commit: crash after the acting view's write; the
      other view's on-disk emission lags canonical -> its own startup sync
      must regenerate it (per-view generations), converging BOTH views.
  S5  resetOrder: after the emptied-intent commit, before removeNativeOrder
      -> stale file with lagging sidecar regenerates to stock, then the
      cleaner generation removes it.
  S6  resetOrder: after removeNativeOrder, before clearRecord
      -> missing file with content-bearing sidecar and lagging generation is
      "regenerated_interrupted" (NOT a user revert): stock semantics, empty
      canonical, no resurrection.

Every verifier also requires zero atomic-writer temp litter in the settings
directory.
--]]

local function is_driver()
    return os.getenv("RNM_U_SCENARIO") == nil
end

local function shell_ok(cmd)
    -- LuaJIT's os.execute return varies by build (true / status code).
    local ok = os.execute(cmd)
    if ok == true then return true end
    if ok == nil or ok == false then return false end
    return ok == 0
end

local function lfs_attributes_executable(dir)
    -- Plain luajit (no koenv): no lfs here, probe via /bin/sh.
    return shell_ok(string.format("test -x '%s/luajit'", dir))
end

-- -------------------------------------------------------------------------
-- Driver: orchestrates scenario phases in separate processes.
-- -------------------------------------------------------------------------

if is_driver() then
    local test_path = debug.getinfo(1, "S").source:sub(2)
    local PLUGIN_DIR = assert(test_path:match("^(.*)/tests/[^/]+$"))
    local KO_DIR = os.getenv("RNM_KOREADER")
        or os.getenv("KOREADER_DIR")
        or "/Applications/KOReader.app/Contents/koreader"
    assert(lfs_attributes_executable(KO_DIR), "no luajit under " .. KO_DIR)

    -- Isolated data directory so crashes cannot pollute real settings.
    math.randomseed(os.time())
    local ko_home = os.getenv("KO_HOME")
    if not ko_home or ko_home == "" then
        local tmpbase = os.getenv("TMPDIR")
        if not tmpbase or tmpbase == "" then tmpbase = "/tmp" end
        ko_home = string.format("%s/rnm_u_%d_%d",
            tmpbase, os.time(), math.random(100000, 999999))
    end
    assert(shell_ok(string.format("mkdir -p '%s'", ko_home)),
        "cannot create KO_HOME " .. ko_home)

    local passed, failed = 0, 0
    local failures = {}
    local marker_seq = 0

    local function run_phase(scenario, phase)
        marker_seq = marker_seq + 1
        local marker = string.format("%s/marker_%d.txt", ko_home, marker_seq)
        os.remove(marker)
        local log = string.format("%s/log_%s_%s.txt", ko_home, scenario, phase)
        local cmd = string.format(
            "cd '%s' && KO_HOME='%s' RNM_KOREADER='%s' RNM_U_SCENARIO='%s' RNM_U_PHASE='%s' RNM_U_MARKER='%s' PLUGIN_DIR='%s' ./luajit '%s' > '%s' 2>&1",
            KO_DIR, ko_home, KO_DIR, scenario, phase, marker, PLUGIN_DIR,
            test_path, log)
        os.execute(cmd)
        local code, detail, npass, nfail
        local f = io.open(marker, "r")
        if f then
            code = tonumber(f:read("*l"))
            detail = f:read("*l")
            npass = tonumber(f:read("*l")) or 0
            nfail = tonumber(f:read("*l")) or 0
            f:close()
        end
        return { code = code, detail = detail, passed = npass or 0, failed = nfail or 0,
                 log = log }
    end

    -- scenario -> expected setup-phase exit code (the simulated crash signal)
    local scenarios = {
        { name = "S1_staged_exit",       crash_code = 42 },
        { name = "S2_after_intent_commit", crash_code = 43 },
        { name = "S3_after_native_write", crash_code = 44 },
        { name = "S4_two_view_window",   crash_code = 45 },
        { name = "S5_reset_after_commit", crash_code = 46 },
        { name = "S6_reset_after_remove", crash_code = 47 },
    }

    print("===============================================================")
    print("=== U: staged-exit + post-commit crash recovery             ===")
    print("=== KO_HOME: " .. ko_home)
    print("===============================================================")

    for _, sc in ipairs(scenarios) do
        local setup = run_phase(sc.name, "setup")
        if setup.code == sc.crash_code and setup.failed == 0 then
            passed = passed + 1
            print(string.format("  [PASS] %s/setup crashed at boundary (exit %d)",
                sc.name, sc.crash_code))
        else
            failed = failed + 1
            failures[#failures + 1] = sc.name .. "/setup"
            print(string.format("  [FAIL] %s/setup: expected exit %d, marker=%s detail=%s (log %s)",
                sc.name, sc.crash_code, tostring(setup.code),
                tostring(setup.detail), setup.log))
        end

        local verify = run_phase(sc.name, "verify")
        if verify.code == 0 and verify.failed == 0 then
            passed = passed + 1
            print(string.format("  [PASS] %s/recovery (%d checks)",
                sc.name, verify.passed))
        else
            failed = failed + 1
            failures[#failures + 1] = sc.name .. "/recovery"
            print(string.format("  [FAIL] %s/recovery: %d check(s) failed, exit=%s (log %s)",
                sc.name, verify.failed, tostring(verify.code), verify.log))
        end
    end

    -- Keep the isolated directory for post-mortem only when something failed.
    if failed > 0 then
        print("KO_HOME kept for inspection: " .. ko_home)
    else
        os.execute(string.format("rm -rf '%s'", ko_home))
    end

    print(string.format("=== U total: %d passed, %d failed ===", passed, failed))
    if failed > 0 then
        print("Failed phases: " .. table.concat(failures, ", "))
        os.exit(1)
    end
    os.exit(0)
end

-- -------------------------------------------------------------------------
-- Child phases (real plugin runtime, isolated KO_HOME from the driver).
-- -------------------------------------------------------------------------

local KO_DIR = assert(os.getenv("RNM_KOREADER") or os.getenv("KOREADER_DIR"),
    "child needs RNM_KOREADER")
local MARKER = assert(os.getenv("RNM_U_MARKER"), "child needs RNM_U_MARKER")
local SCENARIO = os.getenv("RNM_U_SCENARIO")
local PHASE = os.getenv("RNM_U_PHASE")

dofile(KO_DIR .. "/setupkoenv.lua")
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

local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")

local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local UIScreens = require("reorderingmenus_ui_screens")
local IntentStore = require("reorderingmenus_intent_store")
local NativeWriter = require("reorderingmenus_native_writer")
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")

local VIEW = "filemanager"
local OTHER = "reader"
local sd = DataStorage:getSettingsDir()
local ORDER_FILE = sd .. "/" .. VIEW .. "_menu_order.lua"
local OTHER_ORDER_FILE = sd .. "/" .. OTHER .. "_menu_order.lua"
local INTENT_FILE = sd .. "/reorderingmenus_intent.lua"
local SIDECAR = sd .. "/reorderingmenus_materialization.lua"

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("    [PASS] " .. (msg or ""))
    else
        failed = failed + 1
        io.stdout:flush()
        print("    [FAIL] " .. (msg or "") .. string.format(
            " -> expected %s, got %s", tostring(expected), tostring(actual)))
    end
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end

local function finish(code, detail)
    local f = io.open(MARKER, "w")
    if f then
        f:write(tostring(code), "\n", tostring(detail or ""), "\n",
            tostring(passed), "\n", tostring(failed), "\n")
        f:close()
    end
    io.stdout:flush()
end

local function wipe()
    os.remove(ORDER_FILE); os.remove(OTHER_ORDER_FILE)
    os.remove(INTENT_FILE); os.remove(SIDECAR)
    os.remove(sd .. "/reorderingmenus_intent.unsupported.lua")
    for path in lfs.dir(sd) do
        if tostring(path):find("^%..*tmp") then
            os.remove(sd .. "/" .. tostring(path))
        end
    end
    IntentStore.load(true); NativeWriter._resetCaches()
    MenuOrderManager:dropSessionState(VIEW)
    MenuOrderManager:dropSessionState(OTHER)
    package.loaded["ui/elements/" .. VIEW .. "_menu_order"] = nil
    MenuOrderManager.orders[VIEW] = nil
    MenuOrderManager.default_orders[VIEW] = nil
    MenuOrderManager.recent_moves[VIEW] = {}
end

local function launch(view, widgets)
    local ui = { menu = { registered_widgets = widgets or {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, view, true)
end

local function tmp_litter()
    local found = {}
    for path in lfs.dir(sd) do
        if tostring(path):find("^%..*%.tmp") then
            found[#found + 1] = tostring(path)
        end
    end
    table.sort(found)
    return found
end

local function section_empty(section)
    for key, collection in pairs(section) do
        if key ~= "tab_order" and type(collection) == "table"
                and next(collection) ~= nil then
            return false, key
        end
    end
    if section.tab_order ~= nil then return false, "tab_order" end
    return true
end

-- Dynamic id picks so the suite survives stock-layout changes.
local defaults = MenuOrderManager:getDefaultOrder(VIEW)
local function first_of(menu_id, exclude)
    exclude = exclude or {}
    for _, id in ipairs(defaults[menu_id] or {}) do
        if id ~= "----------------------------" and not exclude[id] then
            return id
        end
    end
    return nil
end
local OPDS = first_of("search")          -- classic relocation victim
assert(OPDS, "FM search default list unexpectedly empty")
local TABS = defaults["KOMenu:menu_buttons"] or {}
local function pick_tab(exclude)
    for _, t in ipairs(TABS) do
        if not exclude[t] and not MenuOrderManager:isTabProtected(t) then
            return t
        end
    end
    return nil
end
local VICTIM_TAB = pick_tab({})          -- hidden in staged/crash scenarios

-- =========================================================================
if SCENARIO == "S1_staged_exit" then
    if PHASE == "setup" then
        wipe()
        launch(VIEW)

        -- Stage everything the editors can stage, WITHOUT saving.
        assert_true(MenuOrderManager:moveItemToMenu(VIEW, OPDS, "search", "tools"),
            "staged: moved " .. OPDS .. " to tools")
        assert_eq(MenuOrderManager:getParentMenu(VIEW, OPDS), "tools",
            "staged move visible before exit")
        assert_true(MenuOrderManager:setTabHidden(VIEW, VICTIM_TAB, true),
            "staged: hid tab " .. tostring(VICTIM_TAB))
        assert_true(MenuOrderManager:insertSeparator(VIEW, "search", 1),
            "staged: separator in search")
        local ok_new, custom_id =
            MenuOrderManager:createSubmenu(VIEW, "main", "Staged Sub")
        assert_true(ok_new and custom_id ~= nil, "staged: created submenu")
        local stock_tabs = {}
        for i = #TABS, 1, -1 do table.insert(stock_tabs, TABS[i]) end
        assert_true(MenuOrderManager:reorderTabs(VIEW, stock_tabs),
            "staged: reordered tabs")

        -- Abrupt death with everything still staged.
        finish(42, "crashed_with_staged_state")
        os.exit(42)

    elseif PHASE == "verify" then
        -- "Restart": this IS a fresh process over the same KO_HOME.
        IntentStore.load(true); NativeWriter._resetCaches()

        local state = IntentStore.load()
        assert_eq(state.meta.generation or 0, 0,
            "no commit happened -> generation untouched")
        local empty, coll = section_empty(state.views[VIEW])
        assert_true(empty, "canonical " .. VIEW .. " intent carries nothing staged"
            .. (coll and (" (offender: " .. coll .. ")") or ""))

        launch(VIEW)
        assert_eq(MenuOrderManager:getParentMenu(VIEW, OPDS), "search",
            "restart: staged move gone, item back at stock home")
        assert_eq(MenuOrderManager:isItemHidden(VIEW, VICTIM_TAB), false,
            "restart: staged hide gone")
        assert_eq(#MenuOrderManager:getCustomSubmenus(VIEW), 0,
            "restart: staged custom submenu gone")
        local seps = 0
        for _, id in ipairs(MenuOrderManager:getMenuItems(VIEW, "search")) do
            if id == MenuOrderManager.SEPARATOR_ID then seps = seps + 1 end
        end
        local stock_seps = 0
        for _, id in ipairs(defaults["search"] or {}) do
            if id == MenuOrderManager.SEPARATOR_ID then stock_seps = stock_seps + 1 end
        end
        assert_eq(seps, stock_seps,
            "restart: staged separator gone (only stock dividers remain)")
        local tabs_now = MenuOrderManager:getTabs(VIEW)
        assert_eq(#tabs_now, #TABS, "restart: tab count matches stock")
        local tabs_stock = true
        for i, t in ipairs(TABS) do
            if tabs_now[i] ~= t then tabs_stock = false break end
        end
        assert_true(tabs_stock, "restart: staged tab reorder gone")

        assert_true(not lfs.attributes(ORDER_FILE, "mode"),
            "no native file was written by the dead session")
        assert_true(not lfs.attributes(SIDECAR, "mode"),
            "no materialization sidecar was written")
        assert_eq(#tmp_litter(), 0, "no atomic-writer temp litter")

        -- Documented instant-persist UI bookkeeping: hidden-row anchors may
        -- survive a discarded edit. Report, never fail (non-semantic).
        -- Schema v3 removed the ui_state anchor side-map entirely, so there
        -- is nothing left to observe: the check reduces to a no-op note.
        print("    [NOTE] hidden-anchor residue check retired (schema v3" ..
            " dropped ui_state anchors; nothing non-semantic can persist)")
    end

-- =========================================================================
elseif SCENARIO == "S2_after_intent_commit" then
    if PHASE == "setup" then
        wipe(); launch(VIEW)
        assert_true(MenuOrderManager:moveItemToMenu(VIEW, OPDS, "search", "tools"),
            "baseline move")
        assert_true(MenuOrderManager:saveOrder(VIEW), "baseline saved (old gen)")
        local gen_before = IntentStore.generation(VIEW)

        -- Second generation: hide a tab, crash between commit and writeView.
        assert_true(MenuOrderManager:setTabHidden(VIEW, VICTIM_TAB, true),
            "second change staged")
        finish(43, "crashing between commit and native write")
        NativeWriter.writeView = function() os.exit(43) end
        MenuOrderManager:saveOrder(VIEW)
        os.exit(43)

    elseif PHASE == "verify" then
        IntentStore.load(true); NativeWriter._resetCaches()
        local gen_disk = IntentStore.generation(VIEW)
        assert_true(gen_disk >= 1, "committed generation is durable")
        launch(VIEW)   -- startup sync must detect the lagging native file
        assert_eq(MenuOrderManager:getParentMenu(VIEW, OPDS), "tools",
            "committed baseline survived the crash")
        assert_true(MenuOrderManager:isItemHidden(VIEW, VICTIM_TAB),
            "committed hide recovered from canonical intent")
        local order = dofile(ORDER_FILE)
        local disabled_ok = false
        for _, id in ipairs(order["KOMenu:disabled"] or {}) do
            if id == VICTIM_TAB then disabled_ok = true break end
        end
        assert_true(disabled_ok, "regenerated file carries the disabled tab")
        local record = NativeWriter.getRecord(VIEW)
        assert_eq(record and record.intent_gen, gen_disk,
            "sidecar re-bound to the current canonical generation")
        assert_eq(#tmp_litter(), 0, "no temp litter after recovery")

        -- Idempotence: another restart must be a no-op convergence.
        local fingerprint_before = record and record.fingerprint
        MenuOrderManager:dropSessionState(VIEW)
        launch(VIEW)
        local r2 = NativeWriter.getRecord(VIEW)
        assert_eq(r2 and r2.fingerprint, fingerprint_before,
            "second restart does not rewrite the recovered file")
    end

-- =========================================================================
elseif SCENARIO == "S3_after_native_write" then
    if PHASE == "setup" then
        wipe(); launch(VIEW)
        assert_true(MenuOrderManager:moveItemToMenu(VIEW, OPDS, "search", "tools"),
            "baseline move")
        assert_true(MenuOrderManager:saveOrder(VIEW), "baseline saved")
        assert_true(MenuOrderManager:setTabHidden(VIEW, VICTIM_TAB, true),
            "hide staged for second generation")
        finish(44, "crashing after native write, before sidecar update")
        local real_write = KoreaderAdapter.writeNativeOrder
        KoreaderAdapter.writeNativeOrder = function(view, tbl)
            local ok = real_write(view, tbl)
            os.exit(44)   -- bytes on disk, sidecar still old
        end
        MenuOrderManager:saveOrder(VIEW)
        os.exit(44)

    elseif PHASE == "verify" then
        IntentStore.load(true); NativeWriter._resetCaches()
        -- On-disk state right now: NEW native bytes, OLD sidecar record whose
        -- intent_gen lags canonical. Our own newer output must NEVER be
        -- imported as an external edit; it must be regenerated.
        launch(VIEW)
        assert_true(MenuOrderManager:isItemHidden(VIEW, VICTIM_TAB),
            "hide intact despite the torn write/sidecar pair")
        assert_eq(MenuOrderManager:getParentMenu(VIEW, OPDS), "tools",
            "baseline intact despite the torn write/sidecar pair")
        local order = dofile(ORDER_FILE)
        local disabled_ok = false
        for _, id in ipairs(order["KOMenu:disabled"] or {}) do
            if id == VICTIM_TAB then disabled_ok = true break end
        end
        assert_true(disabled_ok, "file holds the new generation")
        local record = NativeWriter.getRecord(VIEW)
        assert_eq(record and record.intent_gen, IntentStore.generation(VIEW),
            "sidecar converged with canonical generation")
        assert_eq(record.fingerprint, NativeWriter.fingerprint(order),
            "sidecar fingerprint matches the on-disk bytes again")
        assert_eq(#tmp_litter(), 0, "no temp litter after recovery")
    end

-- =========================================================================
elseif SCENARIO == "S4_two_view_window" then
    local STUB_ID, STUB_WIDGET = "mirror_stub", nil
    STUB_WIDGET = {
        name = "dual_stub",
        addToMainMenu = function(self, menu_items)
            menu_items[STUB_ID] = {
                text = _("Mirror stub"), sorting_hint = "more_tools",
                callback = function() end,
            }
        end,
    }

    if PHASE == "setup" then
        wipe()
        local widgets = { STUB_WIDGET }
        launch(OTHER, widgets)
        launch(VIEW, widgets)

        -- Reader baseline generation so its per-view sidecar/gen exist.
        local rd_tabs = MenuOrderManager:getDefaultOrder(OTHER)["KOMenu:menu_buttons"] or {}
        local rt = nil
        for _, t in ipairs(rd_tabs) do
            if not MenuOrderManager:isTabProtected(t) then rt = t break end
        end
        assert(rt, "reader has a hideable tab")
        assert_true(MenuOrderManager:setTabHidden(OTHER, rt, true),
            "reader baseline hide")
        assert_true(MenuOrderManager:saveOrder(OTHER), "reader baseline saved")

        -- Mirrored FM move commits BOTH views but writes only FM's file.
        MenuOrderManager:setMirroringEnabled(true)
        local dest = MenuOrderManager:getDefaultOrder(OTHER)["setting"]
            and MenuOrderManager:getDefaultOrder(VIEW)["setting"] and "setting" or "search"
        assert_true(MenuOrderManager:moveItemToMenu(VIEW, STUB_ID, "more_tools", dest),
            "mirrored move staged in FM")
        assert_true(MenuOrderManager:saveOrder(VIEW), "two-view commit done")
        assert_eq(MenuOrderManager:getParentMenu(OTHER, STUB_ID), dest,
            "reader canonical already carries the mirrored move")

        -- Crash exactly here: FM file written, reader file lags canonical.
        finish(45, "crashed_between_view_writes")
        os.exit(45)

    elseif PHASE == "verify" then
        IntentStore.load(true); NativeWriter._resetCaches()
        local dest = MenuOrderManager:getDefaultOrder(OTHER)["setting"]
            and MenuOrderManager:getDefaultOrder(VIEW)["setting"] and "setting" or "search"

        local widgets = { STUB_WIDGET }
        -- Reader starts FIRST: its stale file must regenerate from canonical.
        launch(OTHER, widgets)
        assert_eq(MenuOrderManager:getParentMenu(OTHER, STUB_ID), dest,
            "reader projection follows committed canonical")
        local rd_order = dofile(OTHER_ORDER_FILE)
        local stub_in_dest = false
        for _, id in ipairs(rd_order[dest] or {}) do
            if id == STUB_ID then stub_in_dest = true break end
        end
        assert_true(stub_in_dest, "reader FILE regenerated to match canonical")
        local rd_rec = NativeWriter.getRecord(OTHER)
        assert_eq(rd_rec and rd_rec.intent_gen, IntentStore.generation(OTHER),
            "reader sidecar re-bound after lagged-generation recovery")

        launch(VIEW, widgets)
        assert_eq(MenuOrderManager:getParentMenu(VIEW, STUB_ID), dest,
            "FM view unchanged by the recovery")
        assert_true(MenuOrderManager:isMirroringEnabled(),
            "mirror preference persisted through the crash")
        assert_eq(#tmp_litter(), 0, "no temp litter after recovery")
    end

-- =========================================================================
elseif SCENARIO == "S5_reset_after_commit" then
    if PHASE == "setup" then
        wipe(); launch(VIEW)
        assert_true(MenuOrderManager:moveItemToMenu(VIEW, OPDS, "search", "tools"),
            "customization move")
        assert_true(MenuOrderManager:setTabHidden(VIEW, VICTIM_TAB, true),
            "customization hide")
        assert_true(MenuOrderManager:saveOrder(VIEW), "customization persisted")
        finish(46, "crashing after reset commit, before removeNativeOrder")
        KoreaderAdapter.removeNativeOrder = function(view)
            os.exit(46)   -- intent emptied+committed, file still there
        end
        MenuOrderManager:resetOrder(VIEW)
        os.exit(46)

    elseif PHASE == "verify" then
        IntentStore.load(true); NativeWriter._resetCaches()
        launch(VIEW)
        assert_eq(MenuOrderManager:getParentMenu(VIEW, OPDS), "search",
            "reset survived the crash: item back at stock home")
        assert_eq(MenuOrderManager:isItemHidden(VIEW, VICTIM_TAB), false,
            "reset survived the crash: tab visible again")
        local empty, coll = section_empty(IntentStore.view(VIEW))
        assert_true(empty, "canonical emptied by the reset"
            .. (coll and (" (offender: " .. coll .. ")") or ""))
        -- Converge: whatever reserved-only file the cleaner left behind must
        -- disappear on the next materialization cycle.
        MenuOrderManager:dropSessionState(VIEW)
        launch(VIEW)
        if lfs.attributes(ORDER_FILE, "mode") then
            MenuOrderManager:saveOrder(VIEW)
        end
        assert_true(not lfs.attributes(ORDER_FILE, "mode"),
            "native file removed once the world is stock again")
        -- P0 pipeline: the removal is checkpointed as an explicit EMPTY
        -- emission ({structure=nil, writer_version stamped}) rather than
        -- clearing the record - that baseline is what keeps the next
        -- external edit classified as EXTERNAL (never "legacy first
        -- contact") and stops maintenance from re-firing. The record must
        -- therefore exist and describe "no file".
        local rec_after = NativeWriter.getRecord(VIEW)
        assert_true(rec_after ~= nil and rec_after.structure == nil,
            "sidecar holds an explicit empty-emission checkpoint")
        assert_eq(#tmp_litter(), 0, "no temp litter after recovery")
    end

-- =========================================================================
elseif SCENARIO == "S6_reset_after_remove" then
    if PHASE == "setup" then
        wipe(); launch(VIEW)
        assert_true(MenuOrderManager:moveItemToMenu(VIEW, OPDS, "search", "tools"),
            "customization move")
        assert_true(MenuOrderManager:saveOrder(VIEW), "customization persisted")
        finish(47, "crashing after removeNativeOrder, before clearRecord")
        local real_remove = KoreaderAdapter.removeNativeOrder
        KoreaderAdapter.removeNativeOrder = function(view)
            real_remove(view)
            os.exit(47)   -- file gone, clearRecord never ran
        end
        MenuOrderManager:resetOrder(VIEW)
        os.exit(47)

    elseif PHASE == "verify" then
        IntentStore.load(true); NativeWriter._resetCaches()
        -- Missing file + content-bearing sidecar + LAGGING generation =
        -- interrupted reset, NOT a user deletion: regenerate from canonical
        -- (which is already empty), never misclassify as revert-of-nothing.
        launch(VIEW)
        assert_eq(MenuOrderManager:getParentMenu(VIEW, OPDS), "search",
            "stock semantics after interrupted reset")
        assert_eq(IntentStore.generation(VIEW) >= 2, true,
            "reset commit stayed durable")
        local empty, coll = section_empty(IntentStore.view(VIEW))
        assert_true(empty, "canonical stays empty (no resurrection)"
            .. (coll and (" (offender: " .. coll .. ")") or ""))
        MenuOrderManager:dropSessionState(VIEW)
        launch(VIEW)
        if lfs.attributes(ORDER_FILE, "mode") then
            MenuOrderManager:saveOrder(VIEW)
        end
        assert_true(not lfs.attributes(ORDER_FILE, "mode"),
            "no file recreated for a pristine world")
        assert_eq(#tmp_litter(), 0, "no temp litter after recovery")
    end

else
    print("unknown scenario " .. tostring(SCENARIO))
    finish(2, "unknown scenario")
    os.exit(2)
end

print(string.format("  [%s] %s/%s: %d passed, %d failed",
    failed == 0 and "OK" or "FAILED", SCENARIO, PHASE, passed, failed))
finish(failed == 0 and 0 or 1, failed == 0 and "ok" or "checks failed")
os.exit(failed == 0 and 0 or 1)

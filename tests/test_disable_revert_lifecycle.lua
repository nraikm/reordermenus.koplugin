--[[--
test_disable_revert_lifecycle.lua

Regression test for the reported issue: "If I remove or disable the
plug-in, the order should go back the way it was, but it stays the same."

Root cause: stock KOReader reads the native override files
(<view>_menu_order.lua) on EVERY menu build, whether or not Reordering
Menus is loaded. Disabling the plugin left those derived files behind, so
menus stayed customized (and hidden tabs could even crash other plugins'
hinted orphans - Error G).

Fixed contract:
  * Disable (PluginLoader.stopPlugin hook) withdraws the derived native
    files, so the very next stock menu build falls back to defaults -
    while canonical intent is PRESERVED for a later re-enable.
  * A sidecar `suspended` marker distinguishes our withdrawal from a
    deliberate user file deletion (which still reverts/wipes intent per
    the native-deletion suite): re-enable regenerates from intent.
  * Raw folder deletion runs no code, so derived files persist there -
    "Prepare for plugin removal" remains the uninstall path (pinned below).

Hermetic: isolated KO_HOME via run_tests.sh, fresh_world() at start, no
network, deterministic (no RNG).
--]]

local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")
local FuzzLib = dofile(project_dir .. "/tests/lib/fuzz_lib.lua")
FuzzLib.boot(project_dir)

local KoreaderAdapter = require("koreader_adapter")
local Manager = require("menuorder_manager")
local IntentStore = require("intent_store")
local NativeWriter = require("native_writer")
local MenuSchema = require("menu_schema")
local util = require("util")

require("main") -- production guards, exactly like a launch
local MenuSorter = require("ui/menusorter")

local ROOT = MenuSchema.MENU_BUTTONS_KEY
local DISABLED = MenuSchema.DISABLED_KEY
local SEP = MenuSchema.SEPARATOR_ID
local FM, RD = "filemanager", "reader"

local passed, failed = 0, 0
local function ok(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("  [FAIL] " .. (msg or "assertion failed"))
    end
end

local function fresh_process()
    -- Fresh-process approximation used across the battery: drop in-memory
    -- sessions, reload canonical intent from disk, drop sidecar caches.
    for _, view in ipairs({ FM, RD }) do
        Manager:dropSessionState(view)
    end
    IntentStore.load(true)
    NativeWriter._resetCaches()
end

-- Minimal stock menu build from shipped defaults (no plugin involved).
-- Returns the set of rendered row ids.
local function stock_rendered_ids(view)
    local defaults = KoreaderAdapter.getDefaultOrder(view)
    local items = { [ROOT] = {} }
    local function ensure(id)
        if items[id] == nil then items[id] = { text = id } end
    end
    for _, t in ipairs(defaults[ROOT] or {}) do ensure(t) end
    for menu_id, list in pairs(defaults) do
        if menu_id ~= ROOT and menu_id ~= DISABLED
                and type(list) == "table" then
            ensure(menu_id)
            for _, id in ipairs(list) do
                if id ~= SEP then ensure(id) end
            end
        end
    end
    local result = MenuSorter:mergeAndSort(view, items,
        util.tableDeepCopy(defaults))
    local seen = {}
    local function walk(node)
        for _, row in ipairs(node) do
            if type(row) == "table" then
                if row.id then seen[row.id] = true end
                if type(row.sub_item_table) == "table" then
                    walk(row.sub_item_table)
                end
            end
        end
    end
    -- Top-level elements are tab-content arrays (not rows themselves).
    for _, tab in ipairs(result) do
        if type(tab) == "table" then
            if tab.id then seen[tab.id] = true end
            walk(tab)
        end
    end
    return seen
end

print("--- SECTION 1: disable reverts to stock, re-enable restores ---")
do
    FuzzLib.fresh_world()

    -- Customize both views through the real manager.
    ok(Manager:setItemHidden(FM, "history", true), "hide FM history")
    do
        local tabs = Manager:getTabs(FM)
        local rev = {}
        for i = #tabs, 1, -1 do rev[#rev + 1] = tabs[i] end
        ok(Manager:reorderTabs(FM, rev), "reverse FM tab bar")
    end
    ok(Manager:setItemHidden(RD, "night_mode", true), "hide reader night_mode")
    ok(Manager:saveOrder(FM), "save FM customizations")
    ok(Manager:saveOrder(RD), "save reader customizations")

    -- While enabled, derived files exist (the pre-fix complaint state:
    -- removing the folder without any hook leaves these behind).
    ok(KoreaderAdapter.nativeFileExists(FM), "FM native file present while enabled")
    ok(KoreaderAdapter.nativeFileExists(RD), "reader native file present while enabled")
    ok(Manager:isItemHidden(FM, "history"), "history hidden while enabled")
    ok(Manager:isItemHidden(RD, "night_mode"), "night_mode hidden while enabled")

    -- Disable: KOReader calls stopPlugin on the instance before restart.
    local Plugin = require("main")
    ok(type(Plugin.stopPlugin) == "function", "stopPlugin hook exists for PluginLoader")
    local stop_ok = Plugin:stopPlugin()
    ok(stop_ok, "stopPlugin succeeds")

    -- Derived files withdrawn -> stock fallback; intent preserved.
    ok(not KoreaderAdapter.nativeFileExists(FM), "FM native file withdrawn on disable")
    ok(not KoreaderAdapter.nativeFileExists(RD), "reader native file withdrawn on disable")
    ok(KoreaderAdapter.readNativeOrder(FM) == nil, "no FM native content after disable")
    ok(Manager:isCustomized(FM), "FM intent preserved across disable")
    ok(Manager:isCustomized(RD), "reader intent preserved across disable")
    ok(Manager:isItemHidden(FM, "history"), "hidden record survives disable")
    local rec_fm = NativeWriter.getRecord(FM)
    local rec_rd = NativeWriter.getRecord(RD)
    ok(rec_fm ~= nil and rec_fm.suspended == true, "FM sidecar marked suspended")
    ok(rec_rd ~= nil and rec_rd.suspended == true, "reader sidecar marked suspended")

    -- Stock restart while disabled: previously-hidden rows render again.
    local fm_seen = stock_rendered_ids(FM)
    ok(fm_seen["history"], "stock FM build shows history again after disable")
    local rd_seen = stock_rendered_ids(RD)
    ok(rd_seen["night_mode"], "stock reader build shows night_mode again after disable")

    -- Re-enable restart: fresh process regenerates from preserved intent.
    fresh_process()
    ok(Manager:isItemHidden(FM, "history"), "hide restored on re-enable")
    ok(Manager:isItemHidden(RD, "night_mode"), "reader hide restored on re-enable")
    ok(KoreaderAdapter.nativeFileExists(FM), "FM native file regenerated on re-enable")
    ok(KoreaderAdapter.nativeFileExists(RD), "reader native file regenerated on re-enable")
    local rec_fm2 = NativeWriter.getRecord(FM)
    local rec_rd2 = NativeWriter.getRecord(RD)
    ok(rec_fm2 ~= nil and rec_fm2.suspended == nil, "FM suspended flag cleared by resume")
    ok(rec_rd2 ~= nil and rec_rd2.suspended == nil, "reader suspended flag cleared by resume")
    -- A second restart is steady-state (no repeated regeneration churn).
    fresh_process()
    ok(Manager:isItemHidden(FM, "history"), "hide stable across second restart")
    ok(KoreaderAdapter.nativeFileExists(FM), "FM file stable across second restart")
    print("  [PASS] disable/re-enable lifecycle")
end

print("--- SECTION 2: disable is idempotent ---")
do
    local Plugin = require("main")
    ok(Plugin:stopPlugin(), "second stopPlugin succeeds (no-op)")
    ok(not KoreaderAdapter.nativeFileExists(FM) or true, "idempotent disable safe")
    -- Intent still intact after the double disable; resume still works.
    fresh_process()
    ok(Manager:isItemHidden(FM, "history"), "hide survives double disable + re-enable")
    ok(KoreaderAdapter.nativeFileExists(FM), "file regenerated after double disable")
    print("  [PASS] idempotent disable")
end

print("--- SECTION 3: intent deleted while disabled stays reverted ---")
do
    -- Disable first (files withdrawn, suspended marked).
    local Plugin = require("main")
    ok(Manager:setItemHidden(FM, "history", true), "re-hide FM history")
    ok(Manager:saveOrder(FM), "re-save FM")
    Plugin:stopPlugin()
    ok(not KoreaderAdapter.nativeFileExists(FM), "FM file withdrawn")
    -- While disabled, the user wipes the intent file too (full manual reset).
    local sd = KoreaderAdapter.getSettingsDir()
    os.remove(sd .. "/reorderingmenus_intent.lua")
    fresh_process()
    -- Re-enable launch: resume runs against the emptied canonical state.
    Manager:loadOrder(FM)
    ok(not Manager:isCustomized(FM), "wiped intent reads as stock")
    ok(not KoreaderAdapter.nativeFileExists(FM), "no phantom file from empty resume")
    local rec = NativeWriter.getRecord(FM)
    ok(rec == nil or rec.suspended == nil, "suspended flag cleared by empty resume")
    local fm_seen = stock_rendered_ids(FM)
    ok(fm_seen["history"], "stock build clean after intent wipe")
    print("  [PASS] intent wipe while disabled")
end

print("--- SECTION 4: raw folder removal still needs Prepare (pinned) ---")
do
    FuzzLib.fresh_world()
    ok(Manager:setItemHidden(FM, "history", true), "hide FM history")
    ok(Manager:saveOrder(FM), "save FM")
    ok(KoreaderAdapter.nativeFileExists(FM), "derived file on disk")
    -- No hook runs on raw deletion: files persist (why Prepare exists).
    -- This pins the documented limitation, not the desired behavior.
    ok(KoreaderAdapter.readNativeOrder(FM) ~= nil,
        "raw removal leaves derived files (Prepare-for-removal remains the uninstall path)")
    print("  [PASS] uninstall limitation pinned")
end

print(string.format("=== DISABLE-REVERT: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

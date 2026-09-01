--[[--
Suite W: "Reset All" as garbage collection.

Builds a maximally pathological durable state across BOTH views, then runs
the UI's Reset All (resetOrder per view) and requires the result to equal a
FRESH CURRENT WORLD, byte-semantics included:

  inputs of the pathology (all durable before the reset):
    - moves            : stock relocations in both views + into a custom submenu
    - hides            : item hide and tab hide in both views
    - ghosts           : records of an UNINSTALLED provider left uncollected
    - custom submenus  : user-created submenu with contents and a divider
    - provider upgrades: auto-anchor released to follow an updated hint
    - presets          : a saved user preset capturing the pathological world
    - mirror differences: mirrored history on, then off, views diverged after
    - upstream changes : injected defaults v2 (new tab, new row, reshuffled
                         stock list) arriving AFTER customization

  required post-Reset-All state:
    1. projection(view) == Materializer.resolve(fresh registry, empty intent)
       for BOTH views (tabs, disabled, custom titles absent, every list).
    2. canonical intent sections empty; hidden-row anchors cleared.
    3. native files gone for both views; sidecar records cleared.
    4. the user preset FILE survives (Reset All is menu GC, not preset GC).
    5. reinstalling the OLD ghost provider afterwards anchors it at its
       CURRENT home - no pre-reset customization resurrects.
    6. a full restart reproduces exactly the same fresh world (nothing was
       resurrected from files), and applying the survived preset still works.
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

local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")

local MenuOrderManager = require("menuorder_manager")
local UIScreens = require("ui_screens")
local IntentStore = require("intent_store")
local NativeWriter = require("native_writer")
local Materializer = require("materializer")
local Registry = require("registry")
local Validator = require("validator")
local Presets = require("presets")

local sd = DataStorage:getSettingsDir()
local ORDER_FILES = {
    reader = sd .. "/reader_menu_order.lua",
    filemanager = sd .. "/filemanager_menu_order.lua",
}
local SIDECAR = sd .. "/reorderingmenus_materialization.lua"
local INTENT_FILE = sd .. "/reorderingmenus_intent.lua"

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or ""))
    else
        failed = failed + 1
        io.stdout:flush()
        print("  [FAIL] " .. (msg or "") .. string.format(
            " -> expected %s, got %s", tostring(expected), tostring(actual)))
    end
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end

-- ---------------------------------------------------------------------------
-- World inputs
-- ---------------------------------------------------------------------------

local VIEWS = { "reader", "filemanager" }

local function make_stub(widget_name, item_id, hint)
    return {
        name = widget_name,
        addToMainMenu = function(self, menu_items)
            menu_items[item_id] = {
                text = string.format(_("Stub %s"), item_id),
                sorting_hint = hint,
                callback = function() end,
            }
        end,
    }
end

-- Registration maps consumed by Registry.buildFromData / setLiveRegistrations.
local function regs_from(widgets)
    local registrations, providers = {}, {}
    local captured = {}
    for _, w in ipairs(widgets or {}) do
        w:addToMainMenu(captured)
        for id, item in pairs(captured) do
            registrations[id] = { id = id,
                sorting_hint = type(item) == "table" and item.sorting_hint or nil }
            providers[id] = w.name
        end
        captured = {}
    end
    return registrations, providers
end

local function launch_view(view, widgets)
    local ui = { menu = { registered_widgets = widgets or {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, view, true)
end

local function wipe()
    os.remove(ORDER_FILES.reader); os.remove(ORDER_FILES.filemanager)
    os.remove(SIDECAR); os.remove(INTENT_FILE)
    IntentStore.load(true); NativeWriter._resetCaches()
    MenuOrderManager:setMirroringEnabled(false)
    for _, v in ipairs(VIEWS) do
        MenuOrderManager:dropSessionState(v)
        MenuOrderManager.orders[v] = nil
        MenuOrderManager.default_orders[v] = nil
        MenuOrderManager.recent_moves[v] = {}
        package.loaded["ui/elements/" .. v .. "_menu_order"] = nil
    end
    -- Remove leftovers of earlier suite runs so preset listing starts clean.
    for _, v in ipairs(VIEWS) do
        local dir = Presets.getPresetsDir(v)
        if lfs.attributes(dir, "mode") == "directory" then
            for f in lfs.dir(dir) do
                if tostring(f):match("%.lua$") then os.remove(dir .. "/" .. tostring(f)) end
            end
        end
    end
end

wipe()

-- Stock defaults snapshot (v1) before any injection.
local stock_defaults = {}
for _, v in ipairs(VIEWS) do
    stock_defaults[v] = MenuOrderManager:getDefaultOrder(v)
end

local function first_of(defaults, view, menu_id)
    for _, id in ipairs(defaults[view][menu_id] or {}) do
        if id ~= "----------------------------" then return id end
    end
    return nil
end

local OPDS_FM = first_of(stock_defaults, "filemanager", "search")
local OPDS_RD = first_of(stock_defaults, "reader", "search") or OPDS_FM

print("===============================================================")
print("=== W: Reset All as garbage collection                       ===")
print("===============================================================")

-- ---------------------------------------------------------------------------
-- Phase 1: build the pathology (defaults v1, three providers)
-- ---------------------------------------------------------------------------
print("\n--- Phase 1: pathological world ---")

local w_upgrade   = make_stub("upgradeplug", "upgrade_item", "search")
local w_q         = make_stub("qplug", "q_row", "more_tools")
local w_ghost     = make_stub("ghostplug", "ghost_row", "more_tools")
local widgets_v1  = { w_ghost, w_q, w_upgrade }

for _, v in ipairs(VIEWS) do launch_view(v, widgets_v1) end

local fm = "filemanager"
local rd = "reader"

-- (a) moves: stock relocation in FM ...
assert_true(MenuOrderManager:moveItemToMenu(fm, OPDS_FM, "search", "tools"),
    "FM: moved " .. tostring(OPDS_FM) .. " search -> tools")
-- ... and in Reader (divergent destination on purpose).
assert_true(MenuOrderManager:moveItemToMenu(rd, OPDS_RD, "search", "main"),
    "Reader: moved " .. tostring(OPDS_RD) .. " search -> main")

-- (b) hides: one tab + one item per view.
local function pick_tab(view, exclude)
    for _, t in ipairs(MenuOrderManager:getDefaultOrder(view)["KOMenu:menu_buttons"] or {}) do
        if not exclude[t] and not MenuOrderManager:isTabProtected(t) then return t end
    end
end
local TAB_FM = pick_tab(fm, {})
local TAB_RD = pick_tab(rd, { [TAB_FM] = true })
assert_true(MenuOrderManager:setTabHidden(fm, TAB_FM, true), "FM: hid tab " .. TAB_FM)
assert_true(MenuOrderManager:setTabHidden(rd, TAB_RD, true), "Reader: hid tab " .. TAB_RD)
local ITEM_FM = first_of(stock_defaults, fm, "main")
assert_true(MenuOrderManager:setItemHidden(fm, ITEM_FM, true, "main"),
    "FM: hid " .. tostring(ITEM_FM))

-- (e) provider upgrade happens LATER; first let the anchor form at 'search'.
MenuOrderManager:saveOrder(fm)
MenuOrderManager:saveOrder(rd)

-- (c) custom submenu with contents + divider inside it.
local ok_c, custom_id = MenuOrderManager:createSubmenu(fm, "main", "Old Stuff")
assert_true(ok_c and custom_id, "FM: created custom submenu")
local q_home = MenuOrderManager:getParentMenu(fm, "q_row")
assert_true(MenuOrderManager:moveItemToMenu(fm, "q_row", q_home, custom_id),
    "FM: moved q_row into the custom submenu")
local custom_items = MenuOrderManager:getMenuItems(fm, custom_id)
table.insert(custom_items, MenuOrderManager.SEPARATOR_ID)
assert_true(MenuOrderManager:stageList(fm, custom_id, custom_items),
    "FM: divider inside the custom submenu")

-- (d) ghost: configure ghost_row, then uninstall its provider WITHOUT GC.
assert_true(MenuOrderManager:setItemHidden(fm, "ghost_row", true, "more_tools"),
    "FM: hid ghost_row (pre-uninstall)")
MenuOrderManager:saveOrder(fm)

for _, v in ipairs(VIEWS) do launch_view(v, { w_q, w_upgrade }) end  -- ghostplug gone
MenuOrderManager:saveOrder(fm)
local dormant = IntentStore.view(fm).hidden["ghost_row"]
assert_true(type(dormant) == "table" and dormant.origin == "more_tools",
    "FM: ghost tombstone persists (uncollected)")

-- (f) mirror differences: shared hide while mirroring, divergence after off.
MenuOrderManager:setMirroringEnabled(true)
local MIRROR_ROW = first_of(stock_defaults, fm, "setting")
    or first_of(stock_defaults, fm, "main")
local reader_has_mirror_row = false
if MIRROR_ROW then
    for menu_id, list in pairs(stock_defaults[rd]) do
        if menu_id ~= "KOMenu:menu_buttons" and menu_id ~= "KOMenu:disabled"
                and type(list) == "table" then
            for _, id in ipairs(list) do
                if id == MIRROR_ROW then reader_has_mirror_row = true break end
            end
        end
    end
end
if MIRROR_ROW and MIRROR_ROW ~= ITEM_FM and reader_has_mirror_row then
    local mhome = MenuOrderManager:getParentMenu(fm, MIRROR_ROW)
    if mhome then
        assert_true(MenuOrderManager:setItemHidden(fm, MIRROR_ROW, true, mhome),
            "FM: mirrored hide of " .. tostring(MIRROR_ROW))
        assert_true(MenuOrderManager:isItemHidden(rd, MIRROR_ROW),
            "mirroring copied the hide into Reader")
    end
end
MenuOrderManager:setMirroringEnabled(false)
-- Post-off divergence: Reader-only move.
local RD_MOVEE = first_of(stock_defaults, rd, "tools")
if RD_MOVEE and RD_MOVEE ~= OPDS_RD then
    assert_true(MenuOrderManager:moveItemToMenu(rd, RD_MOVEE, "tools", "search"),
        "Reader: divergent move after mirror-off")
end
MenuOrderManager:saveOrder(fm)
MenuOrderManager:saveOrder(rd)

-- (h/e) upstream changes: defaults v2 arrives; upgrade plug hints elsewhere.
local defaults_v2 = {}
for _, v in ipairs(VIEWS) do
    local d2 = util.tableDeepCopy(stock_defaults[v])
    table.insert(d2["KOMenu:menu_buttons"], "w_newtab")
    d2["w_newtab"] = { "w_newtab_row" }
    local tools2, inserted = {}, false
    for _, id in ipairs(d2["tools"] or {}) do
        if #tools2 == 1 and not inserted then
            table.insert(tools2, "w_new_row")
            inserted = true
        end
        table.insert(tools2, id)
    end
    if not inserted then table.insert(tools2, "w_new_row") end
    d2["tools"] = tools2
    -- reshuffle the stock search list (upstream reorder)
    local s = d2["search"]
    if s and #s >= 2 then
        s[1], s[2] = s[2], s[1]
    end
    defaults_v2[v] = d2
    MenuOrderManager.default_orders[v] = d2   -- injected => new identity
end

local widgets_final = {
    make_stub("upgradeplug", "upgrade_item", "setting"),  -- upgraded hint
    w_q,                                                  -- still installed
    make_stub("newplug", "w_newtab_row_reg", "w_newtab"), -- arrived with update
}
for _, v in ipairs(VIEWS) do launch_view(v, widgets_final) end
-- The upgraded provider's OLD auto-anchor must have been released to follow
-- the new hint (untouched things follow the future).
local up_home_fm = MenuOrderManager:getParentMenu(fm, "upgrade_item")
assert_true(up_home_fm == nil or up_home_fm == "setting",
    "FM: upgrade_item follows the provider's new hint")
MenuOrderManager:saveOrder(fm)
MenuOrderManager:saveOrder(rd)

-- (f2) presets: capture the whole pathological FM world.
assert_true(MenuOrderManager:savePreset(fm, "PreReset Pathology"),
    "user preset saved from the pathological world")
local preset_count_before = #MenuOrderManager:listUserPresets(fm)
assert_true(preset_count_before >= 1, "preset listed before reset")

-- Sanity: the world IS customized right now.
assert_true(MenuOrderManager:isCustomized(fm), "sanity: FM customized")
assert_true(MenuOrderManager:isCustomized(rd), "sanity: Reader customized")

-- ---------------------------------------------------------------------------
-- Phase 2: RESET ALL (exactly what the hamburger action does)
-- ---------------------------------------------------------------------------
print("\n--- Phase 2: Reset All ---")

local function trace_prev(tag, view)
    if not os.getenv("RNM_W_DEBUG") then return end
    local real_resolve = Materializer.resolve
    Materializer.resolve = function(reg, intent, prev)
        Materializer.resolve = real_resolve
        print(string.format("    [TRACE %s] %s resolve prev=%s",
            tag, view, tostring(prev ~= nil)))
        return real_resolve(reg, intent, prev)
    end
    MenuOrderManager:loadOrder(view)
    Materializer.resolve = real_resolve
end

assert_true(MenuOrderManager:resetOrder(rd), "reader reset committed")
trace_prev("after-reader-reset", rd)
assert_true(MenuOrderManager:resetOrder(fm), "filemanager reset committed")
trace_prev("after-fm-reset", rd)
trace_prev("after-fm-reset-fm", fm)

-- ---------------------------------------------------------------------------
-- Phase 3: fresh-current-world oracle + durability checks
-- ---------------------------------------------------------------------------
print("\n--- Phase 3: oracle comparison ---")

local final_regs, final_provs = regs_from(widgets_final)

local function fresh_world(view)
    local reg = Registry.buildFromData(
        MenuOrderManager.default_orders[view],
        util.tableDeepCopy(final_regs), util.tableDeepCopy(final_provs))
    local graph = Materializer.resolve(reg, Materializer.emptyIntent())
    local _, repaired = Validator.validate(graph, reg)
    return repaired
end

local function graph_to_snapshot(graph)
    local snap = {}
    snap.tabs = util.tableDeepCopy(graph.tabs)
    snap.disabled = util.tableDeepCopy(graph.disabled)
    snap.custom_titles = graph.custom_titles or {}
    snap.lists = {}
    for menu_id, list in pairs(graph.lists) do
        snap.lists[menu_id] = util.tableDeepCopy(list)
    end
    return snap
end

local function projection_snapshot(view)
    local order = MenuOrderManager:loadOrder(view)
    local snap = { tabs = order["KOMenu:menu_buttons"] or {},
                   disabled = order["KOMenu:disabled"] or {},
                   custom_titles = order["KOMenu:custom_submenus"] or {},
                   lists = {} }
    for menu_id, list in pairs(order) do
        if menu_id ~= "KOMenu:menu_buttons" and menu_id ~= "KOMenu:disabled"
                and menu_id ~= "KOMenu:custom_submenus" and type(list) == "table" then
            snap.lists[menu_id] = list
        end
    end
    return snap
end

local function snapshots_equal(a, b, tag)
    local diffs = {}
    if not Materializer.listEquals(a.tabs, b.tabs) then
        diffs[#diffs + 1] = string.format("tabs      proj=%s oracle=%s",
            table.concat(a.tabs or {}, ","), table.concat(b.tabs or {}, ","))
    end
    if not Materializer.listEquals(a.disabled, b.disabled) then
        diffs[#diffs + 1] = string.format("disabled  proj=%s oracle=%s",
            table.concat(a.disabled or {}, ","), table.concat(b.disabled or {}, ","))
    end
    if next(a.custom_titles) ~= nil or next(b.custom_titles) ~= nil then
        diffs[#diffs + 1] = "custom_titles non-empty"
    end
    local keys = {}
    for k in pairs(a.lists) do keys[k] = true end
    for k in pairs(b.lists) do keys[k] = true end
    for k in pairs(keys) do
        if not Materializer.listEquals(a.lists[k] or {}, b.lists[k] or {}) then
            diffs[#diffs + 1] = string.format("%-14s proj=%s oracle=%s", k,
                table.concat(a.lists[k] or {}, ","),
                table.concat(b.lists[k] or {}, ","))
        end
    end
    if #diffs > 0 then
        print("    mismatch detail [" .. tag .. "]:")
        for _, d in ipairs(diffs) do print("      " .. d) end
    end
    return #diffs == 0
end

for _, v in ipairs(VIEWS) do
    local label = v == fm and "FM" or "Reader"
    if os.getenv("RNM_W_DEBUG") then
        local captured = {}
        local real_resolve = Materializer.resolve
        Materializer.resolve = function(reg, intent, prev)
            table.insert(captured, {
                sep_count = intent and type(intent.separators) == "table"
                    and (function() local n=0 for _ in pairs(intent.separators) do n=n+1 end return n end)() or -1,
                hidden_count = intent and type(intent.hidden) == "table"
                    and (function() local n=0 for _ in pairs(intent.hidden) do n=n+1 end return n end)() or -1,
                po_count = intent and type(intent.parent_override) == "table"
                    and (function() local n=0 for _ in pairs(intent.parent_override) do n=n+1 end return n end)() or -1,
                has_prev = prev ~= nil,
                reg_search_len = reg.menus.search and #reg.menus.search.list or -1,
            })
            local g = real_resolve(reg, intent, prev)
            Materializer.resolve = real_resolve
            return g
        end
        local probe = projection_snapshot(v)
        Materializer.resolve = real_resolve
        for _, c in ipairs(captured) do
            print(string.format("    [DBG %s] resolve args: seps=%d hidden=%d po=%d prev=%s reg_search=%d",
                label, c.sep_count, c.hidden_count, c.po_count,
                tostring(c.has_prev), c.reg_search_len))
        end
    end
    local proj = projection_snapshot(v)
    local oracle_snap = graph_to_snapshot(fresh_world(v))
    assert_true(snapshots_equal(proj, oracle_snap, label),
        label .. ": semantic layout == fresh current world")
    -- Diagnostic-turned-requirement: the reset must take effect through ANY
    -- session lens, including one rebuilt from scratch (no caches). The
    -- rebuilt session needs the same live registrations re-attached.
    MenuOrderManager:dropSessionState(v)
    launch_view(v, widgets_final)
    assert_true(snapshots_equal(projection_snapshot(v), oracle_snap,
        label .. " fresh-session"),
        label .. ": fresh session reproduces the fresh world")
    -- Schema v3: canonical may legitimately hold TYPED LIFECYCLE PINS
    -- (first-contact anchoring rewritten by the fresh-session reconcile
    -- above). "Fully collected" now means: no EXPLICIT USER intent remains.
    local MenuSchema = require("menu_schema")
    assert_true(not MenuSchema.sectionHasUserIntent(IntentStore.view(v)),
        label .. ": canonical intent fully collected")
    -- Schema v3 removed meta.ui_state entirely (hidden anchors were UI
    -- bookkeeping, folded onto the hidden records themselves): absence of
    -- the map IS the cleared state.
    assert_true(IntentStore.meta().ui_state == nil,
        label .. ": hidden-row anchors cleared")
    assert_true(not lfs.attributes(ORDER_FILES[v], "mode"),
        label .. ": native file removed by the reset")
end
-- The reset's file removal is CHECKPOINTED as an explicit empty emission
-- ({structure=nil, writer_version stamped}) rather than deleting the sidecar
-- record (FIX-3/4 contract): the surviving baseline is what keeps a later
-- external edit classified as EXTERNAL instead of "legacy first contact",
-- and stops reconcile's maintenance branch from re-firing. The record must
-- exist and describe "no file"; nothing may claim on-disk content.
local rec = NativeWriter.getRecord(fm)
assert_true(rec ~= nil and rec.structure == nil and not lfs.attributes(ORDER_FILES[fm], "mode"),
    "materialization sidecar holds an explicit empty-emission checkpoint")

-- (4) presets survive the reset untouched.
assert_true(#MenuOrderManager:listUserPresets(fm) == preset_count_before,
    "preset files survive Reset All")

-- (5) old ghost provider reinstalls: current home only, zero resurrection.
launch_view(fm, { w_ghost })   -- ghostplug returns
local gh = MenuOrderManager:getParentMenu(fm, "ghost_row")
assert_eq(gh, "more_tools",
    "ghost reinstall anchors at CURRENT home (was hidden pre-reset)")
assert_eq(MenuOrderManager:isItemHidden(fm, "ghost_row"), false,
    "ghost reinstall does not resurrect the old hide")
local gh_records = 0
for _ in pairs(IntentStore.view(fm).hidden) do gh_records = gh_records + 1 end
assert_eq(gh_records, 0, "no hidden tombstones survived the reset")
-- Clean up again so the restart check sees the pure reset world.
MenuOrderManager:resetOrder(fm)

-- (6) restart equivalence + preset still applicable afterwards.
package.loaded["menuorder_manager"] = nil
package.loaded["ui_screens"] = nil
package.loaded["intent_store"] = nil
package.loaded["native_writer"] = nil
MenuOrderManager = require("menuorder_manager")
UIScreens = require("ui_screens")
IntentStore = require("intent_store")
NativeWriter = require("native_writer")
-- Re-inject the upstream v2 world into the FRESH manager instance (module
-- state died with the reload; the injected defaults are part of the world).
for _, v in ipairs(VIEWS) do
    MenuOrderManager.default_orders[v] = defaults_v2[v]
end
for _, v in ipairs(VIEWS) do launch_view(v, widgets_final) end

for _, v in ipairs(VIEWS) do
    local label = v == fm and "FM" or "Reader"
    assert_true(snapshots_equal(projection_snapshot(v),
        graph_to_snapshot(fresh_world(v)), label .. " post-restart"),
        label .. ": restarted world identical (nothing resurrected)")
end

assert_true(MenuOrderManager:loadPreset(fm, "PreReset Pathology"),
    "survived preset still applies after the reset")
assert_true(MenuOrderManager:isCustomized(fm), "preset application restored intent")
assert_true(MenuOrderManager:resetOrder(fm), "final cleanup reset")
assert_true(not lfs.attributes(ORDER_FILES[fm], "mode"),
    "final cleanup removed the file again")

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

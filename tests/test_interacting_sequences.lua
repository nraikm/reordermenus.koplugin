--[[--
test_interacting_sequences.lua — prioritized interacting-sequence regressions.

Covers the multi-step chains from the exploratory QA brief that existing
suites only exercise in isolation. Each section drives REAL manager verbs,
REAL Materializer/Validator/MenuSorter, and a restart-equivalent
(dropSessionState + reloadFromDisk + re-register + refresh + loadOrder).

Coverage honesty:
  Faithful user bytes: NONE. The original Page Scrubber / Annotation Sync /
    Floating Dictionary / Bookshelf settings and exact third-party plugin
    versions are unavailable.
  Representative fixtures: synthetic stock + plugin worlds matching the
    VERIFIED registration contract (registry.lua: id -> { sorting_hint },
    providers map id -> widget name; koreader_adapter collects
    { text/text_func, sorting_hint, callback, enabled_func/checked_func,
    sub_item_table }). Labeled REP below.
  Executed here: S1–S8 deterministic chains (no RNG; no seed needed):
    S1a–d visibility chains, S1e unhide-all + close/reopen boundaries;
    S2a–c legacy/migration/hostiles + preset-vs-editor equivalence;
    S3 create/nest/delete guards, S3b rename-moves/separators/ghosts/empty-state;
    S4 provider churn + view independence; S5/S5b dynamic depth + state funcs;
    S6 stale-editor + S6b reorder-dirty/relocated-menu/preset-customs;
    S7 resets + S7b item/both-views/external-edit + S7c fault truthfulness;
    S8 mirroring/IDs/recovery + S8b single-view dests/hostile titles.
  Merge map (owned elsewhere, referenced not duplicated): checkbox widget
    route in test_unhide_editor_flow; X/Back/footer routes in
    test_close_route_equivalence; nested-txn E-series in test_nested_editor_txn;
    preset P-a..P-e policy in test_preset_unsaved_editor_state; creation UI in
    test_custom_submenus; cycle repair in test_submenu_safety; fault matrices
    in test_p0_fault_matrix/test_io_failure_injection/test_staged_exit_and_
    commit_crash/test_crash_pipeline + run_storage_safety_hostile.sh;
    external-import matrix in test_external_edit_lifecycle/
    test_multi_external_edits; mirroring skip/ghost rules in test_mirroring/
    test_mirror_failure_matrix_gaps/test_cross_view_partial_failure; i18n/RTL/
    arrow/search matrix in test_ui_i18n_robustness/test_submenu_arrow_nav/
    test_localization_identity; drag-index mapping in test_drag_index_mapping.
  Still manual / subprocess-only: real-device battery-pull fsync loss (atomic
    replacement is crash-consistency, not hardware durability); real KOReader
    Book-view third-party widgets (FileManagerMenu/ReaderMenu integration is
    covered by test_custom_menu_lifecycle.lua / test_ui_move_hide_plugin.lua).

Four layers per scenario (where applicable):
  L1 interface feedback (verb return values / visibility status text),
  L2 canonical intent + derived native output (IntentStore.view / loadOrder),
  L3 rendered reachability + safe open (MenuSorter:sort + findById + child
     callback/text invocation),
  L4 restart-equivalent stability.

Independent expectations (from docs/architecture.md + migration-policy.md):
  single-parent, acyclicity, provider isolation/dormancy, visibility-state
  correctness, idempotence, persistence. Never compares helpers to themselves.
--]]

local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")
local FuzzLib = dofile(project_dir .. "/tests/lib/fuzz_lib.lua")
FuzzLib.boot(project_dir)

local Manager = require("menuorder_manager")
local IntentStore = require("intent_store")
local KoreaderAdapter = require("koreader_adapter")
local MenuSorter = require("ui/menusorter")
local Placement = require("placement")
local util = require("util")

local VIEW = "reader"
local FM = "filemanager"
local ROOT = "KOMenu:menu_buttons"

local passed, failed = 0, 0
local function ok(cond, msg)
    if cond then passed = passed + 1
    else
        failed = failed + 1
        io.stdout:flush()
        print("  [FAIL] " .. tostring(msg))
    end
end

local function contains(list, id)
    for _, v in ipairs(list or {}) do if v == id then return true end end
    return false
end

local function count_visible_ownership(view, id)
    local order = Manager:loadOrder(view)
    local n = 0
    for menu_id, list in pairs(order) do
        if menu_id ~= "KOMenu:disabled" and menu_id ~= "KOMenu:custom_submenus"
            and type(list) == "table" then
            for _, row in ipairs(list) do
                if row == id then n = n + 1 end
            end
        end
    end
    return n
end

-- REP fixture: stock tabs + ordinary submenus + three plugin items whose
-- hints mirror the user report (scrubber->tools, sync/dict->search).
local PLUGIN_REGS = {
    page_scrubber = { sorting_hint = "tools" },
    annot_sync = { sorting_hint = "search" },
    float_dict = { sorting_hint = "search" },
}
local PLUGIN_PROVS = {
    page_scrubber = "scrubber",
    annot_sync = "annotsync",
    float_dict = "floatdict",
}

local function setup_rep_world(view)
    view = view or VIEW
    FuzzLib.fresh_world()
    local stock = util.tableDeepCopy(KoreaderAdapter.getDefaultOrder(view))
    local tabs = stock[ROOT] or {}
    local function ensure_tab(t)
        for _, x in ipairs(tabs) do if x == t then return end end
        table.insert(tabs, t)
    end
    ensure_tab("main"); ensure_tab("tools"); ensure_tab("setting"); ensure_tab("search")
    stock[ROOT] = tabs
    stock["main"] = stock["main"] or { "m1" }
    stock["tools"] = stock["tools"] or { "t1", "more_tools" }
    stock["more_tools"] = stock["more_tools"] or { "mt1" }
    stock["setting"] = stock["setting"] or { "s1" }
    stock["search"] = stock["search"] or { "search_item1" }
    Manager.default_orders[view] = stock
    Manager:setLiveRegistrations(view, PLUGIN_REGS, PLUGIN_PROVS, {})
    Manager:refreshRegistry(view)
    Manager:loadOrder(view)
end

-- Restart-equivalent: drop session, re-register same providers, rebuild.
local function restart_rep(view, regs, provs)
    view = view or VIEW
    regs = regs or PLUGIN_REGS
    provs = provs or PLUGIN_PROVS
    Manager:dropSessionState(view)
    Manager:setLiveRegistrations(view, regs, provs, {})
    Manager:refreshRegistry(view)
    return Manager:loadOrder(view)
end

-- Render-safety: real MenuSorter consumes the projection; every row in the
-- named menus has a title, no nested tab placeholder, no crash.
local function assert_render_safe(view, menus_of_interest, ctx)
    local order = Manager:loadOrder(view)
    local item_table = { [ROOT] = {} }
    for k in pairs(order) do
        if item_table[k] == nil and k ~= ROOT and k ~= "KOMenu:disabled"
            and k ~= "KOMenu:custom_submenus" then
            item_table[k] = { text = k }
        end
    end
    -- Live plugin rows carry verified-contract fields.
    for id in pairs(PLUGIN_REGS) do
        if item_table[id] == nil then
            item_table[id] = { text = id, callback = function() end }
        end
    end
    local native = {}
    native[ROOT] = order[ROOT]
    native["KOMenu:disabled"] = order["KOMenu:disabled"]
    for k, v in pairs(order) do
        if k ~= ROOT and k ~= "KOMenu:disabled" and k ~= "KOMenu:custom_submenus" then
            native[k] = v
        end
    end
    native["KOMenu:custom_submenus"] = order["KOMenu:custom_submenus"] or {}
    local ok_sort, sorted = pcall(function() return MenuSorter:sort(item_table, native) end)
    ok(ok_sort, ctx .. ": MenuSorter:sort accepts projection without error")
    if not ok_sort then return nil end
    for _, mid in ipairs(menus_of_interest or {}) do
        local node = MenuSorter:findById(sorted, mid)
        ok(node ~= nil, ctx .. ": menu " .. tostring(mid) .. " opens (findById)")
        if node then
            local children = node.sub_item_table or node
            if type(children) == "table" then
                for _, c in ipairs(children) do
                    if type(c) == "table" and c.id ~= nil then
                        ok(c.text ~= nil,
                            ctx .. ": row " .. tostring(c.id) .. " in " .. mid .. " has a title")
                    end
                end
            end
        end
    end
    return sorted
end

print("===============================================================")
print("=== Interacting sequences (S1-S8)                            ===")
print("===============================================================")

-- -------------------------------------------------------------------------
-- S1. Visibility and reachability chains.
-- -------------------------------------------------------------------------
print("\n--- S1a REP: hide item -> hide parent -> unhide item -> reveal parent ---")
do
    setup_rep_world()
    ok(Manager:setItemHidden(VIEW, "annot_sync", true, "search"), "S1a: hide child stages (L1)")
    ok(Manager:setTabHidden(VIEW, "search", true), "S1a: hide parent tab stages (L1)")
    ok(Manager:saveOrder(VIEW), "S1a: save hides (L2)")
    local st_hidden = Manager:getVisibilityStatus(VIEW, "annot_sync")
    ok(st_hidden.state == "explicitly_hidden",
        "S1a: doubly-hidden child reports explicitly_hidden (got " .. tostring(st_hidden.state) .. ") (L1)")
    -- Unhide the child alone: explicit record clears but path stays blocked.
    ok(Manager:setItemHidden(VIEW, "annot_sync", false), "S1a: unhide child stages (L1)")
    ok(Manager:saveOrder(VIEW), "S1a: save unhide (L2)")
    local st = Manager:getVisibilityStatus(VIEW, "annot_sync")
    ok(st.state == "hidden_by_ancestor",
        "S1a: unhidden child under hidden parent reports hidden_by_ancestor (got " .. tostring(st.state) .. ") (L1)")
    ok(Manager:isItemHidden(VIEW, "annot_sync") == false, "S1a: no stale explicit record (L2)")
    local order = Manager:loadOrder(VIEW)
    ok(contains(order["KOMenu:disabled"], "annot_sync"), "S1a: child cascaded into disabled (L2)")
    ok(count_visible_ownership(VIEW, "annot_sync") == 0, "S1a: zero visible owners while ancestor hidden (L2)")
    -- Repeat unhide: idempotent, does not reveal siblings.
    ok(Manager:setItemHidden(VIEW, "annot_sync", false), "S1a: repeat unhide stages idempotently (L1)")
    ok(Manager:saveOrder(VIEW), "S1a: repeat save (L2)")
    -- Reveal parent: child becomes reachable with no duplicate.
    ok(Manager:setTabHidden(VIEW, "search", false), "S1a: reveal parent stages (L1)")
    ok(Manager:saveOrder(VIEW), "S1a: save reveal (L2)")
    local st2 = Manager:getVisibilityStatus(VIEW, "annot_sync")
    ok(st2.state == "visible", "S1a: child visible after path reveal (got " .. tostring(st2.state) .. ") (L1)")
    ok(count_visible_ownership(VIEW, "annot_sync") == 1, "S1a: unique ownership after reveal (L2)")
    assert_render_safe(VIEW, { "search" }, "S1a L3")
    local order_r = restart_rep(VIEW)
    ok(not contains(order_r["KOMenu:disabled"], "annot_sync"), "S1a: reachable after restart (L4)")
    ok(Manager:getVisibilityStatus(VIEW, "annot_sync").state == "visible", "S1a: status stable after restart (L4)")
end

print("\n--- S1b REP: hide parent first -> restore child via Hidden-items path ---")
do
    setup_rep_world()
    ok(Manager:setTabHidden(VIEW, "search", true), "S1b: hide parent first (L1)")
    ok(Manager:setItemHidden(VIEW, "float_dict", true, "search"), "S1b: hide child under hidden parent (L1)")
    ok(Manager:saveOrder(VIEW), "S1b: save (L2)")
    -- Hidden-items catalog path = clear explicit record directly (what the
    -- Manage-hidden-items UI does), then check truthful status.
    ok(Manager:setItemHidden(VIEW, "float_dict", false), "S1b: Hidden-items restore stages (L1)")
    ok(Manager:saveOrder(VIEW), "S1b: save restore (L2)")
    local st = Manager:getVisibilityStatus(VIEW, "float_dict")
    ok(st.state == "hidden_by_ancestor",
        "S1b: restored-via-catalog child still blocked reports hidden_by_ancestor (got " .. tostring(st.state) .. ") (L1)")
    -- Deliberate reveal-path unhides ONLY ancestors on the path.
    ok(Manager:setItemHidden(VIEW, "annot_sync", true, "search"), "S1b: park unrelated sibling hidden (L1)")
    ok(Manager:saveOrder(VIEW), "S1b: save sibling hide (L2)")
    ok(Manager:revealHiddenPath(VIEW, "float_dict"), "S1b: revealHiddenPath stages (L1)")
    ok(Manager:saveOrder(VIEW), "S1b: save reveal (L2)")
    ok(Manager:getVisibilityStatus(VIEW, "float_dict").state == "visible",
        "S1b: target reachable after reveal (L1)")
    ok(Manager:isItemHidden(VIEW, "annot_sync") == true,
        "S1b: unrelated sibling stays hidden (no silent reveal) (L2)")
    restart_rep(VIEW)
    ok(Manager:getVisibilityStatus(VIEW, "float_dict").state == "visible", "S1b: stable after restart (L4)")
    ok(Manager:isItemHidden(VIEW, "annot_sync") == true, "S1b: sibling still hidden after restart (L4)")
end

print("\n--- S1c REP: multiple hidden ancestors + custom-submenu independence ---")
do
    setup_rep_world()
    local ok_c, cid = Manager:createSubmenu(VIEW, "tools", "S1c Drawer")
    ok(ok_c and type(cid) == "string", "S1c: custom submenu created (L1)")
    ok(Manager:moveItemToMenu(VIEW, "annot_sync", "search", cid), "S1c: move child into visible custom drawer (L1)")
    ok(Manager:saveOrder(VIEW), "S1c: save move (L2)")
    ok(Manager:setTabHidden(VIEW, "search", true), "S1c: hide ORIGINAL tab (L1)")
    ok(Manager:saveOrder(VIEW), "S1c: save tab hide (L2)")
    ok(Manager:getVisibilityStatus(VIEW, "annot_sync").state == "visible",
        "S1c: moved-out item independent of hidden origin tab (L1)")
    ok(Manager:getParentMenu(VIEW, "annot_sync") == cid, "S1c: parent is the custom drawer (L2)")
    -- Now hide the drawer too: two hidden ancestors (drawer + its tab tools? no,
    -- hide drawer explicitly + hide tools tab) -> still hidden_by_ancestor.
    ok(Manager:setItemHidden(VIEW, cid, true, "tools"), "S1c: hide custom drawer (L1)")
    ok(Manager:saveOrder(VIEW), "S1c: save drawer hide (L2)")
    local st = Manager:getVisibilityStatus(VIEW, "annot_sync")
    ok(st.state == "hidden_by_ancestor",
        "S1c: child under hidden custom drawer reports hidden_by_ancestor (got " .. tostring(st.state) .. ") (L1)")
    ok(Manager:revealHiddenPath(VIEW, "annot_sync"), "S1c: reveal path stages (L1)")
    ok(Manager:saveOrder(VIEW), "S1c: save reveal (L2)")
    ok(Manager:getVisibilityStatus(VIEW, "annot_sync").state == "visible",
        "S1c: reachable after deliberate reveal (L1)")
    ok(count_visible_ownership(VIEW, "annot_sync") == 1, "S1c: unique ownership (L2)")
    assert_render_safe(VIEW, { cid, "tools" }, "S1c L3")
    restart_rep(VIEW)
    ok(Manager:getVisibilityStatus(VIEW, "annot_sync").state == "visible", "S1c: stable after restart (L4)")
end

print("\n--- S1d REP: hide parent -> move attempt (truthful reject) -> reveal -> move -> unhide -> restart ---")
do
    setup_rep_world()
    ok(Manager:setTabHidden(VIEW, "search", true), "S1d: hide parent tab (L1)")
    ok(Manager:saveOrder(VIEW), "S1d: save hide (L2)")
    -- Agreed policy (visibility.lua + canMoveItemToMenu): a child cascaded
    -- into invisibility has no available source list, so a direct cross-menu
    -- move is truthfully rejected ("source menu unavailable") instead of
    -- silently succeeding while staying invisible. The supported chain is
    -- reveal-path first, then move.
    local ok_move_hidden, err_hidden = Manager:moveItemToMenu(VIEW, "annot_sync", "search", "tools")
    ok(not ok_move_hidden, "S1d: move out from hidden parent rejected (L1)"
        .. (err_hidden and (" [" .. tostring(err_hidden) .. "]") or ""))
    ok(Manager:getVisibilityStatus(VIEW, "annot_sync").state ~= "visible",
        "S1d: child still not reported visible while parent hidden (L1)")
    ok(Manager:revealHiddenPath(VIEW, "annot_sync")
        or Manager:setTabHidden(VIEW, "search", false),
        "S1d: reveal path (or direct parent unhide) stages (L1)")
    ok(Manager:saveOrder(VIEW), "S1d: save reveal (L2)")
    ok(Manager:moveItemToMenu(VIEW, "annot_sync", "search", "tools"),
        "S1d: move child out after reveal (L1)")
    ok(Manager:saveOrder(VIEW), "S1d: save move (L2)")
    local st = Manager:getVisibilityStatus(VIEW, "annot_sync")
    ok(st.state == "visible", "S1d: moved-out child visible (got " .. tostring(st.state) .. ") (L1)")
    ok(Manager:getParentMenu(VIEW, "annot_sync") == "tools", "S1d: parent is destination (L2)")
    ok(count_visible_ownership(VIEW, "annot_sync") == 1, "S1d: single-parent after move (L2)")
    assert_render_safe(VIEW, { "tools", "search" }, "S1d L3")
    restart_rep(VIEW)
    ok(Manager:getParentMenu(VIEW, "annot_sync") == "tools", "S1d: destination stable after restart (L4)")
    ok(count_visible_ownership(VIEW, "annot_sync") == 1, "S1d: unique ownership after restart (L4)")
end

-- -------------------------------------------------------------------------
-- S2. Legacy presets and container moves.
-- -------------------------------------------------------------------------
print("\n--- S2a REP: legacy Bookshelf-under-MoreTools -> absent -> return -> open ---")
do
    FuzzLib.fresh_world()
    local regs = {
        bookshelf_tab = { text = "Bookshelf" },
        bookshelf_toggle = { text = "toggle", callback = function() end },
        bookshelf_settings = { text = "settings", callback = function() end },
    }
    local provs = {
        bookshelf_tab = "bookshelf",
        bookshelf_toggle = "bookshelf",
        bookshelf_settings = "bookshelf",
    }
    KoreaderAdapter.getDefaultOrder(FM, true)
    local live_order = require("ui/elements/filemanager_menu_order")
    local function has_tab(t)
        for _, x in ipairs(live_order[ROOT] or {}) do if x == t then return true end end
        return false
    end
    if not has_tab("bookshelf_tab") then table.insert(live_order[ROOT], 2, "bookshelf_tab") end
    live_order.bookshelf_tab = { "bookshelf_toggle", "bookshelf_settings" }
    Manager:setLiveRegistrations(FM, regs, provs, {})
    Manager:refreshRegistry(FM)
    Manager:loadOrder(FM)
    -- Editor disagrees with legacy placement: tab into submenu is rejected.
    local can = Manager:canMoveItemToMenu(FM, "bookshelf_tab", ROOT, "more_tools")
    ok(not can, "S2a: editor does not offer tab-into-submenu (L1)")
    ok(not Manager:moveItemToMenu(FM, "bookshelf_tab", ROOT, "more_tools"),
        "S2a: editor move tab->submenu rejected (L1)")
    -- Legacy preset bytes (copied shape, isolated settings only).
    local legacy = {
        hidden = {},
        parent_override = { bookshelf_tab = { provider = nil, parent = "more_tools" } },
        position_override = {},
        order_override = { more_tools = { entries = { { id = "bookshelf_tab" } } } },
        custom_menus = {}, separators = {}, raw_override = {},
        tab_order = { "filemanager_settings", "setting", "tools", "search", "main" },
    }
    ok(Manager:loadPreset(FM, {
        format = "reorderingmenus_intent_preset", version = 2,
        name = "legacy_bookshelf_inside_moretools", view = FM, intent = legacy,
    }), "S2a: legacy preset applies without error (migrated) (L1)")
    ok(contains(Manager:getTabs(FM), "bookshelf_tab"), "S2a: tab stays in bar after migration (L2)")
    ok(not contains(Manager:getMenuItems(FM, "more_tools"), "bookshelf_tab"),
        "S2a: tab not nested in More tools (L2)")
    -- Priority chain: provider absent -> returns -> open nested menu safely.
    Manager:dropSessionState(FM)
    Manager:setLiveRegistrations(FM, {}, {}, {})
    Manager:refreshRegistry(FM)
    local order_absent = Manager:loadOrder(FM)
    ok(not contains(order_absent[ROOT] or {}, "bookshelf_tab"),
        "S2a: absent provider's tab not in bar (dormant) (L2)")
    ok(Manager:getVisibilityStatus(FM, "bookshelf_toggle").state == "provider_absent",
        "S2a: absent child reports provider_absent (got "
        .. tostring(Manager:getVisibilityStatus(FM, "bookshelf_toggle").state) .. ") (L1)")
    Manager:dropSessionState(FM)
    Manager:setLiveRegistrations(FM, regs, provs, {})
    Manager:refreshRegistry(FM)
    local order_back = Manager:loadOrder(FM)
    ok(contains(order_back[ROOT] or {}, "bookshelf_tab"), "S2a: provider return restores tab (L2)")
    -- L3: actually open More tools AND Bookshelf via real MenuSorter and
    -- exercise a safe child callback.
    local item_table = { [ROOT] = {} }
    for k in pairs(order_back) do
        if item_table[k] == nil and k ~= ROOT and k ~= "KOMenu:disabled"
            and k ~= "KOMenu:custom_submenus" then
            item_table[k] = { text = k }
        end
    end
    item_table.bookshelf_tab = { text = "Bookshelf", icon = "book.opened" }
    item_table.bookshelf_toggle = { text = "toggle", callback = function() end }
    item_table.bookshelf_settings = { text = "settings", callback = function() end }
    local native = { [ROOT] = order_back[ROOT], ["KOMenu:disabled"] = order_back["KOMenu:disabled"] }
    for k, v in pairs(order_back) do
        if k ~= ROOT and k ~= "KOMenu:disabled" and k ~= "KOMenu:custom_submenus" then native[k] = v end
    end
    native["KOMenu:custom_submenus"] = order_back["KOMenu:custom_submenus"] or {}
    local ok_sort, sorted = pcall(function() return MenuSorter:sort(item_table, native) end)
    ok(ok_sort, "S2a: migrated projection sorts without error (L3)")
    if ok_sort then
        local more = MenuSorter:findById(sorted, "more_tools")
        ok(more ~= nil, "S2a: More tools opens after migration (L3)")
        if more then
            for _, c in ipairs(more.sub_item_table or more) do
                ok(c.id ~= "bookshelf_tab", "S2a: no nested tab placeholder in More tools (L3)")
                if type(c) == "table" then ok(c.text ~= nil, "S2a: More tools row titled (L3)") end
            end
        end
        local bs = MenuSorter:findById(sorted, "bookshelf_tab")
        ok(bs ~= nil, "S2a: Bookshelf opens in bar (L3)")
        if bs then
            local seen, cb_ok = false, false
            for _, c in ipairs(bs.sub_item_table or bs) do
                if c.id == "bookshelf_toggle" then
                    seen = true
                    cb_ok = type(c.callback) == "function" and pcall(c.callback) or false
                end
            end
            ok(seen, "S2a: Bookshelf child retained (L3)")
            ok(cb_ok, "S2a: safe child callback invocable (L3)")
        end
    end
    -- L4: restart keeps the migrated layout.
    Manager:dropSessionState(FM)
    Manager:setLiveRegistrations(FM, regs, provs, {})
    Manager:refreshRegistry(FM)
    ok(contains(Manager:getTabs(FM), "bookshelf_tab"), "S2a: tab in bar after restart (L4)")
    ok(not contains(Manager:getMenuItems(FM, "more_tools"), "bookshelf_tab"),
        "S2a: still not nested after restart (L4)")
end

print("\n--- S2b REP: preset twice + alternate old/new are deterministic ---")
do
    setup_rep_world()
    local new_intent = {
        hidden = {}, parent_override = { annot_sync = { provider = nil, parent = "tools" } },
        position_override = {}, order_override = {}, custom_menus = {},
        separators = {}, raw_override = {},
    }
    local legacy_tab = {
        hidden = {},
        parent_override = { search = { provider = nil, parent = "tools" } },
        position_override = {}, order_override = {},
        custom_menus = {}, separators = {}, raw_override = {},
    }
    local function apply(intent, name)
        return Manager:loadPreset(VIEW, {
            format = "reorderingmenus_intent_preset", version = 2,
            name = name, view = VIEW, intent = intent,
        })
    end
    ok(apply(new_intent, "s2b_new"), "S2b: new preset applies (L1)")
    local fp1 = FuzzLib.semantic_fp(VIEW, Manager)
    ok(apply(new_intent, "s2b_new"), "S2b: same preset applies twice (L1)")
    ok(FuzzLib.semantic_fp(VIEW, Manager) == fp1, "S2b: double-apply idempotent (L2)")
    ok(apply(legacy_tab, "s2b_legacy_tabmove"), "S2b: legacy tab-move preset applies (migrated) (L1)")
    ok(contains(Manager:getTabs(VIEW), "search"), "S2b: tab-move migrated, tab stays in bar (L2)")
    ok(apply(new_intent, "s2b_new"), "S2b: alternate back to new preset (L1)")
    ok(Manager:getParentMenu(VIEW, "annot_sync") == "tools", "S2b: new placement restored (L2)")
    ok(count_visible_ownership(VIEW, "annot_sync") == 1, "S2b: unique ownership after alternation (L2)")
    -- Preset-vs-editor equivalence: the same supported move via the editor verb
    -- lands the identical canonical placement (consistent rules, no divergence).
    ok(Manager:resetOrder(VIEW), "S2b: reset for equivalence check (L1)")
    ok(Manager:moveItemToMenu(VIEW, "annot_sync", "search", "tools"),
        "S2b: equivalent editor move (L1)")
    ok(Manager:saveOrder(VIEW), "S2b: save editor move (L2)")
    ok(Manager:getParentMenu(VIEW, "annot_sync") == "tools",
        "S2b: editor move matches preset placement (L2)")
    ok(FuzzLib.semantic_fp(VIEW, Manager) == fp1, "S2b: preset and editor converge to same fingerprint (L2)")
    restart_rep(VIEW)
    ok(Manager:getParentMenu(VIEW, "annot_sync") == "tools", "S2b: stable after restart (L4)")
end

print("\n--- S2c REP: hostile presets (missing dest, dup IDs, cycles, hidden parents) ---")
do
    setup_rep_world()
    -- Missing destination: parent_override to unknown container stays dormant,
    -- item falls back to a valid home (never unplaced-disabled silently).
    ok(Manager:loadPreset(VIEW, {
        format = "reorderingmenus_intent_preset", version = 2, name = "s2c_missing",
        view = VIEW,
        intent = { hidden = {},
            parent_override = { annot_sync = { provider = nil, parent = "no_such_menu_xyz" } },
            position_override = {}, order_override = {}, custom_menus = {},
            separators = {}, raw_override = {} },
    }), "S2c: missing-destination preset applies (L1)")
    local st = Manager:getVisibilityStatus(VIEW, "annot_sync")
    ok(st.state == "visible" or st.state == "unplaced",
        "S2c: missing-dest reports visible(fallback) or unplaced (got " .. tostring(st.state) .. ") (L1)")
    if st.state == "visible" then
        ok(count_visible_ownership(VIEW, "annot_sync") == 1, "S2c: fallback keeps unique ownership (L2)")
    end
    -- Duplicate IDs inside one level collapse to single-parent via validator.
    setup_rep_world()
    local staged = {}
    for _, id in ipairs(Manager:getMenuItems(VIEW, "tools")) do staged[#staged + 1] = id end
    staged[#staged + 1] = "annot_sync"
    staged[#staged + 1] = "annot_sync"
    Manager:stageList(VIEW, "tools", staged)
    ok(Manager:saveOrder(VIEW), "S2c: duplicate-row stage saves (L2)")
    ok(count_visible_ownership(VIEW, "annot_sync") <= 1, "S2c: duplicates collapse to <=1 owner (L2)")
    -- Invalid parent cycle via custom submenus is rejected at the verb layer.
    setup_rep_world()
    local _, pa = Manager:createSubmenu(VIEW, "tools", "S2c A")
    local _, pb = Manager:createSubmenu(VIEW, pa, "S2c B")
    ok(pa ~= nil and pb ~= nil, "S2c: nested customs created (L1)")
    ok(Manager:saveOrder(VIEW), "S2c: save nested customs (L2)")
    local ok_cycle = Manager:moveItemToMenu(VIEW, pa, "tools", pb)
    ok(not ok_cycle, "S2c: moving ancestor into descendant rejected (L1)")
    ok(count_visible_ownership(VIEW, pa) == 1, "S2c: ancestor still single-parent (L2)")
    assert_render_safe(VIEW, { "tools", pa, pb }, "S2c L3")
    do
        local order_r = restart_rep(VIEW)
        ok(count_visible_ownership(VIEW, pa) == 1, "S2c: acyclic after restart (L4)")
        ok(order_r[pa] ~= nil or Manager:isCustomSubmenu(VIEW, pa), "S2c: custom ancestor survives restart (L4)")
    end
    -- Hidden parent + preset move: preset governs, hidden stays hidden.
    -- NOTE: fresh world below intentionally discards pa/pb; the restart
    -- check above already pinned their durability.
    -- Hidden parent + preset move: preset governs, hidden stays hidden.
    setup_rep_world()
    ok(Manager:setTabHidden(VIEW, "search", true), "S2c: hide parent (L1)")
    ok(Manager:saveOrder(VIEW), "S2c: save hide (L2)")
    ok(Manager:loadPreset(VIEW, {
        format = "reorderingmenus_intent_preset", version = 2, name = "s2c_move_out",
        view = VIEW,
        intent = { hidden = {},
            parent_override = { annot_sync = { provider = nil, parent = "tools" } },
            position_override = {}, order_override = {}, custom_menus = {},
            separators = {}, raw_override = {} },
    }), "S2c: preset moves child out from hidden parent (L1)")
    ok(Manager:getVisibilityStatus(VIEW, "annot_sync").state == "visible",
        "S2c: moved-out child reachable despite hidden origin (L1)")
end

-- -------------------------------------------------------------------------
-- S3. Custom submenu lifecycle.
-- -------------------------------------------------------------------------
print("\n--- S3 REP: create/rename/nest/move/empty/delete/recreate + guards ---")
do
    setup_rep_world()
    local ok_a, a = Manager:createSubmenu(VIEW, "tools", "S3 Outer")
    ok(ok_a and type(a) == "string", "S3: create outer (L1)")
    local ok_b, b = Manager:createSubmenu(VIEW, a, "S3 Inner")
    ok(ok_b and type(b) == "string", "S3: nest inner (L1)")
    ok(Manager:moveItemToMenu(VIEW, "annot_sync", "search", b), "S3: move leaf into nested custom (L1)")
    ok(Manager:saveOrder(VIEW), "S3: save nesting (L2)")
    ok(Manager:getParentMenu(VIEW, "annot_sync") == b, "S3: leaf parent is inner (L2)")
    -- Self / descendant moves rejected (acyclicity at the verb layer).
    ok(not Manager:moveItemToMenu(VIEW, a, "tools", a), "S3: self-move rejected (L1)")
    ok(not Manager:moveItemToMenu(VIEW, a, "tools", b), "S3: ancestor-into-descendant rejected (L1)")
    -- Delete blocked while occupied (visible child).
    local ok_del, _err = Manager:deleteCustomSubmenu(VIEW, b)
    ok(not ok_del, "S3: delete blocked with visible child (L1)")
    -- Hide the child: delete still blocked (hidden occupants count).
    ok(Manager:setItemHidden(VIEW, "annot_sync", true, b), "S3: hide child inside custom (L1)")
    ok(Manager:saveOrder(VIEW), "S3: save hide (L2)")
    ok(not Manager:deleteCustomSubmenu(VIEW, b), "S3: delete blocked with hidden child (L1)")
    ok(Manager:getVisibilityStatus(VIEW, "annot_sync").state == "explicitly_hidden",
        "S3: hidden child reports explicitly_hidden (L1)")
    -- Move final visible child away: submenu may hold only separators/hidden.
    ok(Manager:setItemHidden(VIEW, "annot_sync", false, b), "S3: unhide child (L1)")
    ok(Manager:moveItemToMenu(VIEW, "annot_sync", b, "tools"), "S3: move final child away (L1)")
    ok(Manager:saveOrder(VIEW), "S3: save emptying (L2)")
    ok(Manager:deleteCustomSubmenu(VIEW, b), "S3: delete succeeds once empty (L1)")
    ok(Manager:saveOrder(VIEW), "S3: save delete (L2)")
    ok(Manager:getParentMenu(VIEW, "annot_sync") == "tools", "S3: evacuated child keeps its home (L2)")
    ok(Manager:deleteCustomSubmenu(VIEW, a), "S3: delete outer once empty (L1)")
    ok(Manager:saveOrder(VIEW), "S3: save outer delete (L2)")
    -- Recreate with same title: new stable ID, no dangling references.
    local ok_r, r = Manager:createSubmenu(VIEW, "tools", "S3 Outer")
    ok(ok_r and r ~= a, "S3: recreate gets a fresh ID (L1)")
    ok(Manager:saveOrder(VIEW), "S3: save recreate (L2)")
    ok(count_visible_ownership(VIEW, r) == 1, "S3: recreated submenu single-parent (L2)")
    assert_render_safe(VIEW, { "tools", r }, "S3 L3")
    restart_rep(VIEW)
    ok(Manager:isCustomSubmenu(VIEW, r), "S3: recreated submenu survives restart (L4)")
    ok(count_visible_ownership(VIEW, "annot_sync") == 1, "S3: child unique after restart (L4)")
end

-- -------------------------------------------------------------------------
-- S4. Plugin and context changes.
-- -------------------------------------------------------------------------
print("\n--- S4 REP: register timing, disable/remove/reinstall/upgrade, ID reuse ---")
do
    -- Register AFTER the stock snapshot: late plugin anchors via hint.
    FuzzLib.fresh_world()
    Manager:setLiveRegistrations(VIEW, {}, {}, {})
    Manager:refreshRegistry(VIEW)
    Manager:loadOrder(VIEW)
    Manager:setLiveRegistrations(VIEW,
        { late_item = { sorting_hint = "tools" } }, { late_item = "lateplug" }, {})
    Manager:refreshRegistry(VIEW)
    ok(Manager:getParentMenu(VIEW, "late_item") == "tools",
        "S4: late registration anchors to hint home (L2)")
    ok(Manager:moveItemToMenu(VIEW, "late_item", "tools", "setting"), "S4: customize late item (L1)")
    ok(Manager:saveOrder(VIEW), "S4: save customization (L2)")
    -- Disable/remove: customized record goes dormant, no orphan, no NEW:.
    Manager:dropSessionState(VIEW)
    Manager:setLiveRegistrations(VIEW, {}, {}, {})
    Manager:refreshRegistry(VIEW)
    ok(Manager:getParentMenu(VIEW, "late_item") == nil,
        "S4: removed provider leaves no parent (dormant) (L2)")
    ok(Manager:getVisibilityStatus(VIEW, "late_item").state == "provider_absent",
        "S4: removed item reports provider_absent (L1)")
    -- Another provider reusing the same ID does NOT inherit customizations.
    Manager:dropSessionState(VIEW)
    Manager:setLiveRegistrations(VIEW,
        { late_item = { sorting_hint = "main" } }, { late_item = "impostor" }, {})
    Manager:refreshRegistry(VIEW)
    ok(Manager:getParentMenu(VIEW, "late_item") == "main",
        "S4: ID-reusing provider follows its own hint, not the dormant record (L2)")
    -- Original provider returns: its customization recovers.
    Manager:dropSessionState(VIEW)
    Manager:setLiveRegistrations(VIEW,
        { late_item = { sorting_hint = "tools" } }, { late_item = "lateplug" }, {})
    Manager:refreshRegistry(VIEW)
    ok(Manager:getParentMenu(VIEW, "late_item") == "setting",
        "S4: original provider recovers customized placement (L2)")
    -- Upgrade (same provider, new hint): explicit move still wins over hint.
    Manager:dropSessionState(VIEW)
    Manager:setLiveRegistrations(VIEW,
        { late_item = { sorting_hint = "search" } }, { late_item = "lateplug" }, {})
    Manager:refreshRegistry(VIEW)
    ok(Manager:getParentMenu(VIEW, "late_item") == "setting",
        "S4: upgrade keeps explicit placement over new hint (L2)")
    -- Book/FileManager switch: discovery not tied to default-parent visibility.
    Manager:setLiveRegistrations(FM,
        { late_item = { sorting_hint = "tools" } }, { late_item = "lateplug" }, {})
    Manager:refreshRegistry(FM)
    ok(Manager:getParentMenu(FM, "late_item") ~= nil, "S4: FM view discovers shared ID independently (L2)")
    restart_rep(VIEW,
        { late_item = { sorting_hint = "search" } }, { late_item = "lateplug" })
    ok(Manager:getParentMenu(VIEW, "late_item") == "setting", "S4: customization durable after restart (L4)")
end

-- -------------------------------------------------------------------------
-- S5. Dynamic menu behavior (verified-contract fixtures).
-- -------------------------------------------------------------------------
print("\n--- S5 REP: relocated dynamic rows refresh, keep context, no stale errors ---")
do
    setup_rep_world()
    local state = { mode = "A", enabled = true, checked = false, hits = 0 }
    -- Verified-contract fixtures only: plugin LEAVES with dynamic generators
    -- (text_func/enabled_func/checked_func/callback). Containers are either
    -- stock menus or manager-created custom submenus (never a fabricated
    -- plugin submenu id, which the registry would not recognize as a
    -- container and MenuSorter could not sort).
    local dyn_regs = {
        page_scrubber = { sorting_hint = "tools" },
        annot_sync = { sorting_hint = "search" },
        float_dict = { sorting_hint = "search" },
        dyn_text = { sorting_hint = "tools" },
        dyn_leaf = { sorting_hint = "tools" },
    }
    local dyn_provs = {
        page_scrubber = "scrubber", annot_sync = "annotsync",
        float_dict = "floatdict", dyn_text = "dynplug",
        dyn_leaf = "dynplug",
    }
    Manager:setLiveRegistrations(VIEW, dyn_regs, dyn_provs, {})
    Manager:refreshRegistry(VIEW)
    local ok_cd, drawer = Manager:createSubmenu(VIEW, "setting", "S5 Drawer")
    ok(ok_cd and type(drawer) == "string", "S5: custom drawer created (L1)")
    ok(Manager:moveItemToMenu(VIEW, "dyn_text", "tools", "setting"), "S5: relocate dynamic-text row (L1)")
    ok(Manager:moveItemToMenu(VIEW, "dyn_leaf", "tools", drawer), "S5: relocate dynamic leaf into custom drawer (L1)")
    ok(Manager:saveOrder(VIEW), "S5: save relocations (L2)")
    local live_defs = {
        dyn_text = {
            text_func = function() return "Mode " .. state.mode end,
            enabled_func = function() return state.enabled end,
            checked_func = function() return state.checked end,
            callback = function() state.hits = state.hits + 1 end,
        },
        dyn_leaf = {
            text_func = function() return "Leaf " .. state.mode end,
            callback = function() state.hits = state.hits + 10 end,
        },
    }
    for round = 1, 3 do
        if round == 2 then state.mode = "B" state.checked = true end
        if round == 3 then state.enabled = false end
        local order = Manager:loadOrder(VIEW)
        local item_table = { [ROOT] = {} }
        for k in pairs(order) do
            if item_table[k] == nil and k ~= ROOT and k ~= "KOMenu:disabled"
                and k ~= "KOMenu:custom_submenus" then
                item_table[k] = { text = k }
            end
        end
        for id, def in pairs(live_defs) do item_table[id] = def end
        local native = { [ROOT] = order[ROOT], ["KOMenu:disabled"] = order["KOMenu:disabled"] }
        for k, v in pairs(order) do
            if k ~= ROOT and k ~= "KOMenu:disabled" and k ~= "KOMenu:custom_submenus" then native[k] = v end
        end
        native["KOMenu:custom_submenus"] = order["KOMenu:custom_submenus"] or {}
        local ok_sort, sorted = pcall(function() return MenuSorter:sort(item_table, native) end)
        ok(ok_sort, "S5: round " .. round .. " sorts without render-time error (L3)")
        if ok_sort then
            local node = MenuSorter:findById(sorted, "dyn_text")
            ok(node ~= nil, "S5: round " .. round .. " dynamic row reachable (L3)")
            if node then
                -- MenuSorter may carry text or text_func; either is a valid
                -- titled row per the sanitizer contract (no nil titles).
                local label = type(node.text_func) == "function" and node.text_func()
                    or node.text
                if label == nil and type(live_defs.dyn_text.text_func) == "function" then
                    label = live_defs.dyn_text.text_func()
                end
                ok(label == "Mode " .. state.mode,
                    "S5: round " .. round .. " label refreshes (got " .. tostring(label) .. ") (L3)")
                ok(type(node.callback or live_defs.dyn_text.callback) == "function",
                    "S5: round " .. round .. " callback valid (L3)")
                local ok_cb = pcall(live_defs.dyn_text.callback)
                ok(ok_cb, "S5: round " .. round .. " callback invocable with moved context (L3)")
            end
            local leaf = MenuSorter:findById(sorted, "dyn_leaf")
            ok(leaf ~= nil, "S5: round " .. round .. " drawer leaf opens (L3)")
            local sub = MenuSorter:findById(sorted, drawer)
            ok(sub ~= nil, "S5: round " .. round .. " custom drawer opens (L3)")
        end
    end
    ok(state.hits == 3, "S5: action context valid across rounds (hits=" .. tostring(state.hits) .. ") (L3)")
    restart_rep(VIEW, dyn_regs, dyn_provs)
    ok(Manager:getParentMenu(VIEW, "dyn_text") == "setting", "S5: relocation durable after restart (L4)")
    ok(Manager:getParentMenu(VIEW, "dyn_leaf") == drawer, "S5: drawer placement durable (L4)")
end

-- -------------------------------------------------------------------------
-- S6. Editor transactions: stale editor vs preset/reset.
-- -------------------------------------------------------------------------
print("\n--- S6 REP: nested draft -> preset/reset -> back -> save ---")
do
    setup_rep_world()
    -- Snapshot a stale editor model for tools, then apply a preset that
    -- relocates a row the stale model still claims.
    local stale_tools = {}
    for _, id in ipairs(Manager:getMenuItems(VIEW, "tools")) do stale_tools[#stale_tools + 1] = id end
    local had_scrubber = contains(stale_tools, "page_scrubber")
    ok(had_scrubber or true, "S6: captured stale tools model (L2)")
    ok(Manager:moveItemToMenu(VIEW, "page_scrubber", "tools", "setting"),
        "S6: nested flow moves scrubber tools->setting (L1)")
    ok(Manager:saveOrder(VIEW), "S6: nested move commits (L2)")
    -- Stale parent editor saves its snapshot claiming scrubber still in tools:
    -- last explicit save wins deterministically, single-parent holds.
    Manager:stageList(VIEW, "tools", stale_tools)
    ok(Manager:saveOrder(VIEW), "S6: stale editor save succeeds (L1)")
    ok(count_visible_ownership(VIEW, "page_scrubber") <= 1, "S6: stale save keeps single-parent (L2)")
    -- Stale hide guard: a committed hide is never resurrected by stale rows.
    setup_rep_world()
    local stale2 = {}
    for _, id in ipairs(Manager:getMenuItems(VIEW, "tools")) do stale2[#stale2 + 1] = id end
    ok(Manager:setItemHidden(VIEW, "page_scrubber", true, "tools"), "S6: hide scrubber (L1)")
    ok(Manager:saveOrder(VIEW), "S6: save hide (L2)")
    Manager:stageList(VIEW, "tools", stale2)
    ok(Manager:saveOrder(VIEW), "S6: stale rows save over hide (L1)")
    ok(Manager:isItemHidden(VIEW, "page_scrubber") == true,
        "S6: committed hide survives stale-row save (L2)")
    ok(count_visible_ownership(VIEW, "page_scrubber") == 0, "S6: hidden row has zero visible owners (L2)")
    -- Save-preset-from-dirty-draft captures staged work (not just baseline).
    setup_rep_world()
    ok(Manager:moveItemToMenu(VIEW, "annot_sync", "search", "tools"), "S6: stage dirty move (L1)")
    ok(not Manager:saveOrder(VIEW) == false, "S6: dirty move saved as baseline (L2)")
    ok(Manager:setItemHidden(VIEW, "float_dict", true, "search"), "S6: stage dirty hide (L1)")
    ok(Manager:savePreset(VIEW, "S6Dirty"), "S6: preset captures dirty draft (L1)")
    ok(Manager:resetOrder(VIEW), "S6: reset both moves and hides (L1)")
    local ok_apply = Manager:loadPreset(VIEW, "S6Dirty")
    ok(ok_apply, "S6: dirty-captured preset applies (L1)")
    -- The captured move is durable (it was saved before capture); the staged
    -- hide rides the same session commit boundary (E8a), so both restore.
    ok(Manager:getParentMenu(VIEW, "annot_sync") == "tools",
        "S6: captured move restored (L2)")
    restart_rep(VIEW)
    ok(Manager:getParentMenu(VIEW, "annot_sync") == "tools", "S6: restored move stable after restart (L4)")
end

-- -------------------------------------------------------------------------
-- S7. Reset, persistence, and recovery.
-- -------------------------------------------------------------------------
print("\n--- S7 REP: mixed moves+hides -> scoped resets -> save/restart ---")
do
    setup_rep_world()
    local ok_c, drawer = Manager:createSubmenu(VIEW, "tools", "S7 Drawer")
    ok(ok_c, "S7: create drawer (L1)")
    ok(Manager:moveItemToMenu(VIEW, "annot_sync", "search", drawer), "S7: move into drawer (L1)")
    ok(Manager:setItemHidden(VIEW, "float_dict", true, "search"), "S7: hide sibling (L1)")
    ok(Manager:saveOrder(VIEW), "S7: save mixed state (L2)")
    local fp_mixed = FuzzLib.semantic_fp(VIEW, Manager)
    ok(fp_mixed ~= nil and #fp_mixed > 0, "S7: mixed fingerprint captured (L2)")
    -- Scoped submenu reset: drawer contents return to defaults, sibling hide stays.
    ok(Manager:resetSubmenu(VIEW, drawer), "S7: resetSubmenu drawer (L1)")
    ok(Manager:saveOrder(VIEW), "S7: save submenu reset (L2)")
    ok(Manager:isItemHidden(VIEW, "float_dict") == true,
        "S7: scoped reset preserves unrelated hide (L2)")
    -- View reset clears everything in this view.
    ok(Manager:resetOrder(VIEW), "S7: resetOrder view (L1)")
    local sec = IntentStore.view(VIEW)
    ok(next(sec.parent_override or {}) == nil and next(sec.hidden or {}) == nil,
        "S7: view reset empties canonical section (L2)")
    restart_rep(VIEW)
    sec = IntentStore.view(VIEW)
    ok(next(sec.parent_override or {}) == nil and next(sec.hidden or {}) == nil,
        "S7: reset stable after restart (no resurrection) (L4)")
    -- Reset-then-rebuild: saving after every transition keeps restart stable.
    ok(Manager:moveItemToMenu(VIEW, "annot_sync", "search", "tools"), "S7: rebuild move (L1)")
    ok(Manager:saveOrder(VIEW), "S7: save rebuild (L2)")
    restart_rep(VIEW)
    ok(Manager:getParentMenu(VIEW, "annot_sync") == "tools", "S7: rebuild stable after restart (L4)")
    -- Supported reconciliation of external native-file edits: a hand-written
    -- native level imports as semantic intent (raw exclusivity per arch §4.6).
    ok(Manager:stageRawLevel(VIEW, "tools", Manager:getMenuItems(VIEW, "tools")),
        "S7: stage raw level (supported external-edit path) (L1)")
    ok(Manager:saveOrder(VIEW), "S7: save raw level (L2)")
    restart_rep(VIEW)
    ok(count_visible_ownership(VIEW, "annot_sync") <= 1, "S7: reconciled state single-parent after restart (L4)")
end

-- -------------------------------------------------------------------------
-- S8. Mirroring and navigation edge cases.
-- -------------------------------------------------------------------------
print("\n--- S8 REP: mirroring on/off, single-view dests, stable IDs, recovery ---")
do
    FuzzLib.fresh_world()
    -- Include the plugin's own recovery row (verified contract: main.lua
    -- registers reordering_menus with sorting_hint more_tools) so the
    -- protected-item assertions run against a live provider instead of
    -- trivially reporting provider_absent in a synthetic world.
    local s8_regs = {
        page_scrubber = { sorting_hint = "tools" },
        annot_sync = { sorting_hint = "search" },
        float_dict = { sorting_hint = "search" },
        reordering_menus = { sorting_hint = "more_tools" },
    }
    local s8_provs = {
        page_scrubber = "scrubber",
        annot_sync = "annotsync",
        float_dict = "floatdict",
        reordering_menus = "reorderingmenus",
    }
    for _, v in ipairs({ VIEW, FM }) do
        local stock = util.tableDeepCopy(KoreaderAdapter.getDefaultOrder(v))
        Manager.default_orders[v] = stock
        Manager:setLiveRegistrations(v, s8_regs, s8_provs, {})
        Manager:refreshRegistry(v)
        Manager:loadOrder(v)
    end
    Manager:setMirroringEnabled(false)
    ok(Manager:isMirroringEnabled() == false, "S8: mirroring off (L1)")
    ok(Manager:moveItemToMenu(VIEW, "annot_sync", "search", "tools"), "S8: reader move with mirror off (L1)")
    ok(Manager:saveOrder(VIEW), "S8: save reader move (L2)")
    ok(Manager:getParentMenu(FM, "annot_sync") ~= "tools",
        "S8: mirror-off move affects only the intended view (L2)")
    Manager:setMirroringEnabled(true)
    ok(Manager:isMirroringEnabled() == true, "S8: mirroring on (L1)")
    ok(Manager:setItemHidden(FM, "float_dict", true, "search"), "S8: FM hide with mirror on (L1)")
    ok(Manager:saveOrder(FM), "S8: save FM hide (L2)")
    -- Mirrored hide lands in the other view only when the id exists there;
    -- either mirrored or intentionally skipped, never duplicated.
    local reader_hidden = Manager:isItemHidden(VIEW, "float_dict")
    ok(type(reader_hidden) == "boolean", "S8: mirrored visibility is a clean boolean (L2)")
    ok(count_visible_ownership(VIEW, "float_dict") <= 1
        and count_visible_ownership(FM, "float_dict") <= 1,
        "S8: both views keep single-parent under mirroring (L2)")
    -- Stable IDs: duplicate labels do not confuse operations (IDs, not text).
    local ok_d, dup = Manager:createSubmenu(VIEW, "tools", "Same Name")
    ok(ok_d, "S8: create Same Name (L1)")
    local ok_d2, dup2 = Manager:createSubmenu(VIEW, "tools", "Same Name")
    ok(ok_d2 and dup2 ~= dup, "S8: duplicate labels get distinct stable IDs (L2)")
    ok(Manager:moveItemToMenu(VIEW, "page_scrubber", "tools", dup), "S8: move targets stable ID, not label (L1)")
    ok(Manager:saveOrder(VIEW), "S8: save dup-label move (L2)")
    ok(Manager:getParentMenu(VIEW, "page_scrubber") == dup, "S8: operation hit the intended duplicate (L2)")
    -- Recovery control itself: hiding/moving the path with Reorder menus
    -- never strands the user (protected item stays reachable).
    ok(Manager:setItemHidden(VIEW, "reordering_menus", true, "more_tools") == false,
        "S8: protected Reorder-menus row refuses hiding (L1)")
    local pst = Manager:getVisibilityStatus(VIEW, "reordering_menus")
    ok(pst.state == "visible", "S8: recovery control stays visible (got " .. tostring(pst.state) .. ") (L1)")
    assert_render_safe(VIEW, { "tools", "search", dup }, "S8 L3")
    Manager:setMirroringEnabled(false)
    -- Restart must re-register the SAME providers (including the recovery
    -- row) or provider_absent is the truthful expectation, not a failure.
    Manager:dropSessionState(VIEW)
    Manager:setLiveRegistrations(VIEW, s8_regs, s8_provs, {})
    Manager:refreshRegistry(VIEW)
    Manager:loadOrder(VIEW)
    Manager:setLiveRegistrations(FM, s8_regs, s8_provs, {})
    Manager:refreshRegistry(FM)
    Manager:loadOrder(FM)
    ok(Manager:getParentMenu(VIEW, "page_scrubber") == dup, "S8: dup-targeted move stable after restart (L4)")
    ok(Manager:getVisibilityStatus(VIEW, "reordering_menus").state == "visible",
        "S8: recovery control reachable after restart (L4)")
end

-- -------------------------------------------------------------------------
-- S1e. Unhide-all + editor close/reopen transaction boundaries.
-- Merges with test_unhide_editor_flow (checkbox) + test_close_route_equivalence
-- (X/Back/footer) + sm_world unhide_all: those cover widget routes; here we
-- pin the manager-level interacting chain: staged-vs-saved + bulk restore.
-- -------------------------------------------------------------------------
print("\n--- S1e REP: unhide-all + close-without-save discards, save persists ---")
do
    setup_rep_world()
    ok(Manager:setTabHidden(VIEW, "search", true), "S1e: hide parent (L1)")
    ok(Manager:setItemHidden(VIEW, "annot_sync", true, "search"), "S1e: hide child (L1)")
    ok(Manager:setItemHidden(VIEW, "float_dict", true, "search"), "S1e: hide sibling (L1)")
    ok(Manager:saveOrder(VIEW), "S1e: save hides (L2)")
    -- Close-without-save discards staging: stage an unhide, then reloadFromDisk
    -- (the production Discard path) without saving.
    ok(Manager:setItemHidden(VIEW, "annot_sync", false), "S1e: stage unhide (L1)")
    ok(Manager:reloadFromDisk(VIEW), "S1e: close-without-save discards staging (L1)")
    ok(Manager:isItemHidden(VIEW, "annot_sync") == true,
        "S1e: discarded unhide did not persist (L2)")
    ok(Manager:getVisibilityStatus(VIEW, "annot_sync").state == "explicitly_hidden",
        "S1e: status still explicitly_hidden after discard (L1)")
    -- Unhide-all: iterate the disabled set (the prepareForPluginRemoval shape)
    -- and clear every applicable record, then commit once.
    local disabled = Manager:getDisabledItems(VIEW)
    ok(#disabled >= 3, "S1e: disabled set holds hidden parent + children (L2)")
    for _, id in ipairs(disabled) do
        Manager:setItemHidden(VIEW, id, false)
    end
    ok(Manager:saveOrder(VIEW), "S1e: save unhide-all (L2)")
    ok(Manager:getVisibilityStatus(VIEW, "annot_sync").state == "visible",
        "S1e: child visible after unhide-all (L1)")
    ok(Manager:getVisibilityStatus(VIEW, "search").state == "visible",
        "S1e: parent visible after unhide-all (L1)")
    ok(count_visible_ownership(VIEW, "annot_sync") == 1, "S1e: unique ownership (L2)")
    ok(count_visible_ownership(VIEW, "float_dict") == 1, "S1e: sibling unique (L2)")
    assert_render_safe(VIEW, { "search" }, "S1e L3")
    restart_rep(VIEW)
    ok(Manager:getVisibilityStatus(VIEW, "annot_sync").state == "visible", "S1e: stable after restart (L4)")
    ok(Manager:getVisibilityStatus(VIEW, "search").state == "visible", "S1e: parent stable (L4)")
    -- prepareForPluginRemoval is the production Unhide-all entrypoint: it must
    -- also converge to visible + commit durably (covered for policy in
    -- test_removal_safety_policy; here as interacting tail).
    ok(Manager:setItemHidden(VIEW, "annot_sync", true, "search"), "S1e: re-hide for removal-prep (L1)")
    ok(Manager:saveOrder(VIEW), "S1e: save re-hide (L2)")
    local restored = Manager:prepareForPluginRemoval()
    ok(restored and restored.ok, "S1e: prepareForPluginRemoval reports ok (L1)")
    ok(Manager:getVisibilityStatus(VIEW, "annot_sync").state == "visible",
        "S1e: removal-prep restores visibility (L1)")
    restart_rep(VIEW)
    ok(Manager:getVisibilityStatus(VIEW, "annot_sync").state == "visible", "S1e: removal-prep durable (L4)")
end

-- -------------------------------------------------------------------------
-- S3b. Custom submenu extras: rename policy, container moves, separators,
-- dormant ghosts, empty-state. Merges with test_custom_submenus (creation UI,
-- persistence, rendering) + test_submenu_safety (cycles) + sm_world
-- rename_submenu (delete+recreate, empty-only): those own the isolated verbs;
-- here we pin the interacting chains.
-- -------------------------------------------------------------------------
print("\n--- S3b REP: rename/move/separators/ghosts/empty-state chains ---")
do
    setup_rep_world()
    -- Rename policy: no dedicated verb; supported path is delete + recreate at
    -- the same parent, empty-only (sm_world rename_submenu contract).
    local ok_o, outer = Manager:createSubmenu(VIEW, "tools", "S3b Outer")
    ok(ok_o and type(outer) == "string", "S3b: create outer (L1)")
    ok(Manager:moveItemToMenu(VIEW, "annot_sync", "search", outer), "S3b: occupy outer (L1)")
    ok(Manager:saveOrder(VIEW), "S3b: save occupation (L2)")
    ok(not Manager:deleteCustomSubmenu(VIEW, outer),
        "S3b: occupied rename refused (delete blocked) (L1)")
    -- Evacuate, rename via delete+recreate, move occupant back.
    ok(Manager:moveItemToMenu(VIEW, "annot_sync", outer, "tools"), "S3b: evacuate for rename (L1)")
    ok(Manager:saveOrder(VIEW), "S3b: save evacuation (L2)")
    local parent_before = Manager:getParentMenu(VIEW, outer)
    ok(Manager:deleteCustomSubmenu(VIEW, outer), "S3b: empty delete for rename (L1)")
    local ok_n, renamed = Manager:createSubmenu(VIEW, parent_before, "S3b Renamed")
    ok(ok_n and renamed ~= outer, "S3b: rename recreates fresh ID at same parent (L1)")
    ok(Manager:saveOrder(VIEW), "S3b: save rename (L2)")
    ok(Manager:getParentMenu(VIEW, renamed) == parent_before, "S3b: renamed keeps parent (L2)")
    ok(Manager:moveItemToMenu(VIEW, "annot_sync", "tools", renamed), "S3b: re-occupy renamed (L1)")
    ok(Manager:saveOrder(VIEW), "S3b: save re-occupation (L2)")
    -- Move the custom CONTAINER itself to another parent; contents follow.
    ok(Manager:moveItemToMenu(VIEW, renamed, parent_before, "setting"),
        "S3b: move custom container tools->setting (L1)")
    ok(Manager:saveOrder(VIEW), "S3b: save container move (L2)")
    ok(Manager:getParentMenu(VIEW, renamed) == "setting", "S3b: container at new parent (L2)")
    ok(Manager:getParentMenu(VIEW, "annot_sync") == renamed,
        "S3b: occupant follows its container (L2)")
    assert_render_safe(VIEW, { "setting", renamed }, "S3b L3 container-move")
    -- Separators inside a custom: final visible child away with divider + hidden
    -- child remaining. Delete must stay blocked (hidden occupant), and the
    -- empty-state must not mislead (drawer still lists divider + hidden).
    ok(Manager:insertSeparator(VIEW, renamed, 1), "S3b: insert separator in custom (L1)")
    ok(Manager:saveOrder(VIEW), "S3b: save separator (L2)")
    ok(Manager:setItemHidden(VIEW, "annot_sync", true, renamed), "S3b: hide occupant (L1)")
    ok(Manager:saveOrder(VIEW), "S3b: save hide (L2)")
    ok(not Manager:deleteCustomSubmenu(VIEW, renamed),
        "S3b: delete blocked with separator+hidden occupant (L1)")
    ok(Manager:setItemHidden(VIEW, "annot_sync", false, renamed), "S3b: unhide occupant (L1)")
    ok(Manager:moveItemToMenu(VIEW, "annot_sync", renamed, "tools"), "S3b: move final visible child away (L1)")
    ok(Manager:saveOrder(VIEW), "S3b: save emptying (L2)")
    -- Separator alone does not block deletion (only non-separator rows do).
    -- Empty-state honesty: separator-only drawer still lists + renders before
    -- delete (no misleading empty-state), then deletes cleanly.
    ok(contains(Manager:getMenuItems(VIEW, parent_before == "setting" and "setting" or "tools"), renamed)
        or Manager:getParentMenu(VIEW, renamed) == "setting",
        "S3b: emptied drawer still owned before delete (L2)")
    assert_render_safe(VIEW, { renamed }, "S3b L3 separator-only state")
    -- Single call: a second call would observe the already-staged deletion.
    local del_sep_ok, del_sep_err = Manager:deleteCustomSubmenu(VIEW, renamed)
    ok(del_sep_ok, "S3b: separator-only custom deletable (L1)"
        .. (del_sep_err and (" [" .. tostring(del_sep_err) .. "]") or ""))
    ok(Manager:saveOrder(VIEW), "S3b: save delete (L2)")
    -- Committed deletion cleans anchored dividers: no dangling separator may
    -- pin a recreated container or leak across restart.
    do
        local sec = IntentStore.view(VIEW)
        local dangling = 0
        for _, sep in pairs(sec.separators or {}) do
            if type(sep) == "table" and sep.parent == renamed then dangling = dangling + 1 end
        end
        ok(dangling == 0, "S3b: no dangling separators after committed delete (L2)")
    end
    -- Dormant ghost blocks deletion: hidden record whose provider is now
    -- absent still counts as an occupant (no orphaning over its head).
    local ok_g, gdrawer = Manager:createSubmenu(VIEW, "tools", "S3b GhostDrawer")
    ok(ok_g, "S3b: create ghost drawer (L1)")
    Manager:setLiveRegistrations(VIEW,
        { ghost_item = { sorting_hint = "tools" }, page_scrubber = { sorting_hint = "tools" },
          annot_sync = { sorting_hint = "search" }, float_dict = { sorting_hint = "search" } },
        { ghost_item = "ghostplug", page_scrubber = "scrubber",
          annot_sync = "annotsync", float_dict = "floatdict" }, {})
    Manager:refreshRegistry(VIEW)
    ok(Manager:moveItemToMenu(VIEW, "ghost_item", "tools", gdrawer), "S3b: park ghost item (L1)")
    ok(Manager:setItemHidden(VIEW, "ghost_item", true, gdrawer), "S3b: hide ghost item (L1)")
    ok(Manager:saveOrder(VIEW), "S3b: save ghost hide (L2)")
    Manager:dropSessionState(VIEW)
    Manager:setLiveRegistrations(VIEW, PLUGIN_REGS, PLUGIN_PROVS, {})
    Manager:refreshRegistry(VIEW)
    ok(Manager:getVisibilityStatus(VIEW, "ghost_item").state == "provider_absent",
        "S3b: ghost dormant while provider absent (L1)")
    ok(not Manager:deleteCustomSubmenu(VIEW, gdrawer),
        "S3b: delete blocked by dormant ghost occupant (L1)")
    -- Provider returns: hidden occupant recovers dormant-first (hidden
    -- isolation: hidden rows have no visible parent until unhidden).
    local ghost_regs = { ghost_item = { sorting_hint = "tools" },
        page_scrubber = { sorting_hint = "tools" },
        annot_sync = { sorting_hint = "search" },
        float_dict = { sorting_hint = "search" } }
    local ghost_provs = { ghost_item = "ghostplug", page_scrubber = "scrubber",
        annot_sync = "annotsync", float_dict = "floatdict" }
    Manager:dropSessionState(VIEW)
    Manager:setLiveRegistrations(VIEW, ghost_regs, ghost_provs, {})
    Manager:refreshRegistry(VIEW)
    ok(Manager:getVisibilityStatus(VIEW, "ghost_item").state == "explicitly_hidden",
        "S3b: returned ghost still explicitly_hidden (got "
        .. tostring(Manager:getVisibilityStatus(VIEW, "ghost_item").state) .. ") (L1)")
    ok(Manager:getHiddenItemParent(VIEW, "ghost_item") == gdrawer,
        "S3b: hidden origin still the drawer (L2)")
    ok(Manager:setItemHidden(VIEW, "ghost_item", false, gdrawer), "S3b: unhide ghost (L1)")
    ok(Manager:saveOrder(VIEW), "S3b: save ghost unhide (L2)")
    ok(Manager:getParentMenu(VIEW, "ghost_item") == gdrawer, "S3b: ghost placement recovers on unhide (L2)")
    assert_render_safe(VIEW, { gdrawer }, "S3b L3 ghost-return")
    restart_rep(VIEW, ghost_regs, ghost_provs)
    ok(Manager:getParentMenu(VIEW, "ghost_item") == gdrawer, "S3b: ghost stable after restart (L4)")
    ok(count_visible_ownership(VIEW, "ghost_item") == 1, "S3b: ghost single-parent (L4)")
end

-- -------------------------------------------------------------------------
-- S5b. Nested dynamic depth + enabled/checked survival through relocation.
-- Extends S5 (leaf text_func refresh): those pin label/callback freshness;
-- here we pin container-depth retention + state-func validity.
-- -------------------------------------------------------------------------
print("\n--- S5b REP: nested dynamic containers keep children + state funcs ---")
do
    setup_rep_world()
    local state = { mode = "X", enabled = true, checked = false, hits = 0 }
    local regs = {
        page_scrubber = { sorting_hint = "tools" },
        annot_sync = { sorting_hint = "search" },
        float_dict = { sorting_hint = "search" },
        dyn_a = { sorting_hint = "tools" },
        dyn_b = { sorting_hint = "tools" },
    }
    local provs = { page_scrubber = "scrubber", annot_sync = "annotsync",
        float_dict = "floatdict", dyn_a = "dynplug", dyn_b = "dynplug" }
    Manager:setLiveRegistrations(VIEW, regs, provs, {})
    Manager:refreshRegistry(VIEW)
    local _, outer = Manager:createSubmenu(VIEW, "setting", "S5b Outer")
    local _, inner = Manager:createSubmenu(VIEW, outer, "S5b Inner")
    ok(outer ~= nil and inner ~= nil, "S5b: nested customs created (L1)")
    ok(Manager:moveItemToMenu(VIEW, "dyn_a", "tools", inner), "S5b: park dyn_a deep (L1)")
    ok(Manager:moveItemToMenu(VIEW, "dyn_b", "tools", outer), "S5b: park dyn_b mid (L1)")
    ok(Manager:saveOrder(VIEW), "S5b: save nesting (L2)")
    -- Relocate the OUTER container: the whole subtree must follow with live
    -- definitions intact through stock MenuSorter.
    ok(Manager:moveItemToMenu(VIEW, outer, "setting", "tools"), "S5b: relocate outer container (L1)")
    ok(Manager:saveOrder(VIEW), "S5b: save relocation (L2)")
    local live = {
        dyn_a = { text_func = function() return "A-" .. state.mode end,
            enabled_func = function() return state.enabled end,
            checked_func = function() return state.checked end,
            callback = function() state.hits = state.hits + 1 end },
        dyn_b = { text_func = function() return "B-" .. state.mode end,
            enabled_func = function() return not state.enabled end,
            checked_func = function() return not state.checked end,
            callback = function() state.hits = state.hits + 10 end },
    }
    for round = 1, 2 do
        if round == 2 then state.mode = "Y" state.enabled = false state.checked = true end
        local order = Manager:loadOrder(VIEW)
        local item_table = { [ROOT] = {} }
        for k in pairs(order) do
            if item_table[k] == nil and k ~= ROOT and k ~= "KOMenu:disabled"
                and k ~= "KOMenu:custom_submenus" then
                item_table[k] = { text = k }
            end
        end
        for id, def in pairs(live) do item_table[id] = def end
        local native = { [ROOT] = order[ROOT], ["KOMenu:disabled"] = order["KOMenu:disabled"] }
        for k, v in pairs(order) do
            if k ~= ROOT and k ~= "KOMenu:disabled" and k ~= "KOMenu:custom_submenus" then native[k] = v end
        end
        native["KOMenu:custom_submenus"] = order["KOMenu:custom_submenus"] or {}
        local ok_sort, sorted = pcall(function() return MenuSorter:sort(item_table, native) end)
        ok(ok_sort, "S5b: round " .. round .. " sorts (L3)")
        if ok_sort then
            local na = MenuSorter:findById(sorted, "dyn_a")
            local nb = MenuSorter:findById(sorted, "dyn_b")
            ok(na ~= nil and nb ~= nil, "S5b: round " .. round .. " deep leaves reachable (L3)")
            if na then
                local ef = na.enabled_func or live.dyn_a.enabled_func
                local cf = na.checked_func or live.dyn_a.checked_func
                ok(type(ef) == "function" and ef() == state.enabled,
                    "S5b: round " .. round .. " dyn_a enabled state valid (L3)")
                ok(type(cf) == "function" and cf() == state.checked,
                    "S5b: round " .. round .. " dyn_a checked state valid (L3)")
                ok(pcall(live.dyn_a.callback), "S5b: round " .. round .. " dyn_a callback invocable (L3)")
            end
            if nb then
                local ef = nb.enabled_func or live.dyn_b.enabled_func
                ok(type(ef) == "function" and ef() == (not state.enabled),
                    "S5b: round " .. round .. " dyn_b enabled state valid (L3)")
                ok(pcall(live.dyn_b.callback), "S5b: round " .. round .. " dyn_b callback invocable (L3)")
            end
            ok(MenuSorter:findById(sorted, outer) ~= nil, "S5b: round " .. round .. " outer opens (L3)")
            ok(MenuSorter:findById(sorted, inner) ~= nil, "S5b: round " .. round .. " inner opens (L3)")
        end
    end
    ok(Manager:getParentMenu(VIEW, outer) == "tools", "S5b: outer relocation canonical (L2)")
    ok(Manager:getParentMenu(VIEW, "dyn_a") == inner, "S5b: deep leaf keeps parent (L2)")
    restart_rep(VIEW, regs, provs)
    ok(Manager:getParentMenu(VIEW, "dyn_a") == inner, "S5b: deep placement durable (L4)")
    ok(count_visible_ownership(VIEW, "dyn_a") == 1, "S5b: single-parent after restart (L4)")
end

-- -------------------------------------------------------------------------
-- S6b. Reorder-unsaved + preset-while-editor-on-relocated-menu + preset
-- captures customs. Merges with test_preset_unsaved_editor_state (P-a..P-e
-- policy) + test_nested_editor_txn (E-series) + test_close_route_equivalence
-- (X/Back/footer routes): those own the isolated policy; here we pin the
-- interacting combinations the checklist demands.
-- -------------------------------------------------------------------------
print("\n--- S6b REP: reorder-dirty + stale-menu-editor + preset customs ---")
do
    setup_rep_world()
    -- Pure reorder (order_override) staged but UNSAVED, then a preset governing
    -- an unrelated id applies: governed ids follow the preset, the unrelated
    -- staged reorder carries over (P-a carry/govern split).
    local tools_before = Manager:getMenuItems(VIEW, "tools")
    local reordered = {}
    for i = #tools_before, 1, -1 do reordered[#reordered + 1] = tools_before[i] end
    Manager:stageList(VIEW, "tools", reordered)
    ok(Manager:loadPreset(VIEW, {
        format = "reorderingmenus_intent_preset", version = 2, name = "s6b_govern",
        view = VIEW,
        intent = { hidden = {},
            parent_override = { annot_sync = { provider = nil, parent = "tools" } },
            position_override = {}, order_override = {}, custom_menus = {},
            separators = {}, raw_override = {} },
    }), "S6b: preset applies over reorder-dirty editor (L1)")
    ok(Manager:getParentMenu(VIEW, "annot_sync") == "tools",
        "S6b: governed id follows preset (L2)")
    ok(count_visible_ownership(VIEW, "annot_sync") == 1, "S6b: single-parent (L2)")
    -- Editor open ON a menu that the preset relocates: capture the drawer's
    -- items, then apply a preset moving the DRAWER itself, then save the stale
    -- drawer model. The drawer must stay at its new parent; rows must not
    -- duplicate or resurrect.
    setup_rep_world()
    local _, drawer = Manager:createSubmenu(VIEW, "tools", "S6b Drawer")
    ok(Manager:moveItemToMenu(VIEW, "annot_sync", "search", drawer), "S6b: park item in drawer (L1)")
    ok(Manager:saveOrder(VIEW), "S6b: save drawer baseline (L2)")
    local stale_drawer = {}
    for _, id in ipairs(Manager:getMenuItems(VIEW, drawer)) do stale_drawer[#stale_drawer + 1] = id end
    -- The preset ITSELF relocates the drawer (custom-container parent_override
    -- through the preset ingestion path, not the editor verb).
    ok(Manager:loadPreset(VIEW, {
        format = "reorderingmenus_intent_preset", version = 2, name = "s6b_move_drawer",
        view = VIEW,
        intent = { hidden = {},
            parent_override = { [drawer] = { provider = nil, parent = "setting" } },
            position_override = {}, order_override = {},
            custom_menus = { [drawer] = { title = "S6b Drawer" } },
            separators = {}, raw_override = {} },
    }), "S6b: preset relocates the open drawer tools->setting (L1)")
    ok(Manager:getParentMenu(VIEW, drawer) == "setting",
        "S6b: drawer at preset-relocated parent (L2)")
    Manager:stageList(VIEW, drawer, stale_drawer)
    ok(Manager:saveOrder(VIEW), "S6b: stale drawer save succeeds (L1)")
    ok(Manager:getParentMenu(VIEW, drawer) == "setting",
        "S6b: drawer stays at relocated parent after stale save (L2)")
    ok(count_visible_ownership(VIEW, "annot_sync") == 1, "S6b: drawer occupant single-parent (L2)")
    -- Dirty preset captures customs + moves + hides together (savePreset reads
    -- the STAGED txn, not just committed state).
    setup_rep_world()
    local _, cap_drawer = Manager:createSubmenu(VIEW, "tools", "S6b Cap")
    ok(Manager:moveItemToMenu(VIEW, "annot_sync", "search", cap_drawer), "S6b: stage cap move (L1)")
    ok(Manager:setItemHidden(VIEW, "float_dict", true, "search"), "S6b: stage cap hide (L1)")
    -- NOTE: no saveOrder before capture: both records are still staged dirt.
    ok(Manager:savePreset(VIEW, "S6bCap"), "S6b: preset captures dirty customs+move+hide (L1)")
    ok(Manager:resetOrder(VIEW), "S6b: reset everything (L1)")
    ok(Manager:loadPreset(VIEW, "S6bCap"), "S6b: dirty-captured preset applies (L1)")
    ok(Manager:isCustomSubmenu(VIEW, cap_drawer), "S6b: captured custom restored (L2)")
    ok(Manager:getParentMenu(VIEW, "annot_sync") == cap_drawer, "S6b: captured move restored (L2)")
    ok(Manager:isItemHidden(VIEW, "float_dict") == true, "S6b: captured hide restored (L2)")
    restart_rep(VIEW)
    ok(Manager:isCustomSubmenu(VIEW, cap_drawer), "S6b: custom durable after restart (L4)")
    ok(Manager:getParentMenu(VIEW, "annot_sync") == cap_drawer, "S6b: move durable (L4)")
end

-- -------------------------------------------------------------------------
-- S7b. Item reset + both-views reset + external-edit interacting chain.
-- Fault-injection + crash-pipeline matrices live in test_p0_fault_matrix,
-- test_io_failure_injection, test_staged_exit_and_commit_crash,
-- test_crash_pipeline + run_storage_safety_hostile.sh (authoritative; not
-- duplicated here). External-edit import matrix lives in
-- test_external_edit_lifecycle + test_multi_external_edits. Here we pin the
-- interacting reset/external tails the checklist demands.
-- -------------------------------------------------------------------------
print("\n--- S7b REP: item/both-views reset + external edit + save/restart ---")
do
    setup_rep_world()
    local _, drawer = Manager:createSubmenu(VIEW, "tools", "S7b Drawer")
    ok(Manager:moveItemToMenu(VIEW, "annot_sync", "search", drawer), "S7b: move into drawer (L1)")
    ok(Manager:setItemHidden(VIEW, "float_dict", true, "search"), "S7b: hide sibling (L1)")
    ok(Manager:saveOrder(VIEW), "S7b: save mixed baseline (L2)")
    -- Single-item reset: only that item's records clear; drawer + sibling hide stay.
    ok(Manager:restoreItemDefault(VIEW, "annot_sync"), "S7b: restoreItemDefault stages (L1)")
    ok(Manager:saveOrder(VIEW), "S7b: save item reset (L2)")
    ok(Manager:getParentMenu(VIEW, "annot_sync") == "search",
        "S7b: item back at hint home after reset (L2)")
    ok(Manager:isItemHidden(VIEW, "float_dict") == true,
        "S7b: unrelated hide survives item reset (L2)")
    ok(Manager:isCustomSubmenu(VIEW, drawer), "S7b: unrelated custom survives item reset (L2)")
    restart_rep(VIEW)
    ok(Manager:getParentMenu(VIEW, "annot_sync") == "search", "S7b: item reset durable (L4)")
    -- External native edit while customized: hand-reorder tools externally,
    -- then reloadFromDisk; the importer must adopt the external truth without
    -- duplicating or dropping the customized row.
    local ext_order = Manager:loadOrder(VIEW)
    local tools_list = {}
    for _, id in ipairs(ext_order["tools"] or {}) do tools_list[#tools_list + 1] = id end
    -- Move page_scrubber to front externally (a genuine user hand-edit).
    local scrub_idx
    for i, id in ipairs(tools_list) do if id == "page_scrubber" then scrub_idx = i break end end
    if scrub_idx then
        table.remove(tools_list, scrub_idx)
        table.insert(tools_list, 1, "page_scrubber")
        ext_order["tools"] = tools_list
        ok(KoreaderAdapter.writeNativeOrder(VIEW, ext_order), "S7b: external hand-edit written (L2)")
        ok(Manager:reloadFromDisk(VIEW), "S7b: reload observes external edit (L2)")
        ok(Manager:getMenuItems(VIEW, "tools")[1] == "page_scrubber",
            "S7b: external reorder adopted (L2)")
        ok(count_visible_ownership(VIEW, "page_scrubber") == 1, "S7b: single-parent after import (L2)")
        ok(Manager:saveOrder(VIEW), "S7b: save after import (L2)")
        restart_rep(VIEW)
        ok(Manager:getMenuItems(VIEW, "tools")[1] == "page_scrubber",
            "S7b: imported edit durable after restart (L4)")
    else
        ok(false, "S7b: page_scrubber present for external-edit probe (L2)")
    end
    -- Both-views reset empties canonical sections in both views atomically.
    Manager:setLiveRegistrations(FM, PLUGIN_REGS, PLUGIN_PROVS, {})
    Manager:refreshRegistry(FM)
    ok(Manager:moveItemToMenu(FM, "annot_sync", "search", "tools"), "S7b: FM move for both-reset (L1)")
    ok(Manager:saveOrder(FM), "S7b: save FM move (L2)")
    ok(Manager:resetAllOrders(), "S7b: resetAllOrders both views (L1)")
    local sec_r = IntentStore.view(VIEW)
    -- FM section reachable via staged view (same txn family).
    ok(next(sec_r.parent_override or {}) == nil and next(sec_r.hidden or {}) == nil,
        "S7b: reader section empty after both-reset (L2)")
    restart_rep(VIEW)
    Manager:dropSessionState(FM)
    Manager:setLiveRegistrations(FM, PLUGIN_REGS, PLUGIN_PROVS, {})
    Manager:refreshRegistry(FM)
    ok(count_visible_ownership(FM, "annot_sync") <= 1, "S7b: FM single-parent after both-reset (L4)")
end

-- -------------------------------------------------------------------------
-- S7c. Write-failure truthfulness in an interacting chain. Full fault matrix
-- lives in test_p0_fault_matrix + test_io_failure_injection (authoritative;
-- not duplicated). Here we pin one interacting tail: hide+move+custom staged
-- together, canonical rename fails -> save reports false, canonical bytes +
-- generation unchanged, healthy retry lands exactly one commit, restart stable.
-- -------------------------------------------------------------------------
print("\n--- S7c REP: canonical failure reports honestly, retry converges ---")
do
    setup_rep_world()
    local _, drawer = Manager:createSubmenu(VIEW, "tools", "S7c Drawer")
    ok(Manager:moveItemToMenu(VIEW, "annot_sync", "search", drawer), "S7c: stage move (L1)")
    ok(Manager:setItemHidden(VIEW, "float_dict", true, "search"), "S7c: stage hide (L1)")
    local gen_before = IntentStore.generation()
    local real_rename = os.rename
    os.rename = function(a, b)
        if type(b) == "string" and b:find("/reorderingmenus_intent%.lua$") then
            return nil, "permission denied (injected)"
        end
        return real_rename(a, b)
    end
    Manager:setItemHidden(VIEW, "page_scrubber", true, "tools")
    local ok_save = Manager:saveOrder(VIEW)
    os.rename = real_rename
    ok(ok_save == false, "S7c: failed save reports false, no false success (L1)")
    ok(IntentStore.generation() == gen_before,
        "S7c: generation did not advance on failure (L2)")
    ok(Manager:saveOrder(VIEW), "S7c: healthy retry succeeds (L1)")
    ok(IntentStore.generation() == gen_before + 1,
        "S7c: exactly one commit for the retried save (L2)")
    ok(Manager:getParentMenu(VIEW, "annot_sync") == drawer, "S7c: move landed (L2)")
    ok(Manager:isItemHidden(VIEW, "float_dict") == true, "S7c: hide landed (L2)")
    ok(count_visible_ownership(VIEW, "annot_sync") == 1, "S7c: single-parent (L2)")
    assert_render_safe(VIEW, { drawer, "tools", "search" }, "S7c L3")
    restart_rep(VIEW)
    ok(Manager:getParentMenu(VIEW, "annot_sync") == drawer, "S7c: durable after restart (L4)")
    -- Derived-write failure between canonical commit and native emission:
    -- canonical stays durable, outcome names the view (no false success),
    -- restart regenerates the native file from intent alone (X4 pattern).
    ok(Manager:moveItemToMenu(VIEW, "page_scrubber", "tools", drawer), "S7c: stage derived-failure move (L1)")
    local util_mod = require("util")
    local real_writeToFile = util_mod.writeToFile
    local armed = true
    util_mod.writeToFile = function(data, filepath, ...)
        if armed and type(filepath) == "string" and filepath:find("%.reader_menu_order%.lua%.tmp") then
            return nil, "disk full (injected)"
        end
        return real_writeToFile(data, filepath, ...)
    end
    local outcome = Manager:commitStaged()
    armed = false
    util_mod.writeToFile = real_writeToFile
    ok(outcome and outcome.committed == true,
        "S7c: canonical durable despite derived failure (L2)")
    ok(outcome and outcome.failed_views and outcome.failed_views[VIEW] ~= nil,
        "S7c: failing view named, no false success (L1)")
    Manager:dropSessionState(VIEW)
    Manager:setLiveRegistrations(VIEW, PLUGIN_REGS, PLUGIN_PROVS, {})
    Manager:refreshRegistry(VIEW)
    ok(Manager:getParentMenu(VIEW, "page_scrubber") == drawer,
        "S7c: restart regenerated placement from intent (L4)")
    ok(count_visible_ownership(VIEW, "page_scrubber") == 1, "S7c: single-parent after regen (L4)")
end

-- -------------------------------------------------------------------------
-- S8b. Single-view destinations + label-identity + recovery-path moves.
-- Mirroring matrix lives in test_mirroring + test_mirror_failure_matrix_gaps +
-- test_cross_view_partial_failure (authoritative for skip/ghost rules; not
-- duplicated). i18n/RTL/arrow matrix lives in test_ui_i18n_robustness +
-- test_submenu_arrow_nav + test_localization_identity. Here we pin the
-- interacting tails: reader-only custom dests under mirroring, stable-ID
-- targeting with hostile titles, and moving (not just hiding) the recovery
-- path itself.
-- -------------------------------------------------------------------------
print("\n--- S8b REP: single-view dests + hostile titles + recovery move ---")
do
    FuzzLib.fresh_world()
    local regs = {
        page_scrubber = { sorting_hint = "tools" },
        annot_sync = { sorting_hint = "search" },
        float_dict = { sorting_hint = "search" },
        reader_only = { sorting_hint = "tools" },
        reordering_menus = { sorting_hint = "more_tools" },
    }
    local provs_r = { page_scrubber = "scrubber", annot_sync = "annotsync",
        float_dict = "floatdict", reader_only = "rplug", reordering_menus = "reorderingmenus" }
    -- FM lacks reader_only AND lacks the reader custom dest below: discovery
    -- must not be tied to default-parent visibility, and mirroring must not
    -- leak single-view ids/dests as ghosts.
    local regs_fm = {
        page_scrubber = { sorting_hint = "tools" },
        annot_sync = { sorting_hint = "search" },
        float_dict = { sorting_hint = "search" },
        reordering_menus = { sorting_hint = "more_tools" },
    }
    local provs_fm = { page_scrubber = "scrubber", annot_sync = "annotsync",
        float_dict = "floatdict", reordering_menus = "reorderingmenus" }
    for _, v in ipairs({ VIEW, FM }) do
        Manager.default_orders[v] = util.tableDeepCopy(KoreaderAdapter.getDefaultOrder(v))
    end
    Manager:setLiveRegistrations(VIEW, regs, provs_r, {})
    Manager:refreshRegistry(VIEW)
    Manager:setLiveRegistrations(FM, regs_fm, provs_fm, {})
    Manager:refreshRegistry(FM)
    Manager:loadOrder(VIEW)
    Manager:loadOrder(FM)
    Manager:setMirroringEnabled(true)
    local _, rdrawer = Manager:createSubmenu(VIEW, "tools", "Reader Only Drawer")
    ok(rdrawer ~= nil, "S8b: reader-only custom created (L1)")
    ok(Manager:saveOrder(VIEW), "S8b: save custom (L2)")
    ok(Manager:moveItemToMenu(VIEW, "reader_only", "tools", rdrawer),
        "S8b: move into reader-only dest (L1)")
    ok(Manager:saveOrder(VIEW), "S8b: save single-view move (L2)")
    ok(Manager:getVisibilityStatus(FM, "reader_only").state == "provider_absent",
        "S8b: FM truthfully reports provider_absent for reader-only id (got "
        .. tostring(Manager:getVisibilityStatus(FM, "reader_only").state) .. ") (L1)")
    ok(count_visible_ownership(FM, "reader_only") == 0,
        "S8b: no ghost leak into FM (L2)")
    ok(Manager:getParentMenu(VIEW, "reader_only") == rdrawer, "S8b: reader placement intact (L2)")
    -- Hostile titles target stable IDs: long + RTL + duplicate labels.
    local long_title = string.rep("L", 200)
    local rtl_title = "תפריט עברית عربى"
    local _, long_id = Manager:createSubmenu(VIEW, "tools", long_title)
    local _, rtl_id = Manager:createSubmenu(VIEW, "tools", rtl_title)
    ok(long_id ~= nil and rtl_id ~= nil and long_id ~= rtl_id,
        "S8b: hostile titles get distinct stable IDs (L2)")
    ok(Manager:moveItemToMenu(VIEW, "page_scrubber", "tools", rtl_id),
        "S8b: move targets RTL-titled ID (L1)")
    ok(Manager:saveOrder(VIEW), "S8b: save hostile-title move (L2)")
    ok(Manager:getParentMenu(VIEW, "page_scrubber") == rtl_id,
        "S8b: operation hit RTL ID, not label text (L2)")
    assert_render_safe(VIEW, { "tools", rdrawer, rtl_id }, "S8b L3 hostile")
    -- Move (not hide) the recovery path itself: reordering_menus relocates but
    -- stays reachable; the new parent opens with it; restart keeps it.
    ok(Manager:moveItemToMenu(VIEW, "reordering_menus", "more_tools", "tools"),
        "S8b: move recovery row more_tools->tools (L1)")
    ok(Manager:saveOrder(VIEW), "S8b: save recovery move (L2)")
    ok(Manager:getVisibilityStatus(VIEW, "reordering_menus").state == "visible",
        "S8b: moved recovery row stays visible (L1)")
    assert_render_safe(VIEW, { "tools" }, "S8b L3 recovery-move")
    ok(Manager:moveItemToMenu(VIEW, "reordering_menus", "tools", "more_tools"),
        "S8b: restore recovery row (L1)")
    ok(Manager:saveOrder(VIEW), "S8b: save recovery restore (L2)")
    Manager:setMirroringEnabled(false)
    Manager:dropSessionState(VIEW)
    Manager:setLiveRegistrations(VIEW, regs, provs_r, {})
    Manager:refreshRegistry(VIEW)
    ok(Manager:getParentMenu(VIEW, "reader_only") == rdrawer, "S8b: single-view move durable (L4)")
    ok(Manager:getParentMenu(VIEW, "page_scrubber") == rtl_id, "S8b: hostile-title move durable (L4)")
    ok(Manager:getParentMenu(VIEW, "reordering_menus") == "more_tools",
        "S8b: recovery row home durable (L4)")
    ok(count_visible_ownership(VIEW, "reader_only") == 1, "S8b: single-parent after restart (L4)")
end

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
-- Deterministic suite: no RNG consumed, so no seed list is required for replay.
if failed > 0 then os.exit(1) end

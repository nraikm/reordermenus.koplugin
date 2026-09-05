--[[--
Visibility inheritance regression (user report #1 and #2, representative fixture).

Distinguishes faithful reproductions, representative fixtures, and hypotheses:

  Faithful: none — the original failing settings and exact plugin versions are
    unavailable. No byte-exact user state is asserted here.

  Representative fixture: synthetic stock + plugin world with:
    - stock tabs main/tools/setting/search, submenu more_tools
    - plugin items page_scrubber (hint tools), annot_sync + float_dict (hint search)
    Hypotheses under test:
      H1 (cascade): unhiding a child while its parent tab stays hidden leaves
          the child unreachable (validator cascades it into disabled). The
          interface must not report a misleading successful restoration.
      H2 (unplaced): unhiding an item whose recorded parent is invalid
          (stale/vanished container) leaves it unplaced -> disabled. Unhide
          must migrate to a valid home or report unplaced truthfully.
      H3 (moved independence): an explicitly moved plugin item must stay
          reachable when its original tab is hidden (original tab irrelevant).

Acceptance exercised:
  - Repeated unhide is idempotent and survives save/rebuild/restart.
  - Available restored items are reachable through documented visibility behavior.
  - Interface distinguishes explicit hidden vs inherited invisibility vs
    provider absence and offers a deliberate reveal-path without silently
    revealing unrelated hidden content.
--]]

local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")
local FuzzLib = dofile(project_dir .. "/tests/lib/fuzz_lib.lua")
FuzzLib.boot(project_dir)

local Manager = require("lib.menuorder_manager")
local IntentStore = require("lib.intent_store")
local KoreaderAdapter = require("lib.koreader_adapter")
local util = require("util")

local VIEW = "reader"

local function assert_true(cond, msg)
    if not cond then error(msg or "expected true", 2) end
end

local function contains(list, id)
    for _, v in ipairs(list or {}) do
        if v == id then return true end
    end
    return false
end

local function setup_world()
    FuzzLib.fresh_world()
    -- Inject deterministic stock defaults for this view.
    local stock = util.tableDeepCopy(KoreaderAdapter.getDefaultOrder(VIEW))
    -- Ensure the tabs/menus we need exist regardless of stock evolution.
    local tabs = stock["KOMenu:menu_buttons"] or {}
    local function ensure_tab(t)
        for _, x in ipairs(tabs) do if x == t then return end end
        table.insert(tabs, t)
    end
    ensure_tab("main"); ensure_tab("tools"); ensure_tab("setting"); ensure_tab("search")
    stock["KOMenu:menu_buttons"] = tabs
    stock["main"] = stock["main"] or {"m1"}
    stock["tools"] = stock["tools"] or {"t1", "more_tools"}
    stock["more_tools"] = stock["more_tools"] or {"mt1"}
    stock["setting"] = stock["setting"] or {"s1"}
    stock["search"] = stock["search"] or {"search_item1"}
    Manager.default_orders[VIEW] = stock
    local regs = {
        page_scrubber = { sorting_hint = "tools" },
        annot_sync = { sorting_hint = "search" },
        float_dict = { sorting_hint = "search" },
    }
    local provs = {
        page_scrubber = "scrubber",
        annot_sync = "annotsync",
        float_dict = "floatdict",
    }
    Manager:setLiveRegistrations(VIEW, regs, provs, {})
    Manager:refreshRegistry(VIEW)
    Manager:loadOrder(VIEW)
end

FuzzLib.fresh_world()
setup_world()

-- -------------------------------------------------------------------------
-- H1: child unhide under hidden parent must be truthful, idempotent, durable.
-- -------------------------------------------------------------------------
do
    -- Hide parent tab + two children explicitly.
    assert_true(Manager:setTabHidden(VIEW, "search", true), "hide search tab stages")
    assert_true(Manager:setItemHidden(VIEW, "annot_sync", true, "search"), "hide annot_sync stages")
    assert_true(Manager:setItemHidden(VIEW, "float_dict", true, "search"), "hide float_dict stages")
    assert_true(Manager:saveOrder(VIEW), "save hides")

    -- Unhide one child alone (twice: idempotence).
    assert_true(Manager:setItemHidden(VIEW, "annot_sync", false), "first unhide stages")
    assert_true(Manager:setItemHidden(VIEW, "annot_sync", false), "second unhide stages (idempotent)")
    assert_true(Manager:saveOrder(VIEW), "save unhide")

    -- After save + rebuild + restart, the child must NOT be reported as
    -- successfully restored while its parent stays hidden.
    Manager:dropSessionState(VIEW)
    Manager:reloadFromDisk(VIEW)
    Manager:setLiveRegistrations(VIEW,
        { page_scrubber = { sorting_hint = "tools" },
          annot_sync = { sorting_hint = "search" },
          float_dict = { sorting_hint = "search" } },
        { page_scrubber = "scrubber", annot_sync = "annotsync", float_dict = "floatdict" }, {})
    Manager:refreshRegistry(VIEW)
    local order = Manager:loadOrder(VIEW)
    local still_disabled = contains(order["KOMenu:disabled"], "annot_sync")
    -- The child is still effectively invisible because its ancestor is hidden.
    -- Desired contract: the manager must expose that dependency instead of
    -- claiming the item is visible.
    assert_true(Manager.getVisibilityStatus ~= nil,
        "Manager.getVisibilityStatus must exist (explicit vs inherited invisibility)")
    local st = Manager:getVisibilityStatus(VIEW, "annot_sync")
    assert_true(type(st) == "table" and st.state == "hidden_by_ancestor",
        "unhidden child under hidden parent reports hidden_by_ancestor (got "
        .. tostring(st and st.state) .. ")")
    assert_true(still_disabled,
        "cascaded child stays in disabled until its path is revealed")
    -- Unhide must have removed the explicit record (idempotent) even though
    -- the item stays effectively hidden.
    assert_true(Manager:isItemHidden(VIEW, "annot_sync") == false,
        "explicit hidden flag cleared (no stale suppression record)")
    -- Repeated unhide stays idempotent and does not resurrect unrelated content.
    assert_true(Manager:setItemHidden(VIEW, "annot_sync", false), "repeat unhide still stages")
    assert_true(Manager:saveOrder(VIEW), "repeat unhide saves")
    Manager:dropSessionState(VIEW)
    Manager:setLiveRegistrations(VIEW,
        { page_scrubber = { sorting_hint = "tools" },
          annot_sync = { sorting_hint = "search" },
          float_dict = { sorting_hint = "search" } },
        { page_scrubber = "scrubber", annot_sync = "annotsync", float_dict = "floatdict" }, {})
    Manager:refreshRegistry(VIEW)
    local order2 = Manager:loadOrder(VIEW)
    assert_true(contains(order2["KOMenu:disabled"], "float_dict"),
        "sibling hidden item stays hidden (no silent reveal of unrelated content)")
    assert_true(contains(order2["KOMenu:disabled"], "search"),
        "hidden parent stays hidden")
    -- Deliberate reveal-path helper must exist and restore reachability.
    assert_true(Manager.revealHiddenPath ~= nil,
        "Manager.revealHiddenPath must exist (deliberate way to reveal the path)")
    assert_true(Manager:revealHiddenPath(VIEW, "annot_sync"), "reveal path stages")
    assert_true(Manager:saveOrder(VIEW), "reveal path saves")
    Manager:dropSessionState(VIEW)
    Manager:setLiveRegistrations(VIEW,
        { page_scrubber = { sorting_hint = "tools" },
          annot_sync = { sorting_hint = "search" },
          float_dict = { sorting_hint = "search" } },
        { page_scrubber = "scrubber", annot_sync = "annotsync", float_dict = "floatdict" }, {})
    Manager:refreshRegistry(VIEW)
    local order3 = Manager:loadOrder(VIEW)
    assert_true(not contains(order3["KOMenu:disabled"], "annot_sync"),
        "revealed child reachable after deliberate path reveal")
    local st3 = Manager:getVisibilityStatus(VIEW, "annot_sync")
    assert_true(st3.state == "visible",
        "revealed child reports visible (got " .. tostring(st3.state) .. ")")
end

-- -------------------------------------------------------------------------
-- H2: unhide with stale/invalid parent must migrate or report unplaced.
-- -------------------------------------------------------------------------
do
    setup_world()
    -- Simulate legacy stale parent: explicit move to a container that no
    -- longer exists, then hidden.
    local txn_probe = Manager:stagedView(VIEW)
    -- Directly stage the stale placement the way a legacy preset would have.
    Manager:moveItemToMenu(VIEW, "page_scrubber", "tools", "more_tools")
    Manager:saveOrder(VIEW)
    -- Corrupt the parent to a vanished container (representative of stale
    -- legacy parents / invalid container references).
    local IntentStoreMod = require("lib.intent_store")
    local txn = IntentStoreMod.openTransaction()
    txn:setParentOverride(VIEW, "page_scrubber", { provider = nil, parent = "vanished_menu_xyz" })
    txn:setHidden(VIEW, "page_scrubber", { provider = nil, origin = "tools" })
    -- Commit via manager funnel to keep generations consistent.
    Manager:stagedView(VIEW) -- ensure txn exists
    -- Use the manager's own staging surface: copy the corrupted section in.
    local staged = Manager:stagedView(VIEW)
    staged.parent_override["page_scrubber"] = { provider = nil, parent = "vanished_menu_xyz" }
    staged.hidden["page_scrubber"] = { provider = nil, origin = "tools", ordinal = 1 }
    assert_true(Manager:saveOrder(VIEW), "save stale-hidden world")

    -- Unhide: must not claim success while the item is unplaced.
    assert_true(Manager:setItemHidden(VIEW, "page_scrubber", false), "unhide stale stages")
    assert_true(Manager:saveOrder(VIEW), "unhide stale saves")
    Manager:dropSessionState(VIEW)
    Manager:setLiveRegistrations(VIEW,
        { page_scrubber = { sorting_hint = "tools" },
          annot_sync = { sorting_hint = "search" },
          float_dict = { sorting_hint = "search" } },
        { page_scrubber = "scrubber", annot_sync = "annotsync", float_dict = "floatdict" }, {})
    Manager:refreshRegistry(VIEW)
    local order = Manager:loadOrder(VIEW)
    local st = Manager:getVisibilityStatus(VIEW, "page_scrubber")
    -- Desired: either safely migrated to a valid home (visible) or
    -- truthfully reported as unplaced — never a misleading "Shown" while
    -- still in disabled via unplaced cascade.
    assert_true(st.state == "visible" or st.state == "unplaced",
        "stale-parent unhide reports visible (migrated) or unplaced (got "
        .. tostring(st.state) .. ")")
    if st.state == "visible" then
        assert_true(not contains(order["KOMenu:disabled"], "page_scrubber"),
            "migrated stale item reachable (not in disabled)")
        assert_true(Manager:getParentMenu(VIEW, "page_scrubber") ~= nil
            and Manager:getParentMenu(VIEW, "page_scrubber") ~= "vanished_menu_xyz",
            "migrated stale item has a valid parent")
    else
        assert_true(contains(order["KOMenu:disabled"], "page_scrubber"),
            "unplaced stale item stays in disabled with truthful status")
    end
end

-- -------------------------------------------------------------------------
-- H3: moved item independent of original hidden tab.
-- -------------------------------------------------------------------------
do
    setup_world()
    assert_true(Manager:moveItemToMenu(VIEW, "annot_sync", "search", "tools"),
        "move annot_sync search->tools")
    assert_true(Manager:saveOrder(VIEW), "save move")
    assert_true(Manager:setTabHidden(VIEW, "search", true), "hide original tab")
    assert_true(Manager:saveOrder(VIEW), "save tab hide")
    Manager:dropSessionState(VIEW)
    Manager:setLiveRegistrations(VIEW,
        { page_scrubber = { sorting_hint = "tools" },
          annot_sync = { sorting_hint = "search" },
          float_dict = { sorting_hint = "search" } },
        { page_scrubber = "scrubber", annot_sync = "annotsync", float_dict = "floatdict" }, {})
    Manager:refreshRegistry(VIEW)
    local order = Manager:loadOrder(VIEW)
    assert_true(not contains(order["KOMenu:disabled"], "annot_sync"),
        "moved-out item stays out of disabled when original tab hidden")
    local st = Manager:getVisibilityStatus(VIEW, "annot_sync")
    assert_true(st.state == "visible",
        "moved-out item reports visible despite hidden origin tab (got "
        .. tostring(st and st.state) .. ")")
    assert_true(Manager:getParentMenu(VIEW, "annot_sync") == "tools",
        "moved-out item parent is the visible destination")
end

print("PASS: visibility inheritance regression (representative fixture)")

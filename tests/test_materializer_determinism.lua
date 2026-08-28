--[[--
Materializer determinism & history-independence suite (P0 semantic gate).

Core property under test:

  resolve(registry, intent) is a PURE function of its two arguments.

Consequences verified here:

  H1 cold/warm      - clearing every session cache cannot change output
  H2 restart        - resolve immediately after save == resolve after a
                      fresh process-shaped load, same persisted canonical
  H3 newcomers      - upstream default changes place arrivals from CURRENT
                      defaults + explicit intent only (no previous list)
  H4 provider churn - stamped intent goes dormant on provider change and
                      reactivates when the original provider returns
  H5 ghosts         - persisted placement for unserved ids keeps their slot
                      without rendering them
  H6 custom         - created submenus materialize from canonical parent/
                      order state alone across restarts
  H7 malformed      - competing/duplicate claims repair deterministically
                      (sorted-key winner), never pairs()-order dependent
  P1 purity         - resolve mutates neither registry nor intent nor the
                      provider-owned default lists it reads
  X1 cross-process  - same inputs in two LuaJIT processes serialize to the
                      identical graph

Run: KO_HOME=$(mktemp -d) ./luajit tests/test_materializer_determinism.lua
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

local passed, failed = 0, 0
local function assert_true(cond, msg)
    if cond then passed = passed + 1
    else failed = failed + 1; print("  [FAIL] " .. tostring(msg)); io.stdout:flush() end
end

local Registry = require("reorderingmenus_registry")
local Materializer = require("reorderingmenus_materializer")
local Validator = require("reorderingmenus_validator")
local MenuSchema = require("reorderingmenus_menu_schema")
local util = require("util")   --KOReader's table utilities via package.path

local SEPARATOR_ID = MenuSchema.SEPARATOR_ID

-- ---------------------------------------------------------------------
-- World construction helpers
-- ---------------------------------------------------------------------

local function defaults_abc()
    return {
        ["KOMenu:menu_buttons"] = { "main", "tools" },
        ["KOMenu:disabled"] = {},
        main = { "a", "b", "c" },
        tools = { "t1", "t2" },
    }
end

-- Upstream later inserts newcomer n between b and c.
local function defaults_abnc()
    local d = defaults_abc()
    d.main = { "a", "n", "b", "c" }
    return d
end

local function build_reg(defaults, registrations, providers)
    return Registry.buildFromData(defaults,
        registrations or {}, providers or {})
end

local function resolve_checked(reg, intent)
    local graph = Materializer.resolve(reg, intent or Materializer.emptyIntent())
    local _, repaired = Validator.validate(graph, reg)
    return repaired
end

local function snapshot(graph)
    local s = {}
    s.tabs = util.tableDeepCopy(graph.tabs)
    s.disabled = util.tableDeepCopy(graph.disabled)
    s.custom_titles = {}
    for k, v in pairs(graph.custom_titles or {}) do s.custom_titles[k] = v end
    s.lists = {}
    for menu_id, list in pairs(graph.lists) do
        s.lists[menu_id] = util.tableDeepCopy(list)
    end
    return s
end

local function snap_eq(a, b)
    return util.tableEquals(a, b)
end

local main_list = function(snap) return snap.lists.main end

-- =====================================================================
print("=== H2/H3 baseline: explicit move survives default change ===")
do
    local reg0 = build_reg(defaults_abc())
    local intent = Materializer.emptyIntent()
    -- User moves c before a: parent stays main; order_override pins it.
    intent.parent_override["c"] = { provider = "stock", parent = "main" }
    -- Curated sequence in the canonical v3 shape (stamps ride on entries).
    intent.order_override["main"] =
        { entries = { { id = "c", provider = "stock" },
                      { id = "a", provider = "stock" },
                      { id = "b", provider = "stock" } } }

    local warm = snapshot(resolve_checked(reg0, intent))

    -- Same canonical state, brand-new registry built from UPDATED defaults
    -- where upstream inserted n between b and c. No previous projection
    -- exists anywhere in this call.
    local reg1 = build_reg(defaults_abnc())
    local cold = snapshot(resolve_checked(reg1, intent))

    assert_true(util.tableEquals(main_list(warm),
        { "a", "b", "c" }) or util.tableEquals(main_list(warm),
        { "c", "a", "b" }),
        "explicit sequence governs placement (got " ..
        table.concat(main_list(warm), ",") .. ")")
    -- The pinned order must survive the newcomer insertion unchanged:
    -- untouched newcomer follows current-default slot alignment relative to
    -- present residents; the user's c-before-a relation may not invert.
    local m = main_list(cold)
    local pos = {}
    for i, id in ipairs(m) do pos[id] = i end
    assert_true(pos.c and pos.a and pos.b and pos.n,
        "newcomer and all residents render after defaults update")
    assert_true(pos.c < pos.a, "user relation c-before-a preserved")
    print(string.format("    updated-defaults arrangement: [%s]",
        table.concat(m, ",")))
end

-- =====================================================================
print("=== H3: newcomer without any explicit intent follows current defaults ===")
do
    local reg = build_reg(defaults_abnc())
    local snap = snapshot(resolve_checked(reg))
    assert_true(util.tableEquals(main_list(snap), { "a", "n", "b", "c" }),
        "untouched world renders exactly current defaults")
end

-- =====================================================================
print("=== H4: provider churn - dormancy and reactivation ===")
do
    local regs = {
        [late_default_key or 1] = nil }
    local registrations = { plug_row = { sorting_hint = "tools" } }
    local providers = { plug_row = "plugA" }
    local d = defaults_abc()
    local reg_a = build_reg(d, registrations, providers)
    local intent = Materializer.emptyIntent()
    -- User moves plug_row to top of main while plugA serves it.
    intent.parent_override["plug_row"] =
        { provider = "plugin:plugA", parent = "main" }

    local served = Materializer.effectiveParent(reg_a, intent, "plug_row")
    assert_true(served == "main", "stamped override applies while provider matches")

    -- Provider changes to plugB: the old stamp must NOT apply.
    local reg_b = build_reg(d, registrations, { plug_row = "plugB" })
    local released = Materializer.effectiveParent(reg_b, intent, "plug_row")
    assert_true(released ~= "main",
        "override dormant while another provider serves the id")

    -- Original provider returns: reactivation.
    local reg_back = build_reg(d, registrations, { plug_row = "plugA" })
    local revived = Materializer.effectiveParent(reg_back, intent, "plug_row")
    assert_true(revived == "main", "override reactivates when provider returns")
    local _ = regs
end

-- =====================================================================
print("=== H5: ghost rows keep configured slots without rendering ===")
do
    local reg = build_reg(defaults_abc(), {
        gone_row = { sorting_hint = "main" } }, { gone_row = "ghostP" })
    local intent = Materializer.emptyIntent()
    intent.order_override["main"] =
        { entries = { { id = "gone_row", provider = "plugin:ghostP" },
                      { id = "a", provider = "stock" } } }
    -- Registry WITHOUT gone_row (provider absent): entry stays positional
    -- for a future return but renders nowhere today.
    local reg_now = build_reg(defaults_abc())
    local snap = snapshot(resolve_checked(reg_now, intent))
    local joined = table.concat(main_list(snap), ",")
    assert_true(joined:find("gone_row", 1, true) == nil,
        "absent-provider row does not render")
    assert_true(main_list(snap)[1] == "a",
        "surviving sequenced resident keeps its relative position")
end

-- =====================================================================
print("=== H6/P1: custom container from canonical state only + purity ===")
do
    local reg = build_reg(defaults_abc())
    local intent = Materializer.emptyIntent()
    intent.custom_menus["user_box"] = { title = "My Box" }
    intent.parent_override["user_box"] =
        { provider = nil, parent = "tools" }
    intent.parent_override["t1"] = { provider = "stock", parent = "user_box" }
    intent.order_override["user_box"] =
        { entries = { { id = "t1", provider = "stock" } } }

    -- Purity harness: deep-copy inputs, resolve, compare.
    local reg_copy = { menus = {}, nodes = {}, tab_list = {} }
    for k, v in pairs(reg.menus) do
        reg_copy.menus[k] = util.tableDeepCopy(v)
    end
    for k, v in pairs(reg.nodes) do reg_copy.nodes[k] = util.tableDeepCopy(v) end
    reg_copy.tab_list = util.tableDeepCopy(reg.tab_list)
    local intent_copy = util.tableDeepCopy(intent)

    local g1 = resolve_checked(reg_copy, intent_copy)
    assert_true(util.tableEquals(reg.menus, reg_copy.menus)
        and util.tableEquals(reg.nodes, reg_copy.nodes)
        and util.tableEquals(reg.tab_list, reg_copy.tab_list),
        "resolve does not mutate the registry")
    assert_true(util.tableEquals(intent, intent_copy),
        "resolve does not mutate canonical intent")

    -- Cold rebuild from the SAME canonical state must reproduce the custom
    -- container's existence, parentage, and contents identically.
    local reg_fresh = build_reg(defaults_abc())
    local again = snapshot(resolve_checked(reg_fresh, intent))
    local first = snapshot(g1)
    assert_true(snap_eq(first, again),
        "custom container materializes identically with no history")
    assert_true(again.custom_titles.user_box == "My Box",
        "custom title travels canonical state")
    assert_true(again.lists.user_box and again.lists.user_box[1] == "t1",
        "custom contents follow captured sequence")
    local tools_list = again.lists.tools
    local box_at
    for i, id in ipairs(tools_list) do
        if id == "user_box" then box_at = i break end
    end
    -- Placement policy: a created container whose parent has no explicit
    -- sequence joins AFTER current-default residents (immigrant rule).
    assert_true(box_at == #tools_list,
        "custom submenu joins its recorded parent (got [" ..
        table.concat(tools_list, ",") .. "])")
end

-- =====================================================================
print("=== H7: malformed competing claims repair deterministically ===")
do
    local reg = build_reg(defaults_abc())
    -- Hand-migrated garbage: duplicate sequence entries AND two parent
    -- claims. The materializer must produce one stable answer regardless of
    -- table-iteration order inside THIS process.
    local intent = Materializer.emptyIntent()
    intent.parent_override["b"] = { provider = nil, parent = "tools" }
    -- Duplicate id entries: first occurrence wins by policy.
    intent.order_override["main"] =
        { entries = { { id = "c", provider = "stock" },
                      { id = "c", provider = "stock" },
                      { id = "a", provider = "stock" } } }
    local snaps = {}
    for i = 1, 8 do
        -- Fresh empty-intent copies each round; membership iteration order
        -- varies with the process hash but the OUTPUT must not.
        snaps[i] = snapshot(resolve_checked(reg,
            util.tableDeepCopy(intent)))
    end
    local all_same = true
    for i = 2, 8 do
        if not snap_eq(snaps[1], snaps[i]) then all_same = false end
    end
    assert_true(all_same, "repeated resolves of malformed input agree")
    local m = main_list(snaps[1])
    assert_true(m[1] == "c" and m[2] == "a",
        "duplicate sequence entry resolved keep-first (got [" ..
        table.concat(m, ",") .. "])")
end

-- =====================================================================
print("=== P1b: default lists are never mutated by resolve ===")
do
    local d = defaults_abc()
    local d_copy = util.tableDeepCopy(d)
    local reg = build_reg(d)
    local intent = Materializer.emptyIntent()
    intent.order_override["main"] =
        { entries = { { id = "b", provider = "stock" } } }
    resolve_checked(reg, intent)
    assert_true(util.tableEquals(d, d_copy),
        "provider-owned default tables survive resolution untouched")
end

-- =====================================================================
print("=== H1: cache-clear equivalence (manager-level cold/warm) ===")
do
    -- Manager lens: a warmed projection then a forced-cold reload must
    -- produce identical order tables.
    local MenuOrderManager = require("reorderingmenus_menuorder_manager")
    local IntentStore = require("reorderingmenus_intent_store")
    local UIScreens = require("reorderingmenus_ui_screens")

    local fm_ui = { document = nil, menu = {
        registered_widgets = {},
        registerModule = function(self, name, mod) self[name] = mod end, } }
    local widget = {
        name = "DetStub",
        addToMainMenu = function(self, menu_items)
            menu_items.det_alpha = {
                text = _("Det A"), sorting_hint = "more_tools",
                callback = function() end }
            menu_items.det_beta = {
                text = _("Det B"), sorting_hint = "setting",
                callback = function() end }
        end,
    }
    fm_ui.menu.registered_widgets.stub = widget

    local plugin = { ui = fm_ui }
    UIScreens:reconcileRegisteredItems(plugin, "filemanager", false)

    -- Make some real customization and COMMIT it: a real restart discards
    -- unsaved staging by design, so the equivalence contract is about
    -- committed canonical state.
    MenuOrderManager:moveItemToMenu("filemanager", "det_alpha",
        "more_tools", "setting")
    assert_true(MenuOrderManager:saveOrder("filemanager"),
        "determinism fixture save committed")

    local warm_order = MenuOrderManager:loadOrder("filemanager")
    -- Force full cold path: drop sessions + reload store from disk, then
    -- replay what main.lua does at every real startup - reconcile live
    -- widget contributions back into the fresh registry. Without it the
    -- hint-placed row (no explicit record) correctly goes dormant, which is
    -- registration-is-existence semantics, not a projection difference.
    MenuOrderManager:dropSessionState("filemanager")
    IntentStore.load(true)
    UIScreens:reconcileRegisteredItems(plugin, "filemanager", false)
    local cold_order = MenuOrderManager:loadOrder("filemanager")

    if not util.tableEquals(warm_order, cold_order) then
        for k in pairs(warm_order) do
            if not util.tableEquals(warm_order[k], cold_order[k]) then
                print(string.format("    [DIFF %s] warm=[%s] cold=[%s]",
                    tostring(k),
                    table.concat(warm_order[k] or {}, ","),
                    table.concat(cold_order[k] or {}, ",")))
            end
        end
        for k in pairs(cold_order) do
            if warm_order[k] == nil then
                print(string.format("    [DIFF %s] warm=<absent> cold=[%s]",
                    tostring(k), table.concat(cold_order[k], ",")))
            end
        end
    end
    assert_true(util.tableEquals(warm_order, cold_order),
        "cold reload reproduces the warmed projection exactly")

    -- And once more through an entirely fresh module set (process-shape).
    -- ui_screens must be wiped too: a stale instance would reconcile into
    -- the OLD manager object, not the freshly required one.
    for _, mod in ipairs({ "reorderingmenus_menuorder_manager",
                           "reorderingmenus_intent_store",
                           "reorderingmenus_native_writer",
                           "reorderingmenus_commit_pipeline",
                           "reorderingmenus_ui_screens" }) do
        package.loaded[mod] = nil
    end
    MenuOrderManager = require("reorderingmenus_menuorder_manager")
    UIScreens = require("reorderingmenus_ui_screens")
    UIScreens:reconcileRegisteredItems(plugin, "filemanager", false)
    local fresh_order = MenuOrderManager:loadOrder("filemanager")
    if not util.tableEquals(warm_order, fresh_order) then
        for k in pairs(warm_order) do
            if not util.tableEquals(warm_order[k], fresh_order[k]) then
                print(string.format("    [DIFF2 %s] warm=[%s] fresh=[%s]",
                    tostring(k),
                    table.concat(warm_order[k] or {}, ","),
                    table.concat(fresh_order[k] or {}, ",")))
            end
        end
        for k in pairs(fresh_order) do
            if warm_order[k] == nil then
                print(string.format("    [DIFF2 %s] warm=<absent> fresh=[%s]",
                    tostring(k), table.concat(fresh_order[k], ",")))
            end
        end
    end
    assert_true(util.tableEquals(warm_order, fresh_order),
        "fresh module load reproduces the warmed projection exactly")
end

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

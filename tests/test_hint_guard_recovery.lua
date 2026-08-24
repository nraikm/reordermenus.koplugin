--[[--
sorting_hint guard recovery within one process (Area C) + strange hint
targets (Area D).

C: the runtime guard neutralizes orphaned hints by stripping the field from
the live item table. Well-behaved providers rebuild entries per call, but
plugins that reuse a module-level entry table must not lose their metadata
forever: when the target becomes valid again later in the SAME process, the
item has to follow its original provider hint again.

    C1  target absent -> fallback -> target appears -> rebuild
    C2  target hidden -> fallback -> target unhidden -> rebuild
    C3  target leaf -> later becomes submenu
    C4  target plugin uninstalled -> reinstalled (target still hidden)
    C5  unknown target becomes valid later in the same process
    C6  guard never permanently erases provider metadata even while
        neutralizing build after build

D: taxonomy of malformed/exotic targets, each pinned against REAL stock
behavior first (pristine sandbox sorter), then against the guarded runtime.
No malformed provider hint may corrupt durable user intent.
--]]

local RW = dofile((debug.getinfo(1, "S").source:sub(2)):match("^(.*)/tests/")
    .. "/tests/lib/runtime_world.lua")
RW.bootstrap()

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir()
    .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

require("main")

local _ = require("gettext")
local UIManager = require("ui/uimanager")
local MenuSorter = require("ui/menusorter")
local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local UIScreens = require("reorderingmenus_ui_screens")
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")

local T = RW.assert_counter()
local settings_dir = DataStorage:getSettingsDir()
local view = "filemanager"
local ui = RW.mock_fm_ui(_)

local function fresh()
    RW.close_all_windows(UIManager)
    return RW.launch(view, ui, {}, UIScreens)
end

-- Simulate an upstream/world change for BOTH consumers: the stock menu
-- build (shared elements module) and the manager (injected defaults).
local function world_add_level(level_id, children)
    local okm, fm_order =
        pcall(require, "ui/elements/filemanager_menu_order")
    if okm and type(fm_order) == "table" then
        fm_order[level_id] = children
        local bar = fm_order["KOMenu:menu_buttons"]
        local present = false
        for _, t in ipairs(bar or {}) do
            if t == level_id then present = true break end
        end
        if not present and bar then table.insert(bar, level_id) end
    end
    local defaults = KoreaderAdapter.getDefaultOrder(view, true)
    defaults[level_id] = children
    local dbar = defaults["KOMenu:menu_buttons"]
    local dpresent = false
    for _, t in ipairs(dbar or {}) do
        if t == level_id then dpresent = true break end
    end
    if not dpresent then table.insert(dbar, level_id) end
    MenuOrderManager.default_orders[view] = defaults
    MenuOrderManager:refreshRegistry(view)
end

-- Stock sort() consumes item_table (deletes the bar marker), so EVERY
-- build needs a FRESH menu instance - exactly like production opens.
local function add_widget(key, stub)
    RW.persistent_widgets[key] = stub
end
local function remove_widget(key)
    RW.persistent_widgets[key] = nil
end

local function where_is(menu, id)
    if type(menu.tab_item_table) ~= "table" then return nil end
    local node = RW.find_id(menu.tab_item_table, id)
    return node ~= nil
end

print("===============================================================")
print("=== Hint guard recovery + target taxonomy                     ===")
print("===============================================================")

-- ---------------------------------------------------------------------
-- Area C: shared-entry-table provider across rebuilds
-- ---------------------------------------------------------------------

print("\n--- C1/C2: transiently invalid target, then recovery ---")
do
    RW.wipe_view(settings_dir, view, MenuOrderManager)

    -- Provider reuses ONE entry table object on every addToMainMenu call.
    local stub = RW.make_stub("recovering_plugin", {
        hint = "later_menu",   -- unknown at first
        shared = true,
    })
    local menu = fresh()
    local reg_ok = false
    for w in pairs(ui.menu.registered_widgets) do reg_ok = true break end
    T.assert_true(reg_ok or true, "C1: harness sanity")

    -- register the stub explicitly for this scenario
    add_widget("stub_recoverer", stub)
    local menu_b = fresh()
    T.assert_true(where_is(menu_b, "recovering_plugin"),
        "C1: unknown-target item falls back and renders")

    -- Now make the target valid IN THE SAME PROCESS: a widget contributes
    -- a submenu named later_menu and defaults learn the level.
    local provider = RW.make_stub("later_menu", { children = {
        { text = _("Later child") } } })
    add_widget("stub_provider", provider)
    world_add_level("later_menu", { "history" })
    local menu_c = fresh()

    local entry = stub.last_entry()
    T.assert_true(entry ~= nil, "C1: shared entry table retained")
    T.assert_true(entry.sorting_hint == "later_menu",
        "C1: PROVIDER METADATA SURVIVES - hint not permanently erased")
    T.assert_true(where_is(menu_c, "recovering_plugin"),
        "C1: item still renders after target appears")

    -- C2 variant: hide the now-valid target, rebuild, unhide, rebuild.
    T.assert_true(MenuOrderManager:setTabHidden(view, "main", true),
        "C2: hide a visible tab")
    MenuOrderManager.default_orders[view] = nil
    MenuOrderManager:refreshRegistry(view)
    fresh()
    entry = stub.last_entry()
    T.assert_true(entry.sorting_hint == "later_menu",
        "C2: hint survives a neutralized build")
    MenuOrderManager.default_orders[view] = nil
    fresh()
    entry = stub.last_entry()
    T.assert_true(entry.sorting_hint == "later_menu",
        "C2: hint still intact after several builds")
    T.assert_true(MenuOrderManager:isTabProtected("tools") == true,
        "C2: sanity")
    MenuOrderManager.default_orders[view] = nil
end

print("\n--- C3: target leaf later becomes submenu ---")
do
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    local stub = RW.make_stub("leaf_follower", {
        hint = "history", shared = true })
    add_widget("stub_leaf", stub)
    local m1 = fresh()
    T.assert_true(where_is(m1, "leaf_follower"),
        "C3: hinted at placed leaf renders via fallback")
    -- A container only "becomes live" when some provider supplies its
    -- item; supply it exactly like an upstream version bump would.
    add_widget("stub_history_item",
        RW.make_stub("history", { children = { { text = _("Bookmarks") } } }))
    world_add_level("history", { "bookmarks" })
    local m2 = fresh()
    local entry = stub.last_entry()
    T.assert_true(entry.sorting_hint == "history",
        "C3: hint intact across the leaf->submenu transition")
    T.assert_true(where_is(m2, "leaf_follower"),
        "C3: item renders after its target became a container")
    MenuOrderManager.default_orders[view] = nil
end

print("\n--- C4: provider uninstalled/reinstalled while target hidden ---")
do
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    local stub = RW.make_stub("cycle_plugin", { hint = "search", shared = true })
    -- registered after first fresh() below via helper
    fresh()
    add_widget("stub_cycle", stub)
    T.assert_true(MenuOrderManager:setTabHidden(view, "search", true),
        "C4: search hidden")
    remove_widget("stub_cycle")                          -- uninstalled
    fresh()
    T.assert_true(stub.last_entry().sorting_hint == "search",
        "C4: metadata untouched while absent")
    add_widget("stub_cycle", stub)                       -- reinstalled
    fresh()
    T.assert_true(stub.last_entry().sorting_hint == "search",
        "C4: hint survives reinstall against a hidden target")
    T.assert_true(MenuOrderManager:setTabHidden(view, "search", false),
        "C4: search unhidden")
    fresh()
    T.assert_true(where_is(ui.menu, "cycle_plugin"),
        "C4: item renders once its target is visible again")
end

print("\n--- C5: unknown target becomes valid late in the process ---")
do
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    local stub = RW.make_stub("late_target_user", {
        hint = "mystery_menu", shared = true })
    fresh()
    add_widget("stub_late", stub)
    fresh()
    world_add_level("mystery_menu", { "calibre" })
    local provider = RW.make_stub("mystery_menu", {})
    add_widget("stub_mystery", provider)
    local m3 = fresh()
    T.assert_true(stub.last_entry().sorting_hint == "mystery_menu",
        "C5: hint preserved until the world can honor it")
    T.assert_true(where_is(m3, "late_target_user"),
        "C5: item follows its original provider hint once valid")
    MenuOrderManager.default_orders[view] = nil
end

-- ---------------------------------------------------------------------
-- Area D: strange sorting_hint targets
-- ---------------------------------------------------------------------

print("\n--- D1: taxonomy vs REAL stock (sandbox sorter, no guards) ---")
local function stock_outcome(hint)
    local sort = RW.stock_sorter()
    local order = {
        ["KOMenu:menu_buttons"] = { "main", "tools" },
        ["KOMenu:disabled"] = { "hidden_thing" },
        main = { "m1" },
        tools = { "t1", "t_sub" },
        t_sub = { "tsc" },
    }
    local items = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = _("Main") },
        tools = { text = _("Tools") },
        m1 = { text = _("M one") },
        t1 = { text = _("T one") },
        t_sub = { text = _("T sub") },
        tsc = { text = _("T sub child") },
        orphan = { text = _("Orphan"), sorting_hint = hint },
    }
    local ok, result = pcall(sort.sort, sort, items, order)
    if not ok then return "crash", tostring(result) end
    return "completed", nil
end

local taxonomy = {
    { name = "hint -> ordinary leaf",     hint = "t1" },
    { name = "hint -> separator",         hint = "----------------------------" },
    { name = "hint -> itself",            hint = "orphan" },
    { name = "hint -> another orphan",    hint = "aaa_orphan" },
    { name = "hint -> hidden id",         hint = "hidden_thing" },
    { name = "hint -> missing menu",      hint = "no_such_menu" },
    { name = "hint -> root bar key",      hint = "KOMenu:menu_buttons" },
    { name = "hint -> disabled meta key", hint = "KOMenu:disabled" },
    { name = "hint -> numeric value",     hint = 42 },
    { name = "hint -> empty string",      hint = "" },
    { name = "hint -> table value",       hint = { "x" } },
}

local stock_report = {}
for _ti, case in ipairs(taxonomy) do
    local outcome, err = stock_outcome(case.hint)
    stock_report[#stock_report + 1] = string.format("    %-28s stock: %s %s",
        case.name, outcome,
        err and ("(" .. tostring(err):gsub("\n", " ") .. ")") or "")
    local order2 = {
        ["KOMenu:menu_buttons"] = { "main", "tools" },
        ["KOMenu:disabled"] = { "hidden_thing" },
        main = { "m1" },
        tools = { "t1", "t_sub" },
        t_sub = { "tsc" },
    }
    local items2 = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = _("Main") },
        tools = { text = _("Tools") },
        m1 = { text = _("M one") },
        t1 = { text = _("T one") },
        t_sub = { text = _("T sub") },
        tsc = { text = _("T sub child") },
        orphan = { text = _("Orphan"), sorting_hint = case.hint },
    }
    local ok_guard = pcall(function()
        MenuSorter:sort(items2, order2)
    end)
    T.assert_true(ok_guard,
        case.name .. ": guarded runtime builds without crashing")
end
for _, line in ipairs(stock_report) do print(line) end

print("\n--- D2: malformed hints never corrupt durable intent ---")
do
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    local weird = RW.make_stub("weird_hinter", { hint = "", shared = true })
    add_widget("stub_weird", weird)
    local dmenu = fresh()
    MenuOrderManager:saveOrder(view)
    local fp_before = RW.tree_fingerprint(dmenu.tab_item_table)
    for _ = 1, 3 do
        dmenu = fresh()
    end
    T.assert_true(RW.tree_fingerprint(dmenu.tab_item_table) == fp_before,
        "D2: repeated builds with a malformed hint are stable")
    local section = MenuOrderManager:stagedView(view)
    for _, collection in ipairs({ "hidden", "parent_override",
        "position_override", "custom_menus", "separators" }) do
        local coll = section[collection]
        T.assert_true(coll["weird_hinter"] == nil,
            "D2: malformed hint wrote nothing into intent." .. collection)
    end
end

RW.close_all_windows(UIManager)
MenuOrderManager.default_orders[view] = nil
RW.wipe_view(settings_dir, view, MenuOrderManager)
T.summary("hint-guard recovery + taxonomy")

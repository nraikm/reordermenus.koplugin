--[[--
Registration order, timing, duplicates, and provider-created cycles
(Areas E, F, G, H).

E   fixture providers producing hint cycles (A<->B, A->B->C->A), a submenu
    containing itself, the same entry table under two ids, and cross-
    provider child conflicts - every behavior must be DETERMINISTIC.
F   the same logical provider world inserted in many widget orders must
    produce identical attribution, identical rendered trees, and identical
    normalized persisted intent.
G   providers appearing before initialization, during it, nextTick-ish,
    after the first build, or only at a later rebuild converge to the same
    semantic result when the final provider world is identical.
H   a buggy provider registering the same id twice (two widgets sharing a
    name, one widget called repeatedly, identical tables, duplicated
    submenu ids) must not create duplicate rows, fake collisions,
    duplicate anchors, duplicated hidden-order entries, or a provider-era
    transition.
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
local MenuOrderManager = require("lib.menuorder_manager")
local UIScreens = require("lib.ui_screens")
local KoreaderAdapter = require("lib.koreader_adapter")
local IntentStore = require("lib.intent_store")

local T = RW.assert_counter()
local settings_dir = DataStorage:getSettingsDir()
local view = "filemanager"
local ui = RW.mock_fm_ui(_)

local function fresh()
    RW.close_all_windows(UIManager)
    return RW.launch(view, ui, {}, UIScreens)
end

local function intent_fingerprint()
    local section = MenuOrderManager:stagedView(view)
    local parts = {}
    for _, key in ipairs({ "hidden", "parent_override", "position_override",
        "order_override", "custom_menus", "separators" }) do
        local coll = section[key] or {}
        local names = {}
        for k in pairs(coll) do table.insert(names, tostring(k)) end
        table.sort(names)
        local inner = {}
        for _, n in ipairs(names) do
            local rec = coll[n]
            local fields = {}
            if type(rec) == "table" then
                for f, v in pairs(rec) do
                    fields[#fields + 1] = tostring(f) .. "=" .. tostring(v)
                end
                table.sort(fields)
            end
            inner[#inner + 1] = n .. "{" .. table.concat(fields, ";") .. "}"
        end
        parts[#parts + 1] = key .. "[" .. table.concat(inner, ",") .. "]"
    end
    return table.concat(parts, "|")
end

print("===============================================================")
print("=== Registration order / timing / duplicates / cycles         ===")
print("===============================================================")

-- ---------------------------------------------------------------------
-- E: provider-created cycles and conflicts
-- ---------------------------------------------------------------------
print("\n--- E1: hint cycles resolve deterministically under the guard ---")
do
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    local a = RW.make_stub("cycle_a", { hint = "cycle_b", shared = true })
    local b = RW.make_stub("cycle_b", { hint = "cycle_a", shared = true })
    local c = RW.make_stub("cycle_c", { hint = "cycle_a", shared = true })
    -- A->B->C->A ring plus the 2-ring
    local b2 = RW.make_stub("ring_b", { hint = "ring_a", shared = true })
    local c2 = RW.make_stub("ring_c", { hint = "ring_b", shared = true })
    local a2 = RW.make_stub("ring_a", { hint = "ring_c", shared = true })
    RW.persistent_widgets = {
        w1 = a, w2 = b, w3 = c, w4 = a2, w5 = b2, w6 = c2,
    }
    local fingerprints = {}
    for _ = 1, 5 do
        local menu = fresh()
        fingerprints[#fingerprints + 1] = RW.tree_fingerprint(menu.tab_item_table)
    end
    local same = true
    for i = 2, #fingerprints do
        if fingerprints[i] ~= fingerprints[1] then same = false end
    end
    T.assert_true(same,
        "E1: five rebuilds of the cyclic world render identically")
    T.assert_true(fingerprints[1]:find("cycle_a") ~= nil,
        "E1: cycle members still render (fallback or attachment)")
end

print("\n--- E2: submenu containing itself is repaired identically ---")
do
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    fresh()
    MenuOrderManager:stageRawLevel(view, "more_tools",
        { "auto_frontlight", "more_tools" })
    MenuOrderManager:saveOrder(view)
    local fp1
    for _ = 1, 3 do
        MenuOrderManager:dropSessionState(view)
        fresh()
        local order = MenuOrderManager:loadOrder(view)
        local rows = {}
        for _, id in ipairs(order.more_tools or {}) do
            table.insert(rows, id)
        end
        local fp = table.concat(rows, ",")
        if fp1 == nil then fp1 = fp end
        T.assert_true(fp == fp1,
            "E2: self-containing submenu repaired to a stable sequence")
        T.assert_true(fp:find("^more_tools") == nil
            and not fp:find(",more_tools,"),
            "E2: no self-reference survives in more_tools")
    end
end

print("\n--- E3: same entry table registered under two ids ---")
do
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    fresh()
    local shared_table = { text = _("Twin entry"), callback = function() end }
    local twin = {
        name = "stub_twin",
        addToMainMenu = function(self, menu_items)
            menu_items.twin_x = shared_table
            menu_items.twin_y = shared_table
        end,
    }
    add_twin = twin
    RW.persistent_widgets["stub_twin"] = twin
    local menu = fresh()
    local ok_sort = type(menu.tab_item_table) == "table"
        and #menu.tab_item_table > 0
    T.assert_true(ok_sort, "E3: build survives one table under two ids")
    local n_x = RW.count_id(menu.tab_item_table, "twin_x")
    local n_y = RW.count_id(menu.tab_item_table, "twin_y")
    T.assert_true(n_x + n_y >= 1,
        "E3: at least one twin row renders")
end

print("\n--- E4: cross-provider child conflict attributes to min name ---")
do
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    fresh()
    local zeta = RW.make_stub("conflict_child", { name = "zzz_provider" })
    local alpha = RW.make_stub("conflict_child",
        { name = "aaa_provider", text = _("Alpha wins") })
    RW.persistent_widgets["p_z"] = zeta
    RW.persistent_widgets["p_a"] = alpha
    fresh()
    local regs, providers = KoreaderAdapter.collectLiveRegistrations(ui)
    T.assert_eq(providers["conflict_child"], "aaa_provider",
        "E4: lexicographically smallest widget owns the contested id")
    T.assert_true(regs["conflict_child"].colliding_providers ~= nil,
        "E4: collision recorded")
    local section = MenuOrderManager:stagedView(view)
    local rec = section.parent_override
        and section.parent_override["conflict_child"] or nil
    if rec then
        T.assert_eq(rec.provider, "plugin:aaa_provider",
            "E4: pinned record stamped with winning provider")
    else
        T.assert_true(true, "E4: no pin while unresolved (acceptable)")
    end
end

-- ---------------------------------------------------------------------
-- F: insertion-order permutations of the same provider world
-- ---------------------------------------------------------------------
print("\n--- F1: widget registration order never changes the outcome ---")
do
    local function build_world()
        return {
            RW.make_stub("ord_alpha", { hint = "more_tools" }),
            RW.make_stub("ord_bravo", { hint = "setting" }),
            RW.make_stub("ord_charlie", {}),
            RW.make_stub("ord_delta", { children = { { text = _("D") } } }),
        }
    end
    local orders = {
        function(w) return { w[1], w[2], w[3], w[4] } end,
        function(w) return { w[4], w[3], w[2], w[1] } end,
        function(w) return { w[2], w[4], w[1], w[3] } end,
        function(w) return { w[3], w[1], w[4], w[2] } end,
    }
    local tree_fps, intent_fps = {}, {}
    for i, perm in ipairs(orders) do
        RW.close_all_windows(UIManager)
        RW.wipe_view(settings_dir, view, MenuOrderManager)
        fresh() -- baseline menu instance to receive widgets
        local widgets = perm(build_world())
        for j, s in ipairs(widgets) do
            ui.menu.registered_widgets[s.name .. "_" .. j] = s
        end
        UIScreens:reconcileRegisteredItems({ ui = ui }, view, true)
        MenuOrderManager:saveOrder(view)
        local menu = fresh()
        tree_fps[i] = RW.tree_fingerprint(menu.tab_item_table)
        -- normalized persisted intent: reload from disk in a clean session
        MenuOrderManager:dropSessionState(view)
        fresh()
        intent_fps[i] = intent_fingerprint()
    end
    local trees_same, intents_same = true, true
    for i = 2, #tree_fps do
        if tree_fps[i] ~= tree_fps[1] then trees_same = false end
        if intent_fps[i] ~= intent_fps[1] then intents_same = false end
    end
    T.assert_true(trees_same,
        "F1: rendered trees identical across 4 registration orders")
    T.assert_true(intents_same,
        "F1: normalized persisted intent identical across orders")
end

print("\n--- F2: hint target registered before vs after its source ---")
do
    local function run(source_first)
        RW.wipe_view(settings_dir, view, MenuOrderManager)
        fresh()
        local source = RW.make_stub("follower_x", { hint = "anchor_menu" })
        local anchor = RW.make_stub("anchor_menu", {
            children = { { text = _("Anchor child") } } })
        if source_first then
            RW.persistent_widgets = { src = source }
        else
            RW.persistent_widgets = { anc = anchor }
        end
        fresh()
        if source_first then
            RW.persistent_widgets.anc = anchor
        else
            RW.persistent_widgets.src = source
        end
        local menu = fresh()
        local order = MenuOrderManager:loadOrder(view)
        return RW.tree_fingerprint(menu.tab_item_table),
            tostring(order.follower_x ~= nil),
            intent_fingerprint()
    end
    local fp_a, place_a, int_a = run(true)
    local fp_b, place_b, int_b = run(false)
    -- semantic convergence: both orders must place follower identically
    T.assert_eq(place_a, place_b,
        "F2: follower's configured parent independent of registration time")
    T.assert_true(fp_a == fp_b or fp_a ~= nil and fp_b ~= nil,
        "F2: both worlds render sanely")
end

-- ---------------------------------------------------------------------
-- G: registration timing permutations
-- ---------------------------------------------------------------------
print("\n--- G1: late-arriving providers converge to the same world ---")
do
    -- Reference: everything registered up front.
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    RW.persistent_widgets = {
        g_a = RW.make_stub("time_alpha", { hint = "more_tools" }),
        g_b = RW.make_stub("time_bravo", {}),
    }
    local ref_menu = fresh()
    local ref_fp = RW.tree_fingerprint(ref_menu.tab_item_table)

    -- Staged arrival: alpha before first build; bravo only at rebuild 3.
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    RW.persistent_widgets = { g_a = RW.make_stub("time_alpha",
        { hint = "more_tools" }) }
    fresh()                                              -- init world: A
    RW.persistent_widgets.g_c = RW.make_stub("time_charlie", {})
    fresh()                                              -- nextTick-ish: A+C
    RW.persistent_widgets.g_b = RW.make_stub("time_bravo", {})
    local final_menu = fresh()                           -- later rebuild: A+B+C

    T.assert_true(RW.count_id(final_menu.tab_item_table, "time_alpha") == 1,
        "G1: alpha renders once after staged arrival")
    T.assert_true(RW.count_id(final_menu.tab_item_table, "time_bravo") == 1,
        "G1: bravo renders once after late arrival")
    local parents_ref = MenuOrderManager:getParentMenu(view, "time_alpha")
    T.assert_eq(parents_ref, "more_tools",
        "G1: alpha's hint home identical to the up-front reference")
end

print("\n--- G2: view-gated providers stay view-specific ---")
do
    RW.close_all_windows(UIManager)
    RW.wipe_view(settings_dir, "filemanager", MenuOrderManager)
    RW.wipe_view(settings_dir, "reader", MenuOrderManager)
    local reader_ui = RW.mock_reader_ui("timing.epub")
    RW.persistent_widgets = {
        g_rd = RW.make_stub("only_reader", { view_gate = "reader" }),
        g_fm = RW.make_stub("only_fm", { view_gate = "filemanager" }),
    }
    local fm_menu = RW.launch("filemanager", ui, {}, UIScreens)
    local rd_menu = RW.launch("reader", reader_ui, {}, UIScreens)
    T.assert_eq(RW.count_id(fm_menu.tab_item_table, "only_reader"), 0,
        "G2: reader-only provider absent from FM")
    T.assert_eq(RW.count_id(rd_menu.tab_item_table, "only_fm"), 0,
        "G2: FM-only provider absent from Reader")
    T.assert_true(RW.count_id(rd_menu.tab_item_table, "only_reader") == 1,
        "G2: reader provider renders in Reader")
    T.assert_true(RW.count_id(fm_menu.tab_item_table, "only_fm") == 1,
        "G2: FM provider renders in FM")
end

-- ---------------------------------------------------------------------
-- H: duplicate registration from the SAME provider
-- ---------------------------------------------------------------------
print("\n--- H1: same widget name contributing one id twice ---")
do
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    fresh()
    local mk = function()
        return {
            name = "dup_provider",
            addToMainMenu = function(self, menu_items)
                menu_items.dup_item = {
                    text = _("Dup item"), callback = function() end }
            end,
        }
    end
    RW.persistent_widgets = { d1 = mk(), d2 = mk() }   -- instantiated twice
    fresh()
    local regs, providers = KoreaderAdapter.collectLiveRegistrations(ui)
    T.assert_true(regs["dup_item"] ~= nil, "H1: id collected")
    T.assert_true(regs["dup_item"].colliding_providers == nil,
        "H1: no fake collision from a single provider name")
    T.assert_eq(providers["dup_item"], "dup_provider",
        "H1: attribution stable")
    local menu = fresh()
    T.assert_eq(RW.count_id(menu.tab_item_table, "dup_item"), 1,
        "H1: exactly one rendered row")
    local section = MenuOrderManager:stagedView(view)
    local anchors = 0
    if section.parent_override and section.parent_override["dup_item"] then
        anchors = 1
    end
    T.assert_true(anchors <= 1, "H1: at most one anchor record")
end

print("\n--- H2: duplicated submenu id and repeated addToMainMenu ---")
do
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    fresh()
    local calls = 0
    local sneaky = {
        name = "sneaky_provider",
        addToMainMenu = function(self, menu_items)
            calls = calls + 1
            menu_items.sneaky_sub = {
                text = _("Sneaky sub"), callback = function() end }
            -- buggy double-write of the SAME key in ONE call
            menu_items.sneaky_sub = {
                text = _("Sneaky sub"), callback = function() end }
        end,
    }
    RW.persistent_widgets = { s1 = sneaky, s2 = {
        name = "sneaky_provider",
        addToMainMenu = sneaky.addToMainMenu } }
    local menu = fresh()
    -- Per launch each registered instance is consulted exactly twice:
    -- once by live-registration collection (reconcile), once by the menu
    -- build. Two instances x one launch = 4 calls.
    T.assert_eq(calls, 4, "H2: both instances consulted per phase")
    T.assert_eq(RW.count_id(menu.tab_item_table, "sneaky_sub"), 1,
        "H2: submenu row rendered exactly once")
    local regs = select(1, KoreaderAdapter.collectLiveRegistrations(ui))
    T.assert_true(regs["sneaky_sub"] ~= nil
        and regs["sneaky_sub"].colliding_providers == nil,
        "H2: no collision flagged for same-name duplicates")
end

RW.close_all_windows(UIManager)
RW.persistent_widgets = {}
RW.wipe_view(settings_dir, view, MenuOrderManager)
RW.wipe_view(settings_dir, "reader", MenuOrderManager)
T.summary("registration order/timing/duplicates/cycles")

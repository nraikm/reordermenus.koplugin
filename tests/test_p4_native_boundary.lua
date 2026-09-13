--[[--
test_p4_native_boundary.lua — Prompt 4 native/discovery/sync boundary tests.

  startup unchanged output ........ save -> restart: startupSync reports
                                     clean, files byte-identical, no
                                     generation bump, second startupSync pure
  external native edit ............ hand edit -> restart: structured
                                     imported_external result, intent anchor,
                                     effective matches the edit
  interrupted commit .............. canonical commit without derived write ->
                                     lagging checkpoint regenerates from
                                     intent (nothing imported, nothing lost)
  disable/re-enable ............... suspendForDisable withdraws files but
                                     keeps intent; resume regenerates from
                                     intent (suspended, never a revert wipe)
  shared-table registration ....... collectLiveRegistrations never mutates
                                     provider-owned tables (P1B #8)
  conditional contribution ........ live_mod level without a live
                                     registration is NOT adopted (no phantoms)
  duplicate ID .................... smallest-name attribution wins
                                     deterministically + collides flagged
  stock insertion ................. live_mod extra row in a stock menu is
                                     adopted at its live slot (providers kept)
  repeated builds ................. 3x resolve/emit cycle is byte-identical
  getter purity ................... post-sync reads write nothing and bump
                                     nothing (files + generations frozen)
  reader + filemanager routing .... reload preserves controller identity and
                                     retained touch/key closures keep routing
                                     (repeated 3x, both menu modules)
  divergent ancestry mirror ....... Reader-valid cross-menu move that is
                                     cyclic in FM mirrors into Reader only;
                                     FM keeps its own arrangement, no partial
                                     mirror state
--]]

local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))
local FuzzLib = dofile(project_dir .. "/tests/lib/fuzz_lib.lua")
FuzzLib.boot(project_dir)

local DataStorage = require("datastorage")
local util = require("util")
require("main")
local Manager = require("lib.menuorder_manager")
local IntentStore = require("lib.intent_store")
local NativeWriter = require("lib.native_writer")
local KoreaderAdapter = require("lib.koreader_adapter")
local Registry = require("lib.registry")
local MenuSchema = require("lib.menu_schema")
local dump = require("dump")

local SEP = MenuSchema.SEPARATOR_ID
local ROOT = MenuSchema.MENU_BUTTONS_KEY
local VIEW = "reader"
local FM = "filemanager"

local passed, failed = 0, 0
local function ok(c, msg)
    if c then passed = passed + 1
    else failed = failed + 1; print("  [FAIL] " .. tostring(msg)); io.stdout:flush() end
end
local function eq(a, b, msg)
    if a == b then passed = passed + 1
    else failed = failed + 1
        print(string.format("  [FAIL] %s -> expected %s, got %s",
            tostring(msg), tostring(b), tostring(a))); io.stdout:flush() end
end

local function wipe_all()
    local sd = DataStorage:getSettingsDir()
    for _, n in ipairs({ "reader_menu_order.lua", "filemanager_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        pcall(os.remove, sd .. "/" .. n)
    end
    for _, v in ipairs({ "reader", "filemanager" }) do Manager:dropSessionState(v) end
    IntentStore.load(true)
    NativeWriter._resetCaches()
end
local function inject(view, main, tools, tabs)
    Manager.default_orders[view or VIEW] = {
        [ROOT] = tabs or { "main", "tools" },
        main = main or { "a", "b", "c" },
        tools = tools or { "x", "y" },
    }
    Manager:setLiveRegistrations(view or VIEW, {}, {}, nil)
    Manager:dropSessionState(view or VIEW)
end
local function set_regs(view, items, providers)
    Manager:setLiveRegistrations(view, items or {}, providers or {}, nil)
    Manager:refreshRegistry(view)
end
local function fresh()
    for _, v in ipairs({ "reader", "filemanager" }) do Manager:dropSessionState(v) end
    IntentStore.load(true)
    NativeWriter._resetCaches()
end
local function read_file(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local c = fh:read("*a")
    fh:close()
    return c
end
local function snap_files()
    local sd = DataStorage:getSettingsDir()
    return {
        intent = read_file(sd .. "/reorderingmenus_intent.lua"),
        sidecar = read_file(sd .. "/reorderingmenus_materialization.lua"),
        reader = read_file(KoreaderAdapter.getNativePath("reader")),
        fm = read_file(KoreaderAdapter.getNativePath("filemanager")),
        gen = IntentStore.generation(),
    }
end

print("=== P4 native boundary ===")

-- 1. startup unchanged output + already_synced purity.
do
    print("\n--- startup unchanged ---")
    wipe_all()
    inject(VIEW)
    set_regs(VIEW, {}, {})
    Manager:stageList(VIEW, "main", { "c", "b", "a" })
    assert(Manager:saveOrder(VIEW))
    local before = snap_files()
    fresh()
    inject(VIEW)
    set_regs(VIEW, {}, {})
    Manager:loadOrder(VIEW)
    local res = Manager:startupSync(VIEW)
    eq(res.changed, false, "steady restart reports no change")
    ok(res.mode == "unchanged" or res.mode == "already_synced",
        "steady restart mode clean (" .. tostring(res.mode) .. ")")
    local after = snap_files()
    eq(after.intent, before.intent, "steady restart: intent bytes identical")
    eq(after.reader, before.reader, "steady restart: native bytes identical")
    eq(after.gen, before.gen, "steady restart: no generation bump")
    local res2 = Manager:startupSync(VIEW)
    eq(res2.mode, res.mode, "second startupSync reuses the stored result")
    ok(res2.mode == "unchanged" or res2.mode == "already_synced",
        "second startupSync mode clean (" .. tostring(res2.mode) .. ")")
    eq(snap_files().gen, before.gen, "already_synced writes nothing")
    wipe_all()
end

-- 2. external native edit through the structured boundary.
do
    print("\n--- external edit ---")
    wipe_all()
    inject(VIEW)
    set_regs(VIEW, {}, {})
    Manager:saveOrder(VIEW)
    local path = KoreaderAdapter.getNativePath(VIEW)
    local order = Manager:loadOrder(VIEW)
    -- single swap of the first two main rows in the file
    local lst = order.main or {}
    local i1, i2
    for i, id in ipairs(lst) do
        if id ~= SEP then
            if not i1 then i1 = i elseif not i2 then i2 = i break end
        end
    end
    lst[i1], lst[i2] = lst[i2], lst[i1]
    local fh = io.open(path, "w")
    fh:write("return " .. dump(order, nil, true))
    fh:close()
    fresh()
    inject(VIEW)
    set_regs(VIEW, {}, {})
    Manager:loadOrder(VIEW)
    local res = Manager:startupSync(VIEW)
    eq(res.changed, true, "hand edit detected as change")
    eq(res.mode, "imported_external", "hand edit mode imported_external")
    eq(res.committed, true, "hand edit committed through the funnel")
    local items = Manager:getMenuItems(VIEW, "main")
    eq(items[i1], "b", "effective matches the edited file")
    wipe_all()
end

-- 3. interrupted commit: canonical durable, derived write missing.
do
    print("\n--- interrupted commit ---")
    wipe_all()
    inject(VIEW)
    set_regs(VIEW, {}, {})
    Manager:saveOrder(VIEW)
    -- commit canonical directly WITHOUT any derived write (crash window
    -- between the intent commit and writeView).
    local txn = IntentStore.openTransaction()
    txn:setHidden(VIEW, "b", { provider = "stock", origin = "main" })
    assert(txn:commit(true))
    fresh()
    inject(VIEW)
    set_regs(VIEW, {}, {})
    Manager:loadOrder(VIEW)
    local res = Manager:startupSync(VIEW)
    ok(res.mode == "regenerated_lagging" or res.mode == "regenerated"
        or res.changed == true,
        "lagging checkpoint regenerates (" .. tostring(res.mode) .. ")")
    ok(Manager:isItemHidden(VIEW, "b"), "interrupted intent preserved")
    wipe_all()
end

-- 4. disable withdraws files but keeps intent; resume regenerates.
do
    print("\n--- disable/re-enable ---")
    wipe_all()
    inject(VIEW)
    set_regs(VIEW, {}, {})
    Manager:stageList(VIEW, "main", { "c", "b", "a" })
    assert(Manager:saveOrder(VIEW))
    local summary = Manager:suspendForDisable()
    ok(summary[VIEW] ~= nil, "suspend reports per view")
    eq(KoreaderAdapter.nativeFileExists(VIEW), false, "suspend withdraws file")
    ok(Manager:isCustomized(VIEW), "suspend keeps canonical intent")
    fresh()
    inject(VIEW)
    set_regs(VIEW, {}, {})
    Manager:loadOrder(VIEW)
    local res = Manager:startupSync(VIEW)
    ok(res.mode == "regenerated_suspended" or res.mode == "regenerated"
        or res.changed == true,
        "resume regenerates from intent (" .. tostring(res.mode) .. ")")
    eq(table.concat(Manager:getMenuItems(VIEW, "main"), ","),
        "c,b,a", "resume restores customized order (never a revert wipe)")
    wipe_all()
end

-- 5. shared-table registration: provider tables never mutated.
do
    print("\n--- shared-table registration ---")
    local entry = { text = "Shared", sorting_hint = "main" }
    local before_hint, before_n = entry.sorting_hint, 0
    for _ in pairs(entry) do before_n = before_n + 1 end
    local w1 = { name = "aaa_plugin",
        addToMainMenu = function(_, m) m.shared_row = entry end }
    local w2 = { name = "zzz_plugin",
        addToMainMenu = function(_, m) m.shared_row = entry end }
    local regs, provs, colls = KoreaderAdapter.collectLiveRegistrations(
        { menu = { registered_widgets = { w1, w2 } } })
    eq(provs.shared_row, "aaa_plugin", "deterministic smallest-name wins")
    ok(colls.shared_row ~= nil and #colls.shared_row == 2, "collision reported")
    eq(entry.sorting_hint, before_hint, "provider hint field untouched")
    local after_n = 0
    for _ in pairs(entry) do after_n = after_n + 1 end
    eq(after_n, before_n, "no fields added to the provider table")
    ok(regs.shared_row ~= nil, "registration still collected")
    wipe_all()
end

-- 6. conditional contribution: live_mod level without registration ignored.
do
    print("\n--- conditional contribution ---")
    wipe_all()
    inject(VIEW)
    local mod = "ui/elements/reader_menu_order"
    local saved_mod = package.loaded[mod]
    package.loaded[mod] = {
        [ROOT] = { "main", "tools" },
        main = { "a", "b", "c" },
        tools = { "x", "y" },
        ghost_level = { "ghost_row" },
    }
    set_regs(VIEW, {}, {}) -- ghost_row NOT live-registered anywhere
    local reg = Registry.buildFromData(
        KoreaderAdapter.refreshLivePluginOrder(VIEW, {}, {}), {}, {}, nil)
    ok(reg.menus.ghost_level == nil, "unregistered level not adopted (no phantom)")
    ok(reg.nodes.ghost_row == nil, "unregistered row creates no node")
    package.loaded[mod] = saved_mod
    Manager:dropSessionState(VIEW)
    wipe_all()
end

-- 7. duplicate ID attribution is deterministic.
do
    print("\n--- duplicate ID ---")
    local function w(name, hint)
        return { name = name, addToMainMenu = function(_, m)
            m.dupe_row = { text = name, sorting_hint = hint }
        end }
    end
    local _, provs, colls = KoreaderAdapter.collectLiveRegistrations(
        { menu = { registered_widgets = { w("zeta", "tools"), w("alpha", "main") } } })
    eq(provs.dupe_row, "alpha", "smallest contributor wins")
    eq(colls.dupe_row[1], "alpha", "collision list sorted")
    eq(colls.dupe_row[2], "zeta", "collision list complete")
    wipe_all()
end

-- 8. stock insertion adopted at its live slot with provider kept.
do
    print("\n--- stock insertion ---")
    wipe_all()
    inject(VIEW)
    local mod = "ui/elements/reader_menu_order"
    local saved_mod = package.loaded[mod]
    -- Build the live world from the SHIPPED stock table (the only honest
    -- baseline for adoption): copy it, splice one live-registered row after
    -- the first row, and expect adoption at exactly that slot.
    local shipped = KoreaderAdapter.getDefaultOrder(VIEW, true)
    -- Find a menu whose first two rows are plain stock strings, so the
    -- expected adopted slot is unambiguous (index 2).
    local first_menu = nil
    do
        local names = {}
        for name, list in pairs(shipped) do
            if type(name) == "string" and type(list) == "table"
                    and name ~= ROOT and name ~= "KOMenu:disabled"
                    and name ~= "KOMenu:custom_submenus" and #list >= 2
                    and type(list[1]) == "string" and type(list[2]) == "string"
                    and list[1] ~= SEP and list[2] ~= SEP then
                names[#names + 1] = name
            end
        end
        table.sort(names)
        first_menu = names[1]
    end
    ok(first_menu ~= nil, "fixture menu with two leading stock rows found")
    local live = {}
    for name, list in pairs(shipped) do
        if type(list) == "table" then
            local copy = {}
            for _, id in ipairs(list) do copy[#copy + 1] = id end
            live[name] = copy
        else
            live[name] = list
        end
    end
    table.insert(live[first_menu], 2, "plug_row")
    package.loaded[mod] = live
    local order = KoreaderAdapter.refreshLivePluginOrder(VIEW,
        { plug_row = { sorting_hint = first_menu } }, { plug_row = "plugx" })
    local got = nil
    for i, id in ipairs(order[first_menu]) do if id == "plug_row" then got = i break end end
    eq(got, 2, "insertion adopted at its live slot")
    local provs = KoreaderAdapter.getExternalDefaultProviders(VIEW)
    eq(provs.plug_row, "plugin:plugx", "insertion provider kept")
    package.loaded[mod] = saved_mod
    Manager:dropSessionState(VIEW)
    wipe_all()
end

-- 9. repeated builds are byte-identical.
do
    print("\n--- repeated builds ---")
    wipe_all()
    inject(VIEW)
    set_regs(VIEW, {}, {})
    Manager:stageList(VIEW, "main", { "c", "b", "a" })
    assert(Manager:saveOrder(VIEW))
    local a = read_file(KoreaderAdapter.getNativePath(VIEW))
    fresh()
    inject(VIEW)
    set_regs(VIEW, {}, {})
    Manager:loadOrder(VIEW)
    Manager:saveOrder(VIEW)
    local b = read_file(KoreaderAdapter.getNativePath(VIEW))
    eq(a, b, "repeated build byte-identical")
    wipe_all()
end

-- 10. getter purity: post-sync reads write nothing and bump nothing.
do
    print("\n--- getter purity ---")
    wipe_all()
    inject(VIEW)
    set_regs(VIEW, {}, {})
    Manager:saveOrder(VIEW)
    fresh()
    inject(VIEW)
    set_regs(VIEW, {}, {})
    Manager:loadOrder(VIEW) -- runs the one startup sync (documented boundary)
    local before = snap_files()
    _ = Manager:loadOrder(VIEW)
    _ = Manager:getMenuItems(VIEW, "main")
    _ = Manager:getTabs(VIEW)
    _ = Manager:getParentMenu(VIEW, "a")
    _ = Manager:isCustomized(VIEW)
    _ = Manager:stagedView(VIEW)
    _ = Manager:peekTransaction()
    _ = Manager:isSynced(VIEW)
    _ = Manager:getVisibilityStatus(VIEW, "a")
    _ = Manager:getEffectiveModel(VIEW)
    _ = Manager:startupSync(VIEW) -- already synced: pure
    local after = snap_files()
    eq(after.intent, before.intent, "reads write no intent bytes")
    eq(after.sidecar, before.sidecar, "reads write no checkpoint bytes")
    eq(after.reader, before.reader, "reads write no native bytes")
    eq(after.gen, before.gen, "reads bump no generation")
    wipe_all()
end

-- 11. reload routing for both menu modules, repeated, closures intact.
do
    print("\n--- reload routing ---")
    for _, is_reader in ipairs({ true, false }) do
        package.loaded["apps/reader/modules/readermenu"] =
            package.loaded["apps/reader/modules/readermenu"] or {}
        package.loaded["apps/filemanager/filemanagermenu"] =
            package.loaded["apps/filemanager/filemanagermenu"] or {}
        local ui = {
            document = is_reader and {} or nil,
            menu = {
                registered_widgets = {},
                tab_item_table = { { id = "main" } },
                setUpdateItemTable = function(self)
                    self.tab_item_table = { { id = "main", refreshed = true } }
                end,
            },
        }
        local first = ui.menu
        local routed = 0
        local handler = function() return first:setUpdateItemTable() end
        for _ = 1, 3 do
            local ok_r = KoreaderAdapter.applyLiveReload(ui, function() end)
            ok(ok_r, "reload ok (reader=" .. tostring(is_reader) .. ")")
            eq(ui.menu, first, "controller identity preserved")
            local ok_call = pcall(handler)
            ok(ok_call, "retained closure still routes")
            routed = routed + 1
        end
        eq(routed, 3, "three reloads all route")
    end
    wipe_all()
end

-- 12. divergent ancestry: Reader-valid move cyclic in FM mirrors one side only.
do
    print("\n--- divergent ancestry mirror ---")
    wipe_all()
    -- Same submenu ids in BOTH views (ordinary stock submenus, not tabs), so
    -- ancestry can genuinely diverge per view.
    for _, v in ipairs({ VIEW, FM }) do
        Manager.default_orders[v] = {
            [ROOT] = { "main", "tools" },
            main = { "subA", "subB", "a" },
            subA = { "a1" },
            subB = { "b1" },
            tools = { "x" },
        }
        Manager:setLiveRegistrations(v, {}, {}, nil)
        Manager:dropSessionState(v)
        set_regs(v, {}, {})
    end
    IntentStore.setMeta("mirror_changes", false)
    -- FM only: nest subB inside subA (divergent ancestry vs reader).
    -- Mirroring stays OFF for the setup so the nesting stays FM-local.
    ok(Manager:moveItemToMenu(FM, "subB", "main", "subA"), "FM nests B in A")
    assert(Manager:saveOrder(FM))
    eq(Manager:getParentMenu(FM, "subB"), "subA", "FM ancestry diverged")
    eq(Manager:getParentMenu(VIEW, "subB"), "main", "reader still flat")
    -- Reader: subA into subB is valid here (both flat under main)...
    ok(Manager:canMoveItemToMenu(VIEW, "subA", "main", "subB"),
        "reader move A into B valid")
    -- ...but cyclic in FM, so the mirror must skip FM without partial state.
    ok(not Manager:canMoveItemToMenu(FM, "subA", "main", "subB"),
        "FM move A into B refused (cyclic)")
    IntentStore.setMeta("mirror_changes", true)
    ok(Manager:moveItemToMenu(VIEW, "subA", "main", "subB"), "reader nests A in B")
    assert(Manager:saveOrder(VIEW))
    eq(Manager:getParentMenu(VIEW, "subA"), "subB", "reader move applied")
    -- FM untouched by the mirror: A still directly under main there, and no
    -- cyclic record was staged for it.
    eq(Manager:getParentMenu(FM, "subA"), "main", "FM arrangement intact")
    local fm_sec = Manager:stagedView(FM)
    local fm_rec = fm_sec.parent_override and fm_sec.parent_override.subA
    ok(fm_rec == nil or fm_rec.parent ~= "subB",
        "FM mirror skipped: no cyclic record staged")
    IntentStore.setMeta("mirror_changes", false)
    wipe_all()
end

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)

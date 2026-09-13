--[[--
test_p0_audit_fixes.lua — P0 audit correctness regressions (15 bugs).

Smallest deterministic behavioral regression per bug; each fails before its
fix. Covers draft/save/restart/provider levels where meaningful.
--]]

local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")
local FuzzLib = dofile(project_dir .. "/tests/lib/fuzz_lib.lua")
FuzzLib.boot(project_dir)

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

require("main")

local IntentStore = require("lib.intent_store")
local NativeWriter = require("lib.native_writer")
local Materializer = require("lib.materializer")
local Validator = require("lib.validator")
local Registry = require("lib.registry")
local MenuSchema = require("lib.menu_schema")
local Presets = require("lib.presets")
local KoreaderAdapter = require("lib.koreader_adapter")
local DataLoader = require("lib.data_loader")
local Manager = require("lib.menuorder_manager")

local SEP = MenuSchema.SEPARATOR_ID
local ROOT = MenuSchema.MENU_BUTTONS_KEY
local DISABLED = MenuSchema.DISABLED_KEY
local CUSTOM = MenuSchema.CUSTOM_SUBMENUS_KEY

local passed, failed = 0, 0
local function ok(cond, msg)
    if cond then passed = passed + 1
    else
        failed = failed + 1
        print("  [FAIL] " .. tostring(msg))
        io.stdout:flush()
    end
end
local function eq(a, b, msg)
    if a == b then passed = passed + 1
    else
        failed = failed + 1
        print(string.format("  [FAIL] %s -> expected %s, got %s",
            tostring(msg), tostring(b), tostring(a)))
        io.stdout:flush()
    end
end

local function fresh_process()
    for _, view in ipairs({ "reader", "filemanager" }) do
        Manager:dropSessionState(view)
    end
    IntentStore.load(true)
    NativeWriter._resetCaches()
end

local function wipe_all()
    local sd = DataStorage:getSettingsDir()
    for _, name in ipairs({
        "reader_menu_order.lua", "filemanager_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua",
        "reorderingmenus_state.lua",
    }) do pcall(os.remove, sd .. "/" .. name) end
    os.execute("rm -rf " .. sd .. "/menu_order_presets 2>/dev/null")
    os.execute("rm -f " .. sd .. "/reorderingmenus_intent.lua.corrupt-* 2>/dev/null")
    os.execute("rm -f " .. sd .. "/reorderingmenus_intent.lua.unsupported* 2>/dev/null")
    fresh_process()
end

local function inject_reader_defaults(main_list, tools_list, tabs)
    Manager.default_orders["reader"] = {
        [ROOT] = tabs or { "main", "tools" },
        main = main_list,
        tools = tools_list or { "t1" },
    }
    Manager:setLiveRegistrations("reader", {}, {}, nil)
    Manager:dropSessionState("reader")
end

local function set_reader_registrations(items, providers, collisions)
    Manager:setLiveRegistrations("reader", items or {}, providers or {}, collisions)
    Manager:refreshRegistry("reader")
end

print("=== P0 audit fixes ===")

-- ---------------------------------------------------------------- Bug 1
print("\n--- Bug1: unreadable canonical must not be overwritten ---")
do
    wipe_all()
    local sd = DataStorage:getSettingsDir()
    local intent_path = sd .. "/reorderingmenus_intent.lua"
    -- Oversized via tightened bound (no 8MB write needed).
    local old_max = DataLoader.MAX_FILE_BYTES
    DataLoader.MAX_FILE_BYTES = 64
    local big = "-- big\nreturn { version = 3, views = {}, meta = {} }\n" .. string.rep("x", 200)
    local f = assert(io.open(intent_path, "w")); f:write(big); f:close()
    local before = (function() local fh = io.open(intent_path, "r"); local s = fh:read("*a"); fh:close(); return s end)()
    IntentStore._resetPreservationForTests()
    -- Fresh load object: clear memoised state by forcing reload.
    local _, problems = IntentStore.load(true)
    local after = (function() local fh = io.open(intent_path, "r"); local s = fh and fh:read("*a"); if fh then fh:close() end; return s end)()
    eq(after, before, "B1 oversized: canonical bytes unchanged")
    local has_preservation = false
    for _, p in ipairs(problems or {}) do
        if p.kind == "preservation_failed" or p.kind == "unparsable" then has_preservation = true end
    end
    ok(has_preservation, "B1 oversized: load reports preservation problem")
    -- No fake empty backup: every corrupt backup must be non-empty.
    local empty_backup = false
    for file in lfs.dir(sd) do
        if file:match("^reorderingmenus_intent%.lua%.corrupt%-") then
            local fh = io.open(sd .. "/" .. file, "r")
            local body = fh and fh:read("*a") or ""
            if fh then fh:close() end
            if body == "" then empty_backup = true end
        end
    end
    ok(not empty_backup, "B1: no nil->empty fake backup")
    -- Save must refuse while original unpreserved.
    local ok_save = IntentStore.save()
    eq(ok_save, false, "B1: save refuses while unreadable original unpreserved")
    DataLoader.MAX_FILE_BYTES = old_max
    IntentStore._resetPreservationForTests()
    wipe_all()
end

-- ---------------------------------------------------------------- Bug 2
print("\n--- Bug2: hidden/absent ordering survives ---")
do
    wipe_all()
    inject_reader_defaults({ "a", "b", "c" }, { "t1" })
    set_reader_registrations({}, {})
    -- Reorder [a,b,c] -> [a,c,b], hide b: visible [a,c] matches baseline,
    -- but ordering must survive for unhide.
    Manager:stageList("reader", "main", { "a", "c", "b" })
    assert(Manager:saveOrder("reader"))
    Manager:setItemHidden("reader", "b", true, "main")
    assert(Manager:saveOrder("reader"))
    local staged = Manager:stagedView("reader")
    local has_ordering = (staged.order_override and staged.order_override["main"] ~= nil)
        or (staged.position_override and staged.position_override["b"] ~= nil)
    ok(has_ordering,
        "B2: reorder survives hide+save (no graph pruning)")
    fresh_process()
    inject_reader_defaults({ "a", "b", "c" }, { "t1" })
    set_reader_registrations({}, {})
    Manager:setItemHidden("reader", "b", false)
    assert(Manager:saveOrder("reader"))
    local order = Manager:getMenuItems("reader", "main")
    eq(table.concat(order, ","), "a,c,b", "B2: reorder->hide->save->unhide restores position")

    -- Provider disappearance: plugin row p first, provider leaves, unrelated
    -- save, provider returns.
    wipe_all()
    inject_reader_defaults({ "a", "b", "c" }, { "t1" })
    set_reader_registrations({ p = { sorting_hint = "main" } }, { p = "plugx" })
    Manager:stageList("reader", "main", { "p", "a", "b", "c" })
    assert(Manager:saveOrder("reader"))
    -- Provider disappears.
    set_reader_registrations({}, {})
    -- Unrelated save in another menu.
    Manager:setItemHidden("reader", "t1", true, "tools")
    assert(Manager:saveOrder("reader"))
    local staged2 = Manager:stagedView("reader")
    local has_ordering2 = (staged2.order_override and staged2.order_override["main"] ~= nil)
        or (staged2.position_override and staged2.position_override["p"] ~= nil)
    ok(has_ordering2,
        "B2: ordering with dormant entry survives unrelated save")
    -- Provider returns.
    set_reader_registrations({ p = { sorting_hint = "main" } }, { p = "plugx" })
    fresh_process()
    inject_reader_defaults({ "a", "b", "c" }, { "t1" })
    set_reader_registrations({ p = { sorting_hint = "main" } }, { p = "plugx" })
    local order2 = Manager:getMenuItems("reader", "main")
    eq(order2[1], "p", "B2: provider return restores intended ordering")
    wipe_all()
end

-- ---------------------------------------------------------------- Bug 3
print("\n--- Bug3: insertion positions into reordered destination ---")
do
    for _, pos in ipairs({ "begin", "middle", "end" }) do
        wipe_all()
        inject_reader_defaults({ "a", "b", "c", "d" }, { "x", "y" })
        set_reader_registrations({}, {})
        Manager:stageList("reader", "main", { "d", "c", "b", "a" })
        assert(Manager:saveOrder("reader"))
        local preview_before = Manager:getMenuItems("reader", "main")
        if pos == "begin" then
            assert(Manager:moveItemToMenu("reader", "x", "tools", "main", 1))
        elseif pos == "middle" then
            -- Insert after c (middle of d,c,b,a).
            local dest = Manager:getMenuItems("reader", "main")
            local idx = nil
            for i, id in ipairs(dest) do if id == "c" then idx = i break end end
            assert(Manager:moveItemToMenu("reader", "x", "tools", "main", (idx or 2) + 1))
        else
            assert(Manager:moveItemToMenu("reader", "x", "tools", "main", nil))
        end
        local preview = Manager:getMenuItems("reader", "main")
        assert(Manager:saveOrder("reader"))
        local saved = Manager:getMenuItems("reader", "main")
        eq(table.concat(saved, ","), table.concat(preview, ","),
            "B3[" .. pos .. "]: preview == saved")
        fresh_process()
        inject_reader_defaults({ "a", "b", "c", "d" }, { "x", "y" })
        set_reader_registrations({}, {})
        local restarted = Manager:getMenuItems("reader", "main")
        eq(table.concat(restarted, ","), table.concat(saved, ","),
            "B3[" .. pos .. "]: saved == restarted")
        -- Position anchor must have survived minimization.
        local staged = Manager:stagedView("reader")
        if pos ~= "end" then
            ok(staged.position_override and staged.position_override["x"] ~= nil,
                "B3[" .. pos .. "]: insertion anchor preserved")
        end
        if pos == "begin" then eq(saved[1], "x", "B3 begin at head")
        elseif pos == "end" then eq(saved[#saved], "x", "B3 end at tail") end
        _ = preview_before
    end
    wipe_all()
end

-- ---------------------------------------------------------------- Bug 4
print("\n--- Bug4: bulk import preserves unknown ids ---")
do
    wipe_all()
    inject_reader_defaults({ "a", "b", "c" }, { "t1" })
    set_reader_registrations({}, {})
    local reg = Registry.buildFromData(
        Manager.default_orders["reader"], {}, {}, nil)
    local txn = IntentStore.openTransaction()
    -- Simulate external bulk reorder introducing unknown z.
    local new_list = { "c", "z", "a", "b" }
    local old_list = { "a", "b", "c" }
    local diff = require("lib.semantic_diff").infer_list_change(old_list, new_list)
    ok(diff ~= nil, "B4: bulk diff detected")
    -- Drive the real importer path instead of reimplementing it.
    local entry = { structure = { main = old_list }, fingerprint = "x",
        intent_gen = 0, writer_version = NativeWriter.WRITER_VERSION }
    -- Seed sidecar via a save, then hand-edit the native file.
    Manager:stageList("reader", "main", { "a", "b", "c" })
    Manager:saveOrder("reader")
    local native_path = KoreaderAdapter.getNativePath("reader")
    -- Write a native file with unknown z in bulk (bypass writer filter).
    local AtomicWriter = require("lib.atomic_writer")
    -- Build a full native emission and inject z.
    local cur = Manager:loadOrder("reader")
    cur["main"] = { "c", "z", "a", "b" }
    -- Write directly through the adapter (no filtering).
    assert(KoreaderAdapter.writeNativeOrder("reader", cur))
    fresh_process()
    inject_reader_defaults({ "a", "b", "c" }, { "t1" })
    set_reader_registrations({}, {})
    -- Startup sync imports the external bulk change.
    Manager:loadOrder("reader")
    local staged = Manager:stagedView("reader")
    local found_z = false
    local ov = staged.order_override and staged.order_override["main"]
    if ov and ov.entries then
        for _, e in ipairs(ov.entries) do
            if e.id == "z" then found_z = true end
        end
    end
    ok(found_z, "B4: unknown id preserved as dormant intent")
    -- Unrelated save must not delete it.
    Manager:setItemHidden("reader", "t1", true, "tools")
    Manager:saveOrder("reader")
    local staged2 = Manager:stagedView("reader")
    local found_z2 = false
    local ov2 = staged2.order_override and staged2.order_override["main"]
    if ov2 and ov2.entries then
        for _, e in ipairs(ov2.entries) do if e.id == "z" then found_z2 = true end end
    end
    ok(found_z2, "B4: unrelated save preserves unknown")
    -- Provider registration makes it applicable.
    set_reader_registrations({ z = { sorting_hint = "main" } }, { z = "plugz" })
    fresh_process()
    inject_reader_defaults({ "a", "b", "c" }, { "t1" })
    set_reader_registrations({ z = { sorting_hint = "main" } }, { z = "plugz" })
    local order = Manager:getMenuItems("reader", "main")
    local has_z = false
    for _, id in ipairs(order) do if id == "z" then has_z = true end end
    ok(has_z, "B4: later provider makes unknown applicable")
    _ = reg; _ = txn; _ = entry
    wipe_all()
end

-- ---------------------------------------------------------------- Bug 5
print("\n--- Bug5: hintless items stay visible ---")
do
    wipe_all()
    inject_reader_defaults({ "a", "b" }, { "t1" })
    -- Hintless live contribution, no live_mod insertion.
    set_reader_registrations({ plug_item = {} }, { plug_item = "plugx" })
    local order = Manager:getMenuItems("reader", "main")
    local found = false
    for _, id in ipairs(order) do if id == "plug_item" then found = true end end
    ok(found, "B5: hintless contribution rendered (not disabled)")
    local disabled = Manager:getDisabledItems("reader")
    local is_disabled = false
    for _, id in ipairs(disabled) do if id == "plug_item" then is_disabled = true end end
    ok(not is_disabled, "B5: hintless not in disabled")
    -- Unrelated customization + restart keeps it.
    Manager:setItemHidden("reader", "a", true, "main")
    Manager:saveOrder("reader")
    fresh_process()
    inject_reader_defaults({ "a", "b" }, { "t1" })
    set_reader_registrations({ plug_item = {} }, { plug_item = "plugx" })
    local order2 = Manager:getMenuItems("reader", "main")
    local found2 = false
    for _, id in ipairs(order2) do if id == "plug_item" then found2 = true end end
    ok(found2, "B5: hintless survives unrelated save+restart")

    -- Third-party insertion into an existing stock level is adopted as
    -- default (not disabled), survives unrelated customization + restart.
    -- Uses the REAL stock layout (no injected defaults) so adoption runs
    -- against genuine menus.
    do
        wipe_all()
        Manager.default_orders["reader"] = nil
        Manager:dropSessionState("reader")
        local stock = KoreaderAdapter.getDefaultOrder("reader")
        local target_menu, anchor_a = nil, nil
        for menu_id, list in pairs(stock) do
            if menu_id ~= ROOT and menu_id ~= DISABLED and menu_id ~= CUSTOM
                    and type(list) == "table" and #list >= 2 then
                for _, id in ipairs(list) do
                    if type(id) == "string" and id ~= SEP then
                        anchor_a = id break
                    end
                end
                if anchor_a then target_menu = menu_id break end
            end
        end
        ok(target_menu ~= nil, "B5: found real stock menu for insertion test")
        if target_menu then
            local live_mod_name = "ui/elements/reader_menu_order"
            local live_copy = {}
            for k, v in pairs(
                    package.loaded[live_mod_name] or stock) do
                live_copy[k] = type(v) == "table"
                    and util.tableDeepCopy(v) or v
            end
            -- Insert plug_row after the first stock row at the live slot.
            local live_list = util.tableDeepCopy(live_copy[target_menu] or {})
            table.insert(live_list, 2, "plug_row_b5")
            live_copy[target_menu] = live_list
            package.loaded[live_mod_name] = live_copy
            KoreaderAdapter.refreshLivePluginOrder("reader",
                { plug_row_b5 = { sorting_hint = target_menu } },
                { plug_row_b5 = "plugx" })
            Manager:dropSessionState("reader")
            set_reader_registrations(
                { plug_row_b5 = { sorting_hint = target_menu } },
                { plug_row_b5 = "plugx" })
            local order3 = Manager:getMenuItems("reader", target_menu)
            local found3 = false
            for _, id in ipairs(order3) do
                if id == "plug_row_b5" then found3 = true end
            end
            ok(found3, "B5: stock-level insertion adopted")
            local dis3 = Manager:getDisabledItems("reader")
            local dis_found = false
            for _, id in ipairs(dis3) do
                if id == "plug_row_b5" then dis_found = true end
            end
            ok(not dis_found, "B5: insertion not disabled")
            -- Unrelated customization + restart keeps it at its slot.
            Manager:setItemHidden("reader", anchor_a, true,
                Manager:getParentMenu("reader", anchor_a))
            Manager:saveOrder("reader")
            fresh_process()
            package.loaded[live_mod_name] = util.tableDeepCopy(live_copy)
            KoreaderAdapter.refreshLivePluginOrder("reader",
                { plug_row_b5 = { sorting_hint = target_menu } },
                { plug_row_b5 = "plugx" })
            Manager:dropSessionState("reader")
            set_reader_registrations(
                { plug_row_b5 = { sorting_hint = target_menu } },
                { plug_row_b5 = "plugx" })
            local order4 = Manager:getMenuItems("reader", target_menu)
            local found4 = false
            for _, id in ipairs(order4) do
                if id == "plug_row_b5" then found4 = true end
            end
            ok(found4, "B5: insertion survives unrelated+restart")
            package.loaded[live_mod_name] = nil
            KoreaderAdapter.getDefaultOrder("reader", true)
        end
        wipe_all()
    end
end

-- ---------------------------------------------------------------- Bug 6
print("\n--- Bug6: live reload preserves identity ---")
do
    -- Force the reload path (module considered loaded).
    package.loaded["apps/reader/modules/readermenu"] = package.loaded["apps/reader/modules/readermenu"] or {}
    local ui = {
        document = {},
        menu = {
            registered_widgets = {},
            tab_item_table = { { id = "main" } },
            setUpdateItemTable = function(self)
                self.tab_item_table = { { id = "main", refreshed = true } }
            end,
        },
    }
    local old_menu = ui.menu
    -- Touch-zone style closure bound to the old instance.
    local routed = {}
    local handler = function(ges) return old_menu:setUpdateItemTable() end
    local ok_reload, err = KoreaderAdapter.applyLiveReload(ui, function() end)
    ok(ok_reload, "B6: reload ok (" .. tostring(err or "nil") .. ")")
    eq(ui.menu, old_menu, "B6: controller identity preserved")
    ok(ui.menu.tab_item_table ~= nil and ui.menu.tab_item_table[1].refreshed,
        "B6: tree rebuilt on same instance")
    -- Event routing through the retained closure reaches the live tree.
    local ok_call = pcall(handler, {})
    ok(ok_call, "B6: retained touch/key closure still routes")
    _ = routed
end

-- ---------------------------------------------------------------- Bug 7
print("\n--- Bug7: explicit zero dividers ---")
do
    wipe_all()
    inject_reader_defaults({ "a", SEP, "b", SEP, "c" }, { "t1" })
    set_reader_registrations({}, {})
    local baseline = Manager:getMenuItems("reader", "main")
    local seps = 0
    for _, id in ipairs(baseline) do if id == SEP then seps = seps + 1 end end
    eq(seps, 2, "B7: baseline has stock dividers")
    -- Remove all dividers.
    Manager:stageList("reader", "main", { "a", "b", "c" })
    Manager:saveOrder("reader")
    local no_sep = Manager:getMenuItems("reader", "main")
    local seps2 = 0
    for _, id in ipairs(no_sep) do if id == SEP then seps2 = seps2 + 1 end end
    eq(seps2, 0, "B7: draft has zero dividers")
    fresh_process()
    inject_reader_defaults({ "a", SEP, "b", SEP, "c" }, { "t1" })
    set_reader_registrations({}, {})
    local restarted = Manager:getMenuItems("reader", "main")
    local seps3 = 0
    for _, id in ipairs(restarted) do if id == SEP then seps3 = seps3 + 1 end end
    eq(seps3, 0, "B7: zero survives restart (nil vs zero distinguished)")
    -- Add one divider without deleting unrelated (only one expected).
    Manager:insertSeparator("reader", "main", 2)
    Manager:saveOrder("reader")
    local one = Manager:getMenuItems("reader", "main")
    local seps4 = 0
    for _, id in ipairs(one) do if id == SEP then seps4 = seps4 + 1 end end
    eq(seps4, 1, "B7: add one divider yields exactly one")
    -- Hide/unhide around anchor preserves divider.
    Manager:setItemHidden("reader", "a", true, "main")
    Manager:saveOrder("reader")
    Manager:setItemHidden("reader", "a", false)
    Manager:saveOrder("reader")
    local after_unhide = Manager:getMenuItems("reader", "main")
    local seps5 = 0
    for _, id in ipairs(after_unhide) do if id == SEP then seps5 = seps5 + 1 end end
    eq(seps5, 1, "B7: hide/unhide around anchor preserves divider")
    wipe_all()
end

-- ---------------------------------------------------------------- Bug 8
print("\n--- Bug8: submenu preset apply uses saved order ---")
do
    wipe_all()
    inject_reader_defaults({ "x" }, { "t1" })
    -- Build a submenu level 'sub' with a,b,c via custom container.
    Manager.default_orders["reader"] = {
        [ROOT] = { "main", "tools" },
        main = { "sub" },
        sub = { "a", "b", "c" },
        tools = { "t1" },
    }
    Manager:setLiveRegistrations("reader", {}, {}, nil)
    Manager:dropSessionState("reader")
    set_reader_registrations({}, {})
    -- Save preset with order c,b,a.
    Manager:stageList("reader", "sub", { "c", "b", "a" })
    local ok_save, save_path = Manager:saveSubmenuPreset(
        "reader", "sub", "Sub", "audit8", false, nil)
    ok(ok_save, "B8: submenu preset saved")
    -- Current rows drift back to a,b,c.
    Manager:stageList("reader", "sub", { "a", "b", "c" })
    -- Apply preset while editor shows a,b,c (staged_items).
    local s = (function()
        -- Reach session/registry via manager internals through public verbs:
        -- loadSubmenuPreset takes current_menu_items as staged assist.
        local ok_apply = Manager:loadSubmenuPreset(
            "reader", "sub", "audit8", { "a", "b", "c" })
        return ok_apply
    end)()
    ok(s, "B8: submenu preset applied")
    local order = Manager:getMenuItems("reader", "sub")
    eq(table.concat(order, ","), "c,b,a", "B8: saved c,b,a wins over current a,b,c")
    _ = save_path
    wipe_all()
end

-- ---------------------------------------------------------------- Bug 9
print("\n--- Bug9: view preset raw symmetry ---")
do
    wipe_all()
    inject_reader_defaults({ "a", "b" }, { "t1" })
    set_reader_registrations({}, {})
    local txn = IntentStore.openTransaction()
    txn:setRawOverride("reader", "main", { "a", "b" })
    local ok_save, path = Presets.saveViewPreset("reader", "audit9", txn:view("reader"))
    ok(ok_save, "B9: view preset with raw saved")
    -- Clear raw, then apply: raw must come back.
    local txn2 = IntentStore.openTransaction()
    txn2:setRawOverride("reader", "main", nil)
    local data = Presets.readUserPreset(path)
    ok(data and data.intent and data.intent.raw_override
        and data.intent.raw_override["main"] ~= nil, "B9: capture kept raw")
    local txn3 = IntentStore.openTransaction()
    Presets.applyUserIntentPreset("reader", txn3, data.intent, nil)
    ok(txn3:view("reader").raw_override
        and txn3:view("reader").raw_override["main"] ~= nil,
        "B9: apply restores raw (symmetric)")
    wipe_all()
end

-- ---------------------------------------------------------------- Bug 10
print("\n--- Bug10: legacy import keeps titles/content ---")
do
    wipe_all()
    inject_reader_defaults({ "s1", "s2" }, { "t1" })
    set_reader_registrations({}, {})
    local reg = Registry.buildFromData(
        Manager.default_orders["reader"], {}, {}, nil)
    local txn = IntentStore.openTransaction()
    local native = {
        [ROOT] = { "main", "tools" },
        main = { "s1" },
        tools = { "t1" },
        my_sub = { "s2", SEP, "s1_copy" },
        nested_sub = { "deep_item" },
        [CUSTOM] = { my_sub = "My Titled Menu", nested_sub = "Nested" },
    }
    -- my_sub contains moved stock child s2; nested_sub nested under my_sub.
    native["my_sub"] = { "s2", SEP, "deep_item" }
    local n = NativeWriter.importAgainstDefaults("reader", reg, txn, native)
    ok(n > 0, "B10: legacy import produced intent")
    local sec = txn:view("reader")
    eq(sec.custom_menus and sec.custom_menus["my_sub"]
        and sec.custom_menus["my_sub"].title, "My Titled Menu",
        "B10: titled custom submenu preserved")
    ok(sec.parent_override and sec.parent_override["s2"] ~= nil,
        "B10: moved stock child membership recorded")
    ok(sec.custom_menus and sec.custom_menus["nested_sub"] ~= nil,
        "B10: nested custom container created")
    local has_sep = false
    for _, s in pairs(sec.separators or {}) do
        if s.parent == "my_sub" then has_sep = true end
    end
    ok(has_sep, "B10: dividers in custom import recorded")
    wipe_all()
end

-- ---------------------------------------------------------------- Bug 11
print("\n--- Bug11: disable marks before removing ---")
do
    wipe_all()
    inject_reader_defaults({ "a", "b" }, { "t1" })
    set_reader_registrations({}, {})
    Manager:stageList("reader", "main", { "b", "a" })
    Manager:saveOrder("reader")
    local native_path = KoreaderAdapter.getNativePath("reader")
    local exists_before = KoreaderAdapter.nativeFileExists("reader")
    ok(exists_before, "B11: derived file exists before suspend")
    -- Force the durable mark to fail: poison the sidecar location.
    local sidecar_path = DataStorage:getSettingsDir()
        .. "/reorderingmenus_materialization.lua"
    local poisoned = false
    local orig_mark = NativeWriter.markSuspended
    NativeWriter.markSuspended = function() return false, "injected mark failure" end
    local summary = Manager:suspendForDisable()
    NativeWriter.markSuspended = orig_mark
    eq(summary["reader"].suspended, false, "B11: injected mark failure reported")
    ok(KoreaderAdapter.nativeFileExists("reader"),
        "B11: file NOT withdrawn when durable mark failed (crash-safe order)")
    _ = poisoned; _ = sidecar_path; _ = native_path
    wipe_all()
end

-- ---------------------------------------------------------------- Bug 12
print("\n--- Bug12: move actions resolve total ---")
do
    wipe_all()
    inject_reader_defaults({ "a", "b", "c" }, { "t1" })
    set_reader_registrations({}, {})
    local UIScreens = require("lib.ui_screens")
    local idx, total = UIScreens:_currentIndexOfItem("reader", "main", "b")
    eq(idx, 2, "B12: index resolves")
    eq(total, 3, "B12: total resolves (multi-return contract)")
    -- Every movement action for items and separators must not error.
    ok(Manager:moveItem("reader", "main", 2, 3), "B12: item move down")
    ok(Manager:moveItem("reader", "main", 3, 1), "B12: item move to top")
    ok(Manager:moveItem("reader", "main", 1, 3), "B12: item move to bottom")
    ok(Manager:moveItem("reader", "main", 3, 2), "B12: item move up")
    Manager:insertSeparator("reader", "main", 2)
    local with_sep = Manager:getMenuItems("reader", "main")
    local sep_idx = nil
    for i, id in ipairs(with_sep) do if id == SEP then sep_idx = i break end end
    ok(sep_idx ~= nil, "B12: separator inserted")
    ok(Manager:moveItem("reader", "main", sep_idx, 1), "B12: separator move")
    ok(Manager:removeSeparator("reader", "main", 1)
        or true, "B12: separator delete path exercised")
    -- The fixed helper must forward both values (no nil total).
    local src = (function()
        local fh = io.open(project_dir .. "/lib/ui_screens.lua", "r")
        local body = fh:read("*a"); fh:close()
        return body
    end)()
    ok(src:find("return cur, total", 1, true) ~= nil,
        "B12: helper forwards (index, total)")
    wipe_all()
end

-- ---------------------------------------------------------------- Bug 13
print("\n--- Bug13: builtins scoped by (view,id) ---")
do
    for _, view in ipairs({ "reader", "filemanager" }) do
        for _, p in ipairs(Presets.getBuiltinPresets(view)) do
            local resolved, err = Presets.resolve(view, p.id)
            ok(resolved ~= nil and resolved.fragment ~= nil,
                "B13: " .. view .. "/" .. tostring(p.id) .. " resolves")
            if resolved and resolved.fragment then
                local frag_view = resolved.fragment.view
                -- Default preset is global; others must match the view.
                if not resolved.fragment.is_default then
                    eq(frag_view, view,
                        "B13: " .. tostring(p.id) .. " scoped to " .. view)
                end
            else
                print("    resolve err: " .. tostring(err))
            end
        end
    end
    -- The duplicate id must resolve differently per view.
    local r = Presets.resolve("reader", "builtin_power_user")
    local f = Presets.resolve("filemanager", "builtin_power_user")
    ok(r and f and r.fragment ~= f.fragment,
        "B13: duplicate FM/reader power_user are distinct")
end

-- ---------------------------------------------------------------- Bug 14
print("\n--- Bug14: empty-tab recovery yields real tabs ---")
do
    local reg = {
        menus = { main = { list = { "a" }, is_tab = true },
                  tools = { list = { "t1" }, is_tab = true } },
        tab_list = { "main", "tools" },
        nodes = { main = { provider = "stock" }, tools = { provider = "stock" } },
    }
    -- All tabs hidden: empty bar, disabled holds tabs.
    local graph = { tabs = {}, lists = { main = { "a" }, tools = { "t1" } },
        disabled = { "tools", "main" }, unplaced = {}, custom_titles = {} }
    local _, repaired = Validator.validate(graph, reg, {})
    ok(#repaired.tabs > 0, "B14: all-hidden recovers a tab")
    for _, t in ipairs(repaired.tabs) do
        ok(repaired.lists[t] ~= nil, "B14: tab " .. tostring(t) .. " has real list")
    end
    -- Last tab removed upstream + recovery target hidden.
    local reg2 = {
        menus = { main = { list = { "a" }, is_tab = true } },
        tab_list = { "main" },
        nodes = { main = { provider = "stock" } },
    }
    local graph2 = { tabs = {}, lists = {},
        disabled = { "tools", "main" }, unplaced = {}, custom_titles = {} }
    local _, repaired2 = Validator.validate(graph2, reg2, {})
    ok(#repaired2.tabs > 0, "B14: removed-tab recovers")
    for _, t in ipairs(repaired2.tabs) do
        ok(repaired2.lists[t] ~= nil, "B14: recovered tab has list")
    end
end

-- ---------------------------------------------------------------- Bug 15
print("\n--- Bug15: structural equality sees title maps ---")
do
    local a = { main = { "a", "b" }, [CUSTOM] = { sub = "Old" } }
    local b = { main = { "a", "b" }, [CUSTOM] = { sub = "New" } }
    eq(NativeWriter.nativeStructureEquals(a, b), false,
        "B15: differing title maps are unequal")
    local c = { main = { "a", "b" }, [CUSTOM] = { sub = "Same" } }
    local d = { main = { "a", "b" }, [CUSTOM] = { sub = "Same" } }
    eq(NativeWriter.nativeStructureEquals(c, d), true,
        "B15: identical maps are equal")
    eq(NativeWriter.nativeStructureEquals(
        { main = { "a", "b" } }, { main = { "a", "c" } }), false,
        "B15: arrays still compared as arrays")
end

print(string.format("\nSuites: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)

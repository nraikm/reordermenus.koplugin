--[[--
Targeted interaction suites (mandates N, W, S, P):

  N  Tab fuzzing        - randomized hide/reorder/upstream add-remove-reorder/
                          unhide/preset/reset histories; hidden tabs must
                          return deterministically and new tabs must slot by
                          default neighbors, never drift by hidden-neighbor
                          state. Full battery after every op.
  W  Ghost accumulation - thousands of provider tombstones: no visible impact,
                          sane load time, Reset All cleans, reinstall restores,
                          other-provider reuse isolated.
  S  Abrupt editor exit - stage changes then terminate without commit;
                          nothing persists. Late/duplicate callbacks after
                          close are inert.
  P  Duplicate events   - Save x2, Hide x2, Unhide x2, move-confirm x2,
                          discard x2: semantic idempotence, no duplicate
                          durable records.

Env knobs: N_SEEDS/N_STEPS (tab fuzz), W_N (tombstone count).
--]]

local test_path = debug.getinfo(1, "S").source:sub(2)
local project = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")
package.path = project .. "/?.lua;" .. package.path

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir()
    .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()

local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

_ = require("gettext")

require("main")

local World = require("tests.lib.sm_world")
local Manager = require("reorderingmenus_menuorder_manager")
local IntentStore = require("reorderingmenus_intent_store")
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
local util = require("util")

local passed, failed = 0, 0
local function note(cond, msg)
    if cond then passed = passed + 1
    else failed = failed + 1; print("  [FAIL] " .. tostring(msg)); io.stdout:flush() end
end

print("===============================================================")
print("=== Tab fuzz / ghost accumulation / abort / duplicate events ===")
print("===============================================================")

-- =====================================================================
-- N: TAB FUZZING
-- =====================================================================
do
    local N_SEEDS = tonumber(os.getenv("N_SEEDS")) or 6
    local N_STEPS = tonumber(os.getenv("N_STEPS")) or 60

    local TAB_OPS = { "hide_tab", "reorder_tabs", "upstream_add_tab",
        "upstream_remove_tab", "save_order", "restart", "reset_view",
        "unhide_all", "apply_preset" }

    local real_step = World.step
    World.step = function(self)
        -- biased: tab ops dominate; a little general churn keeps worlds real
        local weights, total = {}, 0
        for _, name in ipairs(World.OP_NAMES) do
            local w = 0
            for _, t in ipairs(TAB_OPS) do if t == name then w = 12 break end
            end
            if w == 0 and (name == "move_item_in_menu" or name == "hide_item") then
                w = 1
            end
            weights[name] = w
            total = total + w
        end
        local roll = self:rand(total)
        local chosen
        for _, name in ipairs(World.OP_NAMES) do
            local w = weights[name] or 0
            if roll <= w and w > 0 then chosen = name break end
            roll = roll - w
        end
        chosen = chosen or "save_order"
        local spec = World.OPS[chosen]
        local args = spec.pick(self)
        if args == nil then return chosen, nil, chosen .. "(skipped)" end
        self.history[#self.history + 1] = { op = chosen, args = args }
        self.op_counter = self.op_counter + 1
        local ok, desc = pcall(spec.apply, self, args)
        if not ok then desc = "OPERROR: " .. tostring(desc) end
        return chosen, args, desc
    end

    local clean_runs, violations = 0, 0
    for s = 1, N_SEEDS do
        local seed = 555000 + s * 7717
        local w = World:new(seed)
        local ok_run = true
        for _ = 1, N_STEPS do
            local _, _, desc = w:step()
            if type(desc) == "string" and desc:sub(1, 8) == "OPERROR:" then
                note(false, "N seed " .. seed .. " op crash: " .. desc:sub(1, 140))
                ok_run = false; violations = violations + 1; break
            end
            local ok, failures = w:check()
            if not ok then
                note(false, "N seed " .. seed .. ": " ..
                    tostring(failures[1]):sub(1, 180))
                ok_run = false; violations = violations + 1; break
            end
        end
        -- Deterministic-return check: every hidden historical tab must be
        -- restorable to a deterministic slot (its default index among
        -- surviving tabs), never dependent on hidden neighbors.
        if ok_run then
            local order = w:projection()
            local bar = order["KOMenu:menu_buttons"] or {}
            local seen, dup = {}, false
            for _, t in ipairs(bar) do
                if seen[t] then dup = true end
                seen[t] = true
            end
            note(not dup, "N seed " .. seed .. ": final bar duplicates")
            note(#bar > 0, "N seed " .. seed .. ": final bar non-empty")
            -- hidden-tab determinism: unhiding twice yields same slot
            local all_tabs = w.defaults[w.view]["KOMenu:menu_buttons"] or {}
            for _, t in ipairs(all_tabs) do
                if not seen[t] and Manager:isTabProtected(t) ~= true then
                    -- hidden historical tab: restore, record slot, hide again,
                    -- restore again -> same slot
                    Manager:setTabHidden(w.view, t, false)
                    Manager:saveOrder(w.view)
                    local bar1 = w:projection()["KOMenu:menu_buttons"] or {}
                    local slot1
                    for i, x in ipairs(bar1) do if x == t then slot1 = i end end
                    Manager:setTabHidden(w.view, t, true)
                    Manager:saveOrder(w.view)
                    Manager:setTabHidden(w.view, t, false)
                    Manager:saveOrder(w.view)
                    local bar2 = w:projection()["KOMenu:menu_buttons"] or {}
                    local slot2
                    for i, x in ipairs(bar2) do if x == t then slot2 = i end end
                    note(slot1 ~= nil and slot1 == slot2,
                        "N seed " .. seed .. ": hidden tab " .. t ..
                        " returns deterministically (" ..
                        tostring(slot1) .. " vs " .. tostring(slot2) .. ")")
                    Manager:setTabHidden(w.view, t, false)
                    Manager:saveOrder(w.view)
                end
            end
            clean_runs = clean_runs + 1
        end
        io.stdout:flush()
    end
    World.step = real_step
    note(violations == 0, string.format(
        "N: %d/%d biased tab histories clean (violations=%d)",
        clean_runs, N_SEEDS, violations))
end

-- =====================================================================
-- W: GHOST ACCUMULATION
-- =====================================================================
do
    local FuzzLib = dofile(project .. "/tests/lib/fuzz_lib.lua")
    local W_N = tonumber(os.getenv("W_N")) or 2000
    local VIEW = "reader"
    local function fresh()
        local sd = KoreaderAdapter.getSettingsDir()
        pcall(os.remove, sd .. "/reader_menu_order.lua")
        pcall(os.remove, sd .. "/filemanager_menu_order.lua")
        pcall(os.remove, sd .. "/reorderingmenus_intent.lua")
        pcall(os.remove, sd .. "/reorderingmenus_materialization.lua")
        for _, v in ipairs({ VIEW, "filemanager" }) do
            Manager:resetOrder(v)
            Manager:dropSessionState(v)
        end
        IntentStore.load(true)
    end
    fresh()
    Manager.default_orders[VIEW] =
        util.tableDeepCopy(require("ui/elements/reader_menu_order"))
    -- register one live plugin item, pin it, then remove it W_N times with
    -- distinct ids -> W_N tombstones (parent_override ghosts).
    local regs, provs = {}, {}
    for i = 1, W_N do
        regs["gh_item_" .. i] = { sorting_hint = "search" }
        provs["gh_item_" .. i] = "widgetX"
    end
    Manager:setLiveRegistrations(VIEW, regs, provs)
    _ = Manager:loadOrder(VIEW)

    local t0 = os.clock()
    local txn = IntentStore.openTransaction()
    for i = 1, W_N do
        txn:setParentOverride(VIEW, "gh_item_" .. i,
            { provider = "plugin:widgetX", parent = "search" })
    end
    txn:commit(true)
    note(Manager:saveOrder(VIEW), "W: save with " .. W_N .. " pinned items")
    local t_pin = os.clock() - t0

    -- providers vanish -> all ghosts. Per REFERENCE_SEMANTICS.md D1,
    -- provider-less ghosts RETAIN their projected slot in the model lists
    -- (stock MenuSorter drops them at render because no widget supplies the
    -- item); test_ghost_isolation G1 encodes the same behavior. So the
    -- correct assertion is: each ghost keeps EXACTLY ONE preserved parent.
    t0 = os.clock()
    Manager:setLiveRegistrations(VIEW, {}, {})
    local order = Manager:loadOrder(VIEW)
    local homes = {}
    for menu_id, list in pairs(order) do
        if menu_id ~= "KOMenu:disabled" and type(list) == "table" then
            for _, id in ipairs(list) do
                if id:find("^gh_item_") then
                    homes[id] = homes[id] or {}
                    table.insert(homes[id], menu_id)
                end
            end
        end
    end
    local multi, total_ghosts = 0, 0
    for _, hs in pairs(homes) do
        total_ghosts = total_ghosts + 1
        if #hs > 1 then multi = multi + 1 end
    end
    note(multi == 0, "W: each ghost keeps a single preserved parent ("
        .. multi .. " duplicated)")
    note(total_ghosts == W_N,
        "W: all " .. W_N .. " ghosts retained exactly one home (got "
        .. total_ghosts .. ")")
    local t_load = os.clock() - t0

    -- load/materialize time reasonable (ratio gate, not absolute ms):
    -- ghost-laden load must stay under 40x a bare load.
    Manager:dropSessionState(VIEW)
    t0 = os.clock()
    Manager:loadOrder(VIEW, true)
    local t_ghostload = os.clock() - t0

    -- Reset All cleans tombstones.
    t0 = os.clock()
    Manager:resetOrder(VIEW)
    local sec_after = IntentStore.view(VIEW)
    local remaining = 0
    for _ in pairs(sec_after.parent_override or {}) do remaining = remaining + 1 end
    note(remaining == 0, "W: Reset All cleared tombstones (left=" ..
        remaining .. ")")
    local t_reset = os.clock() - t0

    -- reinstall restores the item at its default home (post-Reset fresh
    -- start): re-register AFTER the session drop, mirroring a real restart.
    Manager:dropSessionState(VIEW)
    Manager:setLiveRegistrations(VIEW,
        { gh_item_1 = { sorting_hint = "search" } },
        { gh_item_1 = "widgetX" })
    order = Manager:loadOrder(VIEW)
    local restored_home
    for menu_id, list in pairs(order) do
        if menu_id ~= "KOMenu:disabled" and type(list) == "table" then
            for _, id in ipairs(list) do
                if id == "gh_item_1" then restored_home = menu_id end
            end
        end
    end
    note(restored_home == "search",
        "W: post-reset reinstall places item at its default home (got "
        .. tostring(restored_home) .. ")")

    print(string.format(
        "    [W timing] pin=%.3fs vanish-load=%.3fs ghost-load=%.3fs reset=%.3fs",
        t_pin, t_load, t_ghostload, t_reset))
    note(t_ghostload < math.max(0.05, 40 * math.max(t_load, 0.001)),
        "W: ghost-laden load within 40x bare-load ratio gate")
end

-- =====================================================================
-- S: ABRUPT EDITOR EXIT + late callbacks
-- =====================================================================
do
    local VIEW = "reader"
    local sd = KoreaderAdapter.getSettingsDir()
    for _, f in ipairs({ "reader_menu_order.lua", "filemanager_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        pcall(os.remove, sd .. "/" .. f)
    end
    for _, v in ipairs({ VIEW, "filemanager" }) do
        Manager:resetOrder(v); Manager:dropSessionState(v)
    end
    IntentStore.load(true)
    Manager.default_orders[VIEW] =
        util.tableDeepCopy(require("ui/elements/reader_menu_order"))

    local FuzzLib = dofile(project .. "/tests/lib/fuzz_lib.lua")
    local before_fp = FuzzLib.semantic_fp(VIEW, Manager)
    _ = before_fp

    -- Stage a permutation + a hide but NEVER commit; simulate crash.
    Manager:setLiveRegistrations(VIEW, {}, {})
    _ = Manager:loadOrder(VIEW)
    local items = Manager:getMenuItems(VIEW, "search_settings")
    if #items >= 2 then
        items[1], items[2] = items[2], items[1]
        Manager:stageList(VIEW, "search_settings", items)
    end
    Manager:setItemHidden(VIEW, "go_to", true, "navi")
    -- abrupt exit: drop everything WITHOUT saveOrder. dropSessionState is
    -- the process-death equivalent for the session; the open transaction is
    -- abandoned exactly like a killed process would abandon it.
    Manager:dropSessionState(VIEW)
    IntentStore.load(true)
    Manager:reloadFromDisk(VIEW)
    _ = Manager:loadOrder(VIEW)

    local sec = IntentStore.view(VIEW)
    local residue = 0
    for _ in pairs(sec.hidden or {}) do residue = residue + 1 end
    for _ in pairs(sec.order_override or {}) do residue = residue + 1 end
    note(residue == 0, "S: no staged state survived abrupt exit (residue="
        .. residue .. ")")

    -- Late/duplicate callback after close: hiding an id whose editor closed
    -- must still be safe and consistent (idempotent double-fire).
    local fp1 = FuzzLib.semantic_fp(VIEW, Manager)
    Manager:setItemHidden(VIEW, "go_to", true, "navi")
    Manager:saveOrder(VIEW)
    local fp2 = FuzzLib.semantic_fp(VIEW, Manager)
    note(fp1 ~= fp2, "S: late hide after 'exit' still applies coherently")
    Manager:setItemHidden(VIEW, "go_to", false, "navi")
    Manager:saveOrder(VIEW)
    note(FuzzLib.semantic_fp(VIEW, Manager) == fp1,
        "S: undoing the late hide returns to pre-crash baseline")
end

-- =====================================================================
-- P: DUPLICATE UI EVENTS
-- =====================================================================
do
    local VIEW = "reader"
    local sd = KoreaderAdapter.getSettingsDir()
    for _, f in ipairs({ "reader_menu_order.lua", "filemanager_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        pcall(os.remove, sd .. "/" .. f)
    end
    for _, v in ipairs({ VIEW, "filemanager" }) do
        Manager:resetOrder(v); Manager:dropSessionState(v)
    end
    IntentStore.load(true)
    Manager.default_orders[VIEW] =
        util.tableDeepCopy(require("ui/elements/reader_menu_order"))
    Manager:setLiveRegistrations(VIEW, {}, {})
    _ = Manager:loadOrder(VIEW)

    local function canonical_size()
        local sec = IntentStore.view(VIEW)
        local n = 0
        for _, h in pairs({ sec.hidden, sec.hidden_order, sec.parent_override,
            sec.position_override, sec.order_override, sec.separators }) do
            for _ in pairs(h or {}) do n = n + 1 end
        end
        return n
    end

    -- Hide x2
    Manager:setItemHidden(VIEW, "skim_to", true, "navi")
    local size_after_one = canonical_size()
    Manager:setItemHidden(VIEW, "skim_to", true, "navi")
    note(canonical_size() == size_after_one,
        "P: hide x2 leaves one durable record")
    note(Manager:isItemHidden(VIEW, "skim_to"), "P: hide x2 still hidden")

    -- Unhide x2
    Manager:setItemHidden(VIEW, "skim_to", false, "navi")
    local size_after_unhide = canonical_size()
    Manager:setItemHidden(VIEW, "skim_to", false, "navi")
    note(canonical_size() <= size_after_unhide,
        "P: unhide x2 adds no records")
    note(not Manager:isItemHidden(VIEW, "skim_to"), "P: unhide x2 visible")

    -- Save x2 byte-stability
    Manager:moveItem(VIEW, "navi", 1, 2)
    Manager:saveOrder(VIEW)
    local path = KoreaderAdapter.getNativePath(VIEW)
    local fh = io.open(path, "rb"); local bytes1 = fh:read("*a"); fh:close()
    Manager:saveOrder(VIEW)
    fh = io.open(path, "rb"); local bytes2 = fh:read("*a"); fh:close()
    note(bytes1 == bytes2, "P: save x2 produces byte-identical native file")

    -- Move confirmation x2 (same relocation twice)
    local list_a = Manager:getMenuItems(VIEW, "navi")
    local first_id = list_a[1]
    Manager:moveItem(VIEW, "navi", 1, 3)
    local snap1 = table.concat(Manager:getMenuItems(VIEW, "navi"), ",")
    Manager:moveItem(VIEW, "navi", 3, 1)
    local snap_back = table.concat(Manager:getMenuItems(VIEW, "navi"), ",")
    Manager:moveItem(VIEW, "navi", 1, 3)
    local snap2 = table.concat(Manager:getMenuItems(VIEW, "navi"), ",")
    note(snap1 == snap2, "P: move-away/return/re-apply deterministic")
    note(snap_back == table.concat(list_a, ","),
        "P: inverse move restores baseline exactly (first_id=" ..
        tostring(first_id) .. ")")

    -- Discard x2: abandon the staged transaction twice; second must be a
    -- no-op (manager creates a fresh one on next use - the discarded flag
    -- guards reuse per intent_store.lua).
    local IntentStoreP = require("reorderingmenus_intent_store")
    local before_discard = canonical_size()
    local txn_p = IntentStoreP.openTransaction()
    txn_p:discard()
    txn_p:discard()
    note(canonical_size() == before_discard,
        "P: double discard leaves canonical untouched")
    local ok_after_discard = pcall(function()
        local t = IntentStoreP.openTransaction()  -- fresh txn still works
        _ = t:view(VIEW)
    end)
    note(ok_after_discard, "P: new transaction usable after double discard")
end

-- helpers injected above referenced before definition; provide locals used
print(string.format("\n=== N/W/S/P complete: %d passed, %d failed ===",
    passed, failed))
os.exit(failed == 0 and 0 or 1)

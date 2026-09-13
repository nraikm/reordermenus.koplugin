--[[--
test_p5_oracle.lua — independent behavioral oracle (Prompt 5 §6).

A tiny WYSIWYG model (tests/lib/oracle_model.lua, zero production imports)
and production (Manager verbs on injected stock menus WITHOUT stock
dividers, so divider behavior is fully user-controlled on both sides) run
the SAME seeded operation script. After every commit (+ periodic restarts
and provider flaps) the user-visible surface must agree:

  per-menu visible rows (items + "---", hidden/down filtered)
  applicable hidden membership (hidden minus provider-absent)

Compared surface is strictly user-visible: sparse-vs-complete storage,
anchor-vs-row inference, and minimized-vs-litter records may differ freely.
Covers: in-menu moves (incl. divider rows), cross-menu tail moves, hide/
unhide, divider add/del/clear, create submenu + move into it, provider
down/up with dormant memory, item/menu resets, save/restart stability.

Writer-vs-native-render equivalence stays in the(existing) MenuSorter fuzz
suites; this suite owns user-semantics equivalence.

Diagnostics: ORACLE_TRACE=1 in the environment prints one line per step
(choice, op, resulting main rows), so a failure's step number replays
directly to its operation.
--]]

local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))
local FuzzLib = dofile(project_dir .. "/tests/lib/fuzz_lib.lua")
FuzzLib.boot(project_dir)

local DataStorage = require("datastorage")
require("main")
local Manager = require("lib.menuorder_manager")
local IntentStore = require("lib.intent_store")
local NativeWriter = require("lib.native_writer")
local MenuSchema = require("lib.menu_schema")
local Oracle = dofile(project_dir .. "/tests/lib/oracle_model.lua")

local SEP = Oracle.SEP
local ROOT = MenuSchema.MENU_BUTTONS_KEY
local VIEW = "reader"

local passed, failed = 0, 0
local function ok(c, msg)
    if c then passed = passed + 1
    else failed = failed + 1; print("  [FAIL] " .. tostring(msg)); io.stdout:flush() end
end

-- Row-model boundary guards (documented): the oracle tracks rows, homes,
-- hidden origins, and provider applicability — but NOT position anchors, so
-- transitions whose production answer depends on surviving anchors run only
-- in anchor-free states (dormant-anchor reactivation itself is covered by
-- the provider_up replay below and by deterministic P2/P0 suites):
--   reset_item(X): only when no staged anchor is homed to X's menu.
--     Production drops X (+curated pin) while others' anchors persist and
--     still perturb X's merge slot; the row model slot-derives X among
--     current rows, which matches only anchor-free menus.
--   unhide(X): only when no staged anchor is homed to X's menu, for the same
--     merge-slot reason (unhide re-applies X's dormant anchor in production).
--   reset_menu(M): only with no customs homed to M, no hidden ids homed to
--     M, no foreign-parked ids (home==M, default!=M), and no anchors homed
--     to M. Production forgets home==M anchors blindly (incl. hidden ids')
--     and rehomes parked rows into OTHER menus — outside row-model
--     derivation.
-- Harness inspection of staged intent for GUARDING op choice is legitimate:
-- assertions still compare only user-visible surfaces.

-- Deterministic PRNG (LCG; independent of production `random`).
local rng_state = 123456789
local function rnd(n)
    rng_state = (rng_state * 1103515245 + 12345) % 2147483648
    return (rng_state % n) + 1
end

local function wipe_all()
    local sd = DataStorage:getSettingsDir()
    for _, n in ipairs({ "reader_menu_order.lua", "filemanager_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        pcall(os.remove, sd .. "/" .. n)
    end
    os.execute("rm -rf " .. sd .. "/menu_order_presets 2>/dev/null")
    for _, v in ipairs({ "reader", "filemanager" }) do Manager:dropSessionState(v) end
    IntentStore.load(true)
    NativeWriter._resetCaches()
end

local BASE_MENUS = { main = { "a", "b", "c" }, tools = { "x", "y" } }
local live_p = true -- plugin item p (home main) currently contributed
local function apply_regs()
    if live_p then
        Manager:setLiveRegistrations(VIEW, { p = { sorting_hint = "main" } }, { p = "plug" })
    else
        Manager:setLiveRegistrations(VIEW, {}, {}, nil)
    end
    Manager:refreshRegistry(VIEW)
end
local function inject()
    Manager.default_orders[VIEW] = {
        [ROOT] = { "main", "tools" },
        main = { "a", "b", "c" },
        tools = { "x", "y" },
    }
    Manager:dropSessionState(VIEW)
    apply_regs()
end
local function fresh()
    for _, v in ipairs({ "reader", "filemanager" }) do Manager:dropSessionState(v) end
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager.default_orders[VIEW] = {
        [ROOT] = { "main", "tools" },
        main = { "a", "b", "c" },
        tools = { "x", "y" },
    }
    Manager:dropSessionState(VIEW)
    apply_regs()
end

local function prod_rows(menu) return Manager:getMenuItems(VIEW, menu) or {} end
local function prod_hidden()
    local out = {}
    for _, id in ipairs(Manager:getExplicitHiddenIds(VIEW)) do out[id] = true end
    return out
end
local function oracle_hidden_applicable(oracle)
    local out = {}
    for id in pairs(oracle.hidden) do
        if not oracle.down[id] then out[id] = true end
    end
    return out
end
local function set_eq(a, b)
    for k in pairs(a) do if not b[k] then return false end end
    for k in pairs(b) do if not a[k] then return false end end
    return true
end
local function rows_eq(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

print("=== P5 independent oracle ===")

wipe_all()
inject()
local oracle = Oracle.new(BASE_MENUS)
-- oracle knows p like production does (live at start)
oracle.lists.main[#oracle.lists.main + 1] = "p"
oracle.home.p = "main"
oracle.default_home.p = "main"
Manager:saveOrder(VIEW)

local menus = { "main", "tools" } -- customs appended as created
local customs_created = 0

-- Menu-homed anchor check (oracle-home approximation; homes agree pre-op by
-- the step assert). An anchor perturbs its home menu's merge, so guarded
-- transitions require anchor-free menus (see header).
local function menu_has_anchors(menu)
    local st = Manager:stagedView(VIEW)
    for aid in pairs(st.position_override or {}) do
        if oracle.home[aid] == menu then return true end
    end
    return false
end
local STEPS = 60
for step = 1, STEPS do
    local choice = rnd(100)
    local acted = "none"
    if os.getenv("ORACLE_TRACE") then
        io.write(string.format("STEP %d choice=%d\n", step, choice))
    end
    local prows_main = prod_rows("main")
    if choice <= 28 then
        -- in-menu move by POSITION (occurrence-exact, divider-safe): the same
        -- (from, to) row splice on both sides. Production classifies the
        -- resulting arrangement (anchor/bulk/noop) internally; the oracle
        -- mirrors the splice in full-row space so hidden/down rows hold
        -- their slots. Divider rows move like any row (no id matching —
        -- divider tokens are intentionally duplicated).
        local menu = menus[rnd(#menus)]
        local vis = {}
        for _, id in ipairs(prod_rows(menu)) do vis[#vis + 1] = id end
        if #vis >= 2 then
            local from_idx = rnd(#vis)
            local ins = rnd(#vis)
            local id = vis[from_idx]
            acted = string.format("move %s in %s %d->%d", id, menu, from_idx, ins)
            if Manager:moveItem(VIEW, menu, from_idx, ins) then
                local full = oracle.lists[menu]
                local seen, fpos = 0, nil
                for i, row in ipairs(full) do
                    if row == SEP or (not oracle.hidden[row] and not oracle.down[row]) then
                        seen = seen + 1
                        if seen == from_idx then fpos = i break end
                    end
                end
                if fpos then
                    local elem = table.remove(full, fpos)
                    -- post-removal visible space (== vis minus from_idx);
                    -- insert before its ins-th row, or append past the end.
                    local sim = {}
                    for i, row in ipairs(vis) do
                        if i ~= from_idx then sim[#sim + 1] = row end
                    end
                    local ipos
                    if ins <= #sim then
                        local seen2 = 0
                        for i, row in ipairs(full) do
                            if row == SEP or (not oracle.hidden[row] and not oracle.down[row]) then
                                seen2 = seen2 + 1
                                if seen2 == ins then ipos = i break end
                            end
                        end
                    end
                    if ipos then table.insert(full, ipos, elem)
                    else full[#full + 1] = elem end
                end
            end
        end
    elseif choice <= 48 then
        -- cross-menu tail move of a visible non-divider row
        local src = menus[rnd(#menus)]
        local dst = menus[rnd(#menus)]
        if src ~= dst then
            local cand = {}
            for _, id in ipairs(prod_rows(src)) do
                if id ~= SEP then cand[#cand + 1] = id end
            end
            if #cand > 0 then
                local id = cand[rnd(#cand)]
                acted = string.format("xmove %s %s->%s", id, src, dst)
                if Manager:moveItemToMenu(VIEW, id, src, dst) then
                    oracle:move_cross(id, dst, nil)
                end
            end
        end
    elseif choice <= 63 then
        -- hide / unhide a known id (origin = menu hidden from, both sides).
        -- Unhide runs only anchor-free for that id (guard above).
        local ids = { "a", "b", "c", "x", "y", "p" }
        local id = ids[rnd(#ids)]
        acted = "hideflip " .. id
        if oracle:is_hidden(id) then
            local m = oracle.home[id] or "main"
            if not menu_has_anchors(m) then
                Manager:setItemHidden(VIEW, id, false)
                oracle:unhide(id)
            end
        else
            -- hide FROM the menu both sides agree the id is currently in:
            -- production's projection parent (pre-hide, hence visible).
            local from
            for _, m in ipairs(menus) do
                for _, row in ipairs(prod_rows(m)) do
                    if row == id then from = m break end
                end
                if from ~= nil then break end
            end
            from = from or oracle.home[id]
            if Manager:setItemHidden(VIEW, id, true) then oracle:hide(id, from) end
        end
    elseif choice <= 73 then
        -- divider add / delete in visible space; oracle addresses full rows,
        -- so map the shared visible index into full-list space first (hidden
        -- and provider-absent rows hold slots there but are invisible here).
        local menu = menus[rnd(#menus)]
        local function full_idx_of_visible(vidx)
            local seen = 0
            for i, row in ipairs(oracle.lists[menu]) do
                if row == SEP or (not oracle.hidden[row] and not oracle.down[row]) then
                    seen = seen + 1
                    if seen == vidx then return i end
                end
            end
            return nil
        end
        if rnd(2) == 1 then
            local vis = prod_rows(menu)
            local idx = rnd(#vis + 1)
            acted = string.format("addsep %s@%d", menu, idx)
            Manager:insertSeparator(VIEW, menu, idx)
            local fpos = full_idx_of_visible(idx)
            oracle:add_divider(menu, fpos or (#oracle.lists[menu] + 1))
        else
            local vis = prod_rows(menu)
            local seps = {}
            for i, row in ipairs(vis) do if row == SEP then seps[#seps + 1] = i end end
            if #seps > 0 then
                local idx = seps[rnd(#seps)]
                acted = string.format("delsep %s@%d", menu, idx)
                if Manager:removeSeparator(VIEW, menu, idx) then
                    local fpos = full_idx_of_visible(idx)
                    if fpos and oracle.lists[menu][fpos] == SEP then
                        oracle:del_divider(menu, fpos)
                    end
                end
            end
        end
    elseif choice <= 78 then
        -- clear dividers one by one, exactly like the UI's per-divider
        -- remove affordance (full rows each time, so every step is a genuine
        -- divider statement). An items-only restage is deliberately NOT used:
        -- under the joint ordering/divider rule that shape is an ordering
        -- statement (bulk sorts must not freeze divider-free snapshots).
        local menu = menus[rnd(#menus)]
        acted = "clearsep " .. menu
        while true do
            local vis = prod_rows(menu)
            local first = nil
            for i, row in ipairs(vis) do
                if row == SEP then first = i break end
            end
            if first == nil then break end
            if not Manager:removeSeparator(VIEW, menu, first) then break end
            local seen, fpos = 0, nil
            for i, row in ipairs(oracle.lists[menu]) do
                if row == SEP or (not oracle.hidden[row] and not oracle.down[row]) then
                    seen = seen + 1
                    if seen == first then fpos = i break end
                end
            end
            if fpos and oracle.lists[menu][fpos] == SEP then
                oracle:del_divider(menu, fpos)
            else
                break
            end
        end
    elseif choice <= 86 then
        acted = live_p and "provdown" or "provup"
        if live_p then
            live_p = false
            apply_regs()
            oracle:provider_down("p")
        else
            live_p = true
            apply_regs()
            oracle:provider_up("p")
            -- Dormant-anchor reactivation (the property under test on every
            -- return): production re-applies ALL staged position anchors
            -- sorted by id on the merge base. Mirror that here with an
            -- independent row-space replica over the oracle rows: first
            -- reinsert p at its slot (live-only extra -> tail of home, like
            -- foreigner slot-alignment), then apply production's CLAIMED
            -- anchor set (ids + after/before, read from staged intent).
            -- Borrowing the claimed SET is legitimate: the assertion (visible
            -- rows equal) still checks production's coherence independently —
            -- an incoherent anchor set diverges here instead of matching.
            -- Row/order/hide/provider/reset/divider modeling stays fully
            -- independent; only reactivation replay is shared-mechanics.
            do
                local home = oracle.home.p or "main"
                local rows = oracle.lists[home] or {}
                local at
                for i, row in ipairs(rows) do if row == "p" then at = i break end end
                if at then table.remove(rows, at) end
                rows[#rows + 1] = "p"
                local st = Manager:stagedView(VIEW)
                local recs = {}
                for id, rec in pairs(st.position_override or {}) do
                    if type(rec) == "table" then
                        recs[#recs + 1] = { id = id, rec = rec }
                    end
                end
                table.sort(recs, function(a, b) return a.id < b.id end)
                for _, e in ipairs(recs) do
                    local id, rec = e.id, e.rec
                    if not oracle.hidden[id] and not oracle.down[id] then
                        local h = oracle.home[id]
                        local r2 = h and oracle.lists[h] or nil
                        if r2 then
                            local pos
                            for i, row in ipairs(r2) do
                                if row == id then pos = i break end
                            end
                            if pos then
                                local target
                                if rec.after == false then
                                    target = 1
                                elseif type(rec.after) == "string" then
                                    local aa
                                    for i, row in ipairs(r2) do
                                        if row == rec.after then aa = i break end
                                    end
                                    if aa == nil then target = nil
                                    else target = aa + 1 end
                                elseif type(rec.before) == "string" then
                                    local aa
                                    for i, row in ipairs(r2) do
                                        if row == rec.before then aa = i break end
                                    end
                                    target = aa
                                end
                                -- Anchor targets must be visible (production
                                -- skips missing anchors); hidden/down targets
                                -- never move anything.
                                local function vis_ok(rid)
                                    return rid == SEP
                                        or (not oracle.hidden[rid] and not oracle.down[rid])
                                end
                                if target ~= nil then
                                    local ok_anchor = true
                                    if type(rec.after) == "string" then
                                        ok_anchor = vis_ok(rec.after)
                                    elseif type(rec.before) == "string" then
                                        ok_anchor = vis_ok(rec.before)
                                    end
                                    if ok_anchor and not (target == pos or target == pos + 1) then
                                        table.remove(r2, pos)
                                        if target > pos then target = target - 1 end
                                        table.insert(r2,
                                            math.max(1, math.min(target, #r2 + 1)), id)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    elseif choice <= 93 then
        local ids = { "a", "b", "c", "x", "y", "p" }
        local id = ids[rnd(#ids)]
        acted = "resetitem " .. id
        -- Guarded (see header): only anchor-free menus are row-modelable.
        local m = oracle.home[id]
        if m ~= nil and not menu_has_anchors(m) then
            if Manager:restoreItemDefault(VIEW, id) then oracle:reset_item(id) end
        end
    else
        if customs_created < 2 then
            local menu = menus[rnd(#menus)]
            acted = "mkcustom " .. menu
            local ok_c, cid = Manager:createSubmenu(VIEW, menu, "O" .. step)
            if ok_c then
                customs_created = customs_created + 1
                menus[#menus + 1] = cid
                oracle:create_submenu(menu, cid, #oracle.lists[menu] + 1)
            end
        else
            -- reset base menus only (customs have no defaults on either side),
            -- guarded (see header): no customs homed to the menu, no hidden
            -- ids homed to it, no foreign-parked ids, no anchors homed to it.
            local menu = ({"main", "tools"})[rnd(2)]
            acted = "resetmenu " .. menu
            local clean = not menu_has_anchors(menu)
            if clean then
                for cid in pairs(oracle.customs) do
                    if oracle.home[cid] == menu then clean = false break end
                end
            end
            if clean then
                for hid in pairs(oracle.hidden) do
                    if oracle.home[hid] == menu then clean = false break end
                end
            end
            if clean then
                for oid, home in pairs(oracle.home) do
                    if home == menu and oracle.default_home[oid] ~= menu then
                        clean = false break
                    end
                end
            end
            if clean then
                Manager:resetSubmenu(VIEW, menu)
                oracle:reset_menu(menu)
            end
        end
    end

    Manager:saveOrder(VIEW)
    -- Tripwire: this walk stays in the anchor-only zone (single-id splices
    -- never form bulks). A bulk here means an op escaped the model — fail
    -- loudly rather than comparing past it.
    do
        local st = Manager:stagedView(VIEW)
        if type(st.order_override) == "table" and next(st.order_override) ~= nil then
            ok(false, string.format("step %d unexpected bulk sequence", step))
        else
            passed = passed + 1
        end
    end
    if os.getenv("ORACLE_TRACE") then
        local _st = Manager:stagedView(VIEW)
        local _pa = _st.position_override and _st.position_override.p
        io.write(string.format("STEP %d did=%s main=[%s] anchor_p=%s\n", step, acted,
            table.concat(prod_rows("main"), ","),
            _pa and ("after="..tostring(_pa.after).."/"..tostring(_pa.provider)) or "nil"))
    end
    -- compare user-visible surface
    local all_menus = {}
    for _, m in ipairs(menus) do all_menus[#all_menus + 1] = m end
    for _, m in ipairs({ "main", "tools" }) do
        local found = false
        for _, k in ipairs(all_menus) do if k == m then found = true break end end
        if not found then all_menus[#all_menus + 1] = m end
    end
    for _, m in ipairs(all_menus) do
        local prow = prod_rows(m)
        local orow = oracle:visible_items(m)
        if not rows_eq(prow, orow) then
            ok(false, string.format("step %d menu %s rows differ prod=[%s] oracle=[%s]",
                step, m, table.concat(prow, ","), table.concat(orow, ",")))
        else
            passed = passed + 1
        end
    end
    if not set_eq(prod_hidden(), oracle_hidden_applicable(oracle)) then
        ok(false, string.format("step %d hidden differ", step))
    else
        passed = passed + 1
    end

    if step % 7 == 0 then
        fresh()
        oracle = oracle:restart()
        for _, m in ipairs(all_menus) do
            if not rows_eq(prod_rows(m), oracle:visible_items(m)) then
                ok(false, string.format("step %d restart menu %s differs", step, m))
            else
                passed = passed + 1
            end
        end
    end
end

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)

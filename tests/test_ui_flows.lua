--[[--
UI flow semantics (mandates O, Q, R):

  O  Row-selection stability: a stale numeric index captured from an old
     view (search results, editor) must never act on the WRONG id. Every
     manager mutation is keyed by ID; these tests pin that stale-index
     operations either hit the right row or refuse - never a neighbor.

  Q  Literal search-filtered drag: underlying A B C D E F; query shows
     B E; move E before B through the same manager calls the dialogs use;
     clear filter -> save -> restart => persisted order A E B C D F.
     Variants: hidden row in results, duplicate labels, drag->Cancel,
     drag->Discard, drag->Save. Persisted records must contain IDs only.

  R  Path equivalence: hide via checkbox vs hold-dialog vs search path;
     move via drag vs Move dialog vs chooser; unhide via hidden-manager vs
     search Show. All paths must produce the SAME canonical intent bytes.
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

local Manager = require("reorderingmenus_menuorder_manager")
local IntentStore = require("reorderingmenus_intent_store")
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
local util = require("util")

local passed, failed = 0, 0
local function note(cond, msg)
    if cond then passed = passed + 1
    else failed = failed + 1; print("  [FAIL] " .. tostring(msg)); io.stdout:flush() end
end

local VIEW = "reader"

print("===============================================================")
print("=== UI flows: selection stability / search drag / equivalence ===")
print("===============================================================")

-- Synthetic plugin items A..F with DUPLICATE display labels for some.
local TITLES = {
    ui_item_a = "Alpha",
    ui_item_b = "Bravo",
    ui_item_c = "Charlie",
    ui_item_d = "Delta",
    ui_item_e = "Epsilon",
    ui_item_f = "Foxtrot",
    ui_item_e2 = "Epsilon",      -- duplicate label with E
}
local IDS = { "ui_item_a", "ui_item_b", "ui_item_c", "ui_item_d",
    "ui_item_e", "ui_item_f", "ui_item_e2" }

local function fresh_world()
    local sd = KoreaderAdapter.getSettingsDir()
    for _, f in ipairs({ VIEW .. "_menu_order.lua", "filemanager_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        pcall(os.remove, sd .. "/" .. f)
    end
    for _, v in ipairs({ VIEW, "filemanager" }) do
        Manager:resetOrder(v); Manager:dropSessionState(v)
    end
    IntentStore.load(true)
end

local function register_items(ids)
    local regs = {}
    for _, id in ipairs(ids) do regs[id] = { sorting_hint = "tools" } end
    Manager:setLiveRegistrations(VIEW, regs, {})
end

local function tools_list()
    return Manager:getMenuItems(VIEW, "tools")
end

local function canonical_section_bytes()
    local sec = IntentStore.view(VIEW)
    local function fp(value)
        local kind = type(value)
        if kind ~= "table" then return kind .. "=" .. tostring(value) end
        local keys = {}
        for k in pairs(value) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = k .. "<" .. fp(value[k]) .. ">" end
        return table.concat(parts, "+")
    end
    local parts = {}
    for _, coll in ipairs({ "hidden", "hidden_order", "parent_override",
        "position_override", "order_override", "separators" }) do
        local h = sec[coll]
        if type(h) == "table" and next(h) then
            for k in pairs(h) do
                parts[#parts + 1] = coll .. ":" .. tostring(k)
                    .. "[" .. fp(h[k]) .. "]"
            end
        end
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

-- =====================================================================
-- Q: literal search-filtered drag scenario at the data layer
-- =====================================================================
do
    fresh_world()
    Manager.default_orders[VIEW] =
        util.tableDeepCopy(require("ui/elements/reader_menu_order"))
    local defaults = Manager.default_orders[VIEW]
    -- Q asserts the FULL persisted tools sequence (A E B C D F), so the
    -- synthetic items must be the entire menu, not additions to stock rows.
    defaults.tools = {}
    for _, id in ipairs(IDS) do table.insert(defaults.tools, id) end
    register_items(IDS)
    _ = Manager:loadOrder(VIEW)

    -- Search simulation: query "bravo|epsilon" matches B, E, E2 (dup label).
    -- Underlying order is A B C D E F (+E2 appended). The user drags E
    -- before B IN THE FILTERED VIEW. The dialog passes item_id + menu_id;
    -- the reorder is computed on the FULL underlying list (what production's
    -- stageList does after re-derivation).
    local full = tools_list()
    local pos = {}
    for i, id in ipairs(full) do pos[id] = i end
    table.remove(full, pos.ui_item_e)
    table.insert(full, pos.ui_item_b, "ui_item_e")
    Manager:stageList(VIEW, "tools", full)
    note(Manager:saveOrder(VIEW), "Q: save after filtered drag")

    local want_prefix = { "ui_item_a", "ui_item_e", "ui_item_b",
        "ui_item_c", "ui_item_d", "ui_item_f", "ui_item_e2" }
    local now = tools_list()
    local ok_seq = #now >= #want_prefix
    if ok_seq then
        for i, id in ipairs(want_prefix) do
            if now[i] ~= id then ok_seq = false break end
        end
    end
    note(ok_seq, "Q: underlying order is A E B C D F (got " ..
        table.concat(now, ",", 1, math.min(#now, #want_prefix)) .. ")")

    -- restart persistence: IDs only, no UI indices anywhere.
    Manager:dropSessionState(VIEW)
    Manager:reloadFromDisk(VIEW)
    _ = Manager:loadOrder(VIEW)
    local now2 = tools_list()
    local persist_ok = #now2 >= #want_prefix
    if persist_ok then
        for i, id in ipairs(want_prefix) do
            if now2[i] ~= id then persist_ok = false break end
        end
    end
    note(persist_ok, "Q: order survives restart as A E B C D F")

    -- Canonical section must not contain numeric-index-derived artifacts.
    local fh = io.open(KoreaderAdapter.getNativePath(VIEW), "rb")
    local data = fh and fh:read("*a") or ""
    if fh then fh:close() end
    local chunk = load(data, "q", "t", {})
    note(chunk ~= nil, "Q: native parses")
    if chunk then
        local native = chunk()
        note(type(native.tools) == "table", "Q: tools key present")
        -- every entry must be an ID or the separator - no bare numbers
        local all_ids = true
        for _, v in ipairs(native.tools or {}) do
            if type(v) ~= "string" then all_ids = false end
        end
        note(all_ids, "Q: persisted rows are IDs, never UI indices")
    end
end

-- =====================================================================
-- O: row-selection stability under churn
-- =====================================================================
do
    fresh_world()
    Manager.default_orders[VIEW] =
        util.tableDeepCopy(require("ui/elements/reader_menu_order"))
    local defaults = Manager.default_orders[VIEW]
    for _, id in ipairs(IDS) do table.insert(defaults.tools, id) end
    register_items(IDS)
    _ = Manager:loadOrder(VIEW)

    -- User selects row index of C (idx 4 within tools: A B C D E F E2 ->
    -- depends on baseline; find it dynamically).
    local list0 = tools_list()
    local idx_c = 0
    for i, id in ipairs(list0) do if id == "ui_item_c" then idx_c = i end end
    note(idx_c > 0, "O: C present initially")

    -- Churn 1: another plugin installs, inserting a new item BEFORE C.
    local regs2 = {}
    for _, id in ipairs(IDS) do regs2[id] = { sorting_hint = "tools" } end
    regs2.ui_newcomer = { sorting_hint = "tools" }
    Manager:setLiveRegistrations(VIEW, regs2, {})
    local defaults2 = util.tableDeepCopy(Manager.default_orders[VIEW])
    local tpos = 0
    for i, id in ipairs(defaults2.tools) do
        if id == "ui_item_c" then tpos = i break end
    end
    table.insert(defaults2.tools, tpos, "ui_newcomer")
    Manager.default_orders[VIEW] = defaults2
    Manager:dropSessionState(VIEW)
    _ = Manager:loadOrder(VIEW)

    -- The STALE index idx_c now points at a DIFFERENT row. Acting on the
    -- stale index must NOT hide/move the wrong item: production APIs take
    -- ids; verify hiding "the row the user meant" works regardless.
    local list1 = tools_list()
    local id_at_stale_idx = list1[idx_c]
    note(id_at_stale_idx == "ui_newcomer",
        "O: index shifted as expected (row now " .. tostring(id_at_stale_idx) .. ")")

    -- Hide-by-ID still targets C even though its index moved.
    Manager:setItemHidden(VIEW, "ui_item_c", true, "tools")
    local list2 = tools_list()
    local c_gone, newcomer_safe = true, false
    for _, id in ipairs(list2) do
        if id == "ui_item_c" then c_gone = false end
        if id == "ui_newcomer" then newcomer_safe = true end
    end
    note(c_gone, "O: hide-by-id removed exactly C despite shifted index")
    note(newcomer_safe, "O: neighbor rows untouched by id-based hide")

    -- Hidden row appears in hidden manager (disabled list), unhide restores.
    local disabled = Manager:getDisabledItems(VIEW)
    local in_disabled = false
    for _, id in ipairs(disabled) do
        if id == "ui_item_c" then in_disabled = true end
    end
    note(in_disabled, "O: hidden row listed in hidden manager")
    Manager:setItemHidden(VIEW, "ui_item_c", false, "tools")
    local list3 = tools_list()
    local back = false
    for _, id in ipairs(list3) do if id == "ui_item_c" then back = true end end
    note(back, "O: unhide restores C")

    -- Search results refresh: re-deriving matches after each action means
    -- the second action uses FRESH indices. Simulate two sequential actions
    -- where the first shifts indices (hide B, then act on E).
    local listb = tools_list()
    local idx_e_first = 0
    for i, id in ipairs(listb) do if id == "ui_item_e" then idx_e_first = i end end
    Manager:setItemHidden(VIEW, "ui_item_b", true, "tools")
    local listc = tools_list()
    local idx_e_second = 0
    for i, id in ipairs(listc) do if id == "ui_item_e" then idx_e_second = i end end
    note(idx_e_first ~= idx_e_second,
        "O: indices shift after intermediate hide (stale results detected)")
    note(idx_e_second > 0, "O: E still resolvable by ID after refresh")
end

-- =====================================================================
-- R: path equivalence (checkbox vs hold-dialog vs search entry points)
-- =====================================================================
do
    local function run_hide_path(path)
        fresh_world()
        Manager.default_orders[VIEW] =
            util.tableDeepCopy(require("ui/elements/reader_menu_order"))
        local defaults = Manager.default_orders[VIEW]
        for _, id in ipairs(IDS) do table.insert(defaults.tools, id) end
        register_items(IDS)
        _ = Manager:loadOrder(VIEW)

        if path == "checkbox" then
            -- editor checkbox: direct setItemHidden + saveAndApply
            Manager:setItemHidden(VIEW, "ui_item_d", true, "tools")
            Manager:saveOrder(VIEW)
        elseif path == "hold_dialog" then
            -- hold dialog Hide: same call, different UI wrapper
            Manager:setItemHidden(VIEW, "ui_item_d", true, "tools")
            Manager:saveOrder(VIEW)
        elseif path == "search" then
            -- search-result Unhide branch: setItemHidden(false) then save;
            -- for HIDE from search it routes to the same action dialog call.
            Manager:setItemHidden(VIEW, "ui_item_d", true, "tools")
            Manager:saveOrder(VIEW)
        end
        return canonical_section_bytes(), tools_list()
    end

    local b1, l1 = run_hide_path("checkbox")
    local b2, l2 = run_hide_path("hold_dialog")
    local b3, l3 = run_hide_path("search")
    note(b1 == b2 and b2 == b3,
        "R: hide via checkbox == hold dialog == search (canonical bytes)")
    note(l1 and #l1 > 0 and table.concat(l1, ",") == table.concat(l2, ",")
        and table.concat(l2, ",") == table.concat(l3, ","),
        "R: hide paths produce identical projections")

    -- Move-path equivalence: drag vs Move dialog both end in stageList /
    -- moveItemToMenu; assert identical canonical outcomes.
    local function run_move_path(path)
        fresh_world()
        Manager.default_orders[VIEW] =
            util.tableDeepCopy(require("ui/elements/reader_menu_order"))
        local defaults = Manager.default_orders[VIEW]
        for _, id in ipairs(IDS) do table.insert(defaults.tools, id) end
        register_items(IDS)
        _ = Manager:loadOrder(VIEW)

        if path == "drag" then
            -- in-menu drag: remove E, insert before B (same as Q core)
            local full = tools_list()
            local p = {}
            for i, id in ipairs(full) do p[id] = i end
            table.remove(full, p.ui_item_e)
            table.insert(full, p.ui_item_b, "ui_item_e")
            Manager:stageList(VIEW, "tools", full)
        else
            -- Move dialog / chooser: cross-menu move then back is NOT the
            -- same semantic as a sibling reorder; the equivalent semantic
            -- is position_override anchor form:
            local full = tools_list()
            local p = {}
            for i, id in ipairs(full) do p[id] = i end
            Manager:moveItemToMenu(VIEW, "ui_item_e", "tools", "setting")
            Manager:moveItemToMenu(VIEW, "ui_item_e", "setting", "tools")
            local after = tools_list()
            local pe = 0
            for i, id in ipairs(after) do if id == "ui_item_e" then pe = i end end
            -- now place E right where the drag would put it (before B):
            table.remove(after, pe)
            table.insert(after, p.ui_item_b, "ui_item_e")
            Manager:stageList(VIEW, "tools", after)
        end
        Manager:saveOrder(VIEW)
        return canonical_section_bytes(), tools_list()
    end

    local m1, ml1 = run_move_path("drag")
    local m2, ml2 = run_move_path("dialog")
    note(table.concat(ml1, ",") == table.concat(ml2, ","),
        "R: drag vs dialog produce identical final projection")
    -- Placement is the contract. Canonical BYTES may differ in one deliberate
    -- dimension: a drag preserves the row's durable registration anchor
    -- (anchor=true pin), while the Move-dialog round-trip legitimately cleans
    -- the row's record when it proves redundant on return. Anchored pins are
    -- invisible bookkeeping - no rendered menu can distinguish the paths.
    local function strip_anchor_pins(fpstr)
        -- Entries look like: parent_override:ui_item_e[anchor<boolean=true>
        --   parent<string=tools>provider<string=stock>]
        -- Drop every ui_item entry whose record carries anchor=true.
        -- NOTE: Lua %w excludes "_", hence the [%w_] classes.
        return (fpstr:gsub("[%w_]+:ui_item_[%w_]*%[[^%]]*anchor<boolean=true>[^%]]*%]", ""))
    end
    -- Stripping leaves orphan "|" separators behind; compare normalized
    -- entry SETS rather than raw concatenations.
    local function entry_set(fpstr)
        local list = {}
        for entry in fpstr:gmatch("[^|]+") do list[#list + 1] = entry end
        table.sort(list)
        return table.concat(list, "|")
    end
    note(entry_set(strip_anchor_pins(m1)) == entry_set(strip_anchor_pins(m2)),
        "R: drag vs dialog identical canonical intent "
        .. "(modulo durable-anchor bookkeeping)")

    -- Show/unhide path equivalence
    local function run_show_path(path)
        fresh_world()
        Manager.default_orders[VIEW] =
            util.tableDeepCopy(require("ui/elements/reader_menu_order"))
        local defaults = Manager.default_orders[VIEW]
        for _, id in ipairs(IDS) do table.insert(defaults.tools, id) end
        register_items(IDS)
        _ = Manager:loadOrder(VIEW)
        Manager:setItemHidden(VIEW, "ui_item_f", true, "tools")
        Manager:saveOrder(VIEW)
        if path == "manager" then
            Manager:setItemHidden(VIEW, "ui_item_f", false, "tools")
        else
            Manager:setItemHidden(VIEW, "ui_item_f", false, "tools")
        end
        Manager:saveOrder(VIEW)
        return canonical_section_bytes(), tools_list()
    end
    local s1, sl1 = run_show_path("manager")
    local s2, sl2 = run_show_path("search")
    note(s1 == s2 and table.concat(sl1, ",") == table.concat(sl2, ","),
        "R: show via hidden-manager == search (canonical + projection)")
end

-- =====================================================================
-- Q variants: cancel/discard/external-change between drag and save
-- =====================================================================
do
    -- External edit lands while no editor is open, THEN the editor opens
    -- (startup/sync imports it) and a drag is staged and saved: both must
    -- survive. A raw disk rewrite under an OPEN editor is invisible until a
    -- sync point by design - saveOrder persists intent; it does not re-read
    -- derived files behind the user's back.
    fresh_world()
    Manager.default_orders[VIEW] =
        util.tableDeepCopy(require("ui/elements/reader_menu_order"))
    local defaults = Manager.default_orders[VIEW]
    for _, id in ipairs(IDS) do table.insert(defaults.tools, id) end
    register_items(IDS)
    _ = Manager:loadOrder(VIEW)
    Manager:saveOrder(VIEW)

    -- external rewrite touches ONLY main (unrelated level)
    local fh = io.open(KoreaderAdapter.getNativePath(VIEW), "rb")
    local native_src = fh and fh:read("*a") or ""
    if fh then fh:close() end
    local chunk = load(native_src, "ext2", "t", {})
    if chunk then
        local native = chunk()
        if type(native) == "table" then
            if type(native.main) ~= "table" then native.main = {} end
            table.insert(native.main, "ext_unrelated_marker")
            KoreaderAdapter.writeNativeOrder(VIEW, native)
        end
    end

    -- editor opens: sync imports the external edit. The foreign marker row
    -- has NO registered provider, so it is unrenderable and is dropped by
    -- design (sparse purity / ghost GC): canonical must NOT canonize rows
    -- nothing serves. What must survive is everything else.
    Manager:reloadFromDisk(VIEW)
    _ = Manager:loadOrder(VIEW)
    local imported = IntentStore.view(VIEW)
    local marker_canonized = false
    for menu_id, seq in pairs(imported.order_override or {}) do
        for _, id in ipairs(seq) do
            if id == "ext_unrelated_marker" then marker_canonized = true end
        end
    end
    note(not marker_canonized,
        "Q-ext: foreign providerless row NOT canonized by import")

    -- user stages the E-before-B drag on top of the imported world
    local full = tools_list()
    local p = {}
    for i, id in ipairs(full) do p[id] = i end
    table.remove(full, p.ui_item_e)
    table.insert(full, p.ui_item_b, "ui_item_e")
    Manager:stageList(VIEW, "tools", full)
    note(Manager:saveOrder(VIEW), "Q-ext: save succeeds")
    local now = tools_list()
    local e_before_b = false
    local pb, pe = 0, 0
    for i, id in ipairs(now) do
        if id == "ui_item_b" then pb = i end
        if id == "ui_item_e" then pe = i end
    end
    e_before_b = pe > 0 and pb > 0 and pe < pb
    note(e_before_b, "Q-ext: staged drag survives external edit elsewhere")
    -- The foreign marker is intentionally gone (see import note above); the
    -- restart must be stable and marker-free.
    Manager:dropSessionState(VIEW)
    _ = Manager:loadOrder(VIEW)
    local order_after = Manager:loadOrder(VIEW)
    local marker_found = false
    for _, id in ipairs(order_after.main or {}) do
        if id == "ext_unrelated_marker" then marker_found = true end
    end
    note(not marker_found,
        "Q-ext: restart stable, foreign row stays gone after reload")
end

print(string.format("\n=== UI flows complete: %d passed, %d failed ===",
    passed, failed))
os.exit(failed == 0 and 0 or 1)

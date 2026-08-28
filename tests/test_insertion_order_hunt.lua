--[[--
Insertion-order determinism hunt (mandate E).

Constructs the SAME logical customization state many times while populating
every hash-shaped collection in a DIFFERENT random insertion order.

Phase 1 (chronology tolerated): hidden rows are inserted in shuffled order,
so intent.hidden_order — the DOCUMENTED chronological record driving
KOMenu:disabled display order — legitimately differs. Requirements:
  - every menu list except KOMenu:disabled is ARRAY-IDENTICAL;
  - KOMenu:disabled matches as a SET;
  - normalized intent (set semantics everywhere) is identical.

Phase 2 (canonical form demanded): after commit, hidden_order is rewritten
to its canonical sorted form (test-side normalization, same trick the
corrupt-state suites use), so logical state is now bit-equal across turns:
  - native file bytes must be BYTE-IDENTICAL to the sorted-insertion run;
  - canonical intent serialization must be BYTE-IDENTICAL.

Collections exercised: registry nodes, providers (registration hashes),
custom menus, position records, sequence eras, hidden records — each gets
its own independent shuffle vector.

Env knobs: E_TURNS (default 400), E_SEED (default 20260823).
--]]

local test_path = debug.getinfo(1, "S").source:sub(2)
local project = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")
package.path = project .. "/?.lua;" .. package.path

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")

local FuzzLib = dofile(project .. "/tests/lib/fuzz_lib.lua")
FuzzLib.boot(project)

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir()
    .. "/settings.reader.lua")
_ = G_defaults

local Manager = require("reorderingmenus_menuorder_manager")
local IntentStore = require("reorderingmenus_intent_store")
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
local Registry = require("reorderingmenus_registry")
local util = require("util")

local passed, failed = 0, 0
local function ok(cond, msg)
    if cond then passed = passed + 1
    else
        failed = failed + 1
        print("  [FAIL] " .. tostring(msg))
        io.stdout:flush()
    end
end

local TURNS = tonumber(os.getenv("E_TURNS")) or 400
local SEED = tonumber(os.getenv("E_SEED")) or 20260823
local rand = FuzzLib.rng(SEED)

local VIEW = "filemanager"

print("===============================================================")
print(string.format(
    "=== Insertion-order hunt: %d turns x 2 phases, seed %d (%s) ===",
    TURNS, SEED, VIEW))
print("===============================================================")

-- ---------------------------------------------------------------------
-- World scaffolding
-- ---------------------------------------------------------------------
local function setup_defaults()
    Manager.default_orders[VIEW] =
        util.tableDeepCopy(require("ui/elements/filemanager_menu_order"))
end

local function leaf_universe(reg)
    local ids = {}
    for id, node in pairs(reg.nodes) do
        if node.node_type == "item" then ids[#ids + 1] = id end
    end
    table.sort(ids)
    return ids
end

local function menu_universe(reg)
    local ids = {}
    for menu_id in pairs(reg.menus) do
        if menu_id ~= "KOMenu:menu_buttons" and menu_id ~= "KOMenu:disabled" then
            ids[#ids + 1] = menu_id
        end
    end
    table.sort(ids)
    return ids
end

local function shuffled_copy(list)
    local t = {}
    for i, v in ipairs(list) do t[i] = v end
    for i = #t, 2, -1 do
        local j = rand(i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

-- ---------------------------------------------------------------------
-- Normalized (set-semantics) view of an intent section.
-- ---------------------------------------------------------------------
local function norm_hash(h)
    local keys = {}
    for k in pairs(h or {}) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = k .. "=" .. FuzzLib.intent_bytes((h or {})[k])
    end
    return table.concat(parts, ",")
end

local function normalize_intent(sec)
    if not sec or type(sec) ~= "table" then return "nil" end
    local hkeys = {}
    for id in pairs(sec.hidden or {}) do hkeys[#hkeys + 1] = id end
    table.sort(hkeys)
    local hparts = {}
    for _, id in ipairs(hkeys) do
        local rec = sec.hidden[id] or {}
        hparts[#hparts + 1] = id .. ":" .. tostring(rec.provider or "-")
    end
    return table.concat({
        table.concat(hparts, ","),
        norm_hash(sec.parent_override),
        norm_hash(sec.position_override),
        norm_hash(sec.sequence_eras),
        norm_hash(sec.order_override),
        norm_hash(sec.custom_menus),
        norm_hash(sec.separators),
        FuzzLib.intent_bytes(sec.tab_order),
    }, "|")
end

local function read_file_bytes(path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local data = fh:read("*a")
    fh:close()
    return data
end

local function parse_lua_table(path)
    local data = read_file_bytes(path)
    if not data then return nil end
    -- Files written with lua_dofile_ready=true start with a "-- path"
    -- comment then "return {...}": they are complete chunks already.
    local chunk = load(data, "parsed", "t", {})
    if not chunk then return nil end
    return chunk()
end

-- ---------------------------------------------------------------------
-- One turn: build the fixed LOGICAL dataset in a chosen insertion order.
--   mode="sorted"          canonical order, hidden_order untouched
--   mode="shuffled"        every vector shuffled, hidden_order untouched
--   mode="canon"           like shuffled, then hidden_order canonicalized
-- ---------------------------------------------------------------------
local REG0 = nil

local function build_and_capture(mode)
    FuzzLib.fresh_world()
    setup_defaults()
    Manager:setLiveRegistrations(VIEW, {}, {})
    _ = Manager:loadOrder(VIEW) -- force session bootstrap

    local leaves = leaf_universe(REG0)
    local menus = menu_universe(REG0)

    -- Fixed logical dataset (identical every turn):
    local pick_hidden, pick_parent, pick_pos, pick_menus = {}, {}, {}, {}
    for i = 1, math.min(6, #leaves) do pick_hidden[i] = leaves[i] end
    for i = 1, math.min(4, #leaves) do pick_parent[i] = leaves[#leaves - i + 1] end
    for i = 1, math.min(3, #leaves) do pick_pos[i] = leaves[(i * 7) % #leaves + 1] end
    for i = 1, math.min(3, #menus) do pick_menus[i] = menus[(i * 3) % #menus + 1] end

    local ord_hidden = mode == "sorted" and pick_hidden or shuffled_copy(pick_hidden)
    local ord_parent = mode == "sorted" and pick_parent or shuffled_copy(pick_parent)
    local ord_pos = mode == "sorted" and pick_pos or shuffled_copy(pick_pos)
    local ord_menus = mode == "sorted" and pick_menus or shuffled_copy(pick_menus)
    local custom_names = { "FuzzAlpha", "FuzzBeta", "FuzzGamma" }
    local ord_custom = mode == "sorted" and custom_names
        or shuffled_copy(custom_names)

    local txn = IntentStore.openTransaction()
    for _, id in ipairs(ord_hidden) do
        txn:setHidden(VIEW, id, { provider = "stock", reason = "fuzz" })
    end
    for _, id in ipairs(ord_parent) do
        txn:setParentOverride(VIEW, id, { provider = "stock", parent = menus[1] })
    end
    for _, id in ipairs(ord_pos) do
        txn:setPositionOverride(VIEW, id, { provider = "stock", after = leaves[2] })
    end
    for _, mid in ipairs(ord_menus) do
        local base = {}
        local src = REG0.menus[mid] and REG0.menus[mid].list or {}
        for x, id in ipairs(src) do base[x] = id end
        txn:setOrderOverride(VIEW, mid, base, {})
    end
    for _, name in ipairs(ord_custom) do
        txn:setCustomMenu(VIEW, "reorderingmenus:user:" .. name:lower(),
            { title = name, parent = "main" })
    end
    txn:commit(true)

    if mode == "canon" then
        -- Test-side canonicalization of the ONLY legitimate chronological
        -- collection. Schema v3 stores hide chronology ON each hidden
        -- record (ordinal); bit-equal logical state therefore requires
        -- bit-equal ordinals, so assign them deterministically here (sorted
        -- id order) exactly like the old hidden_order sort did.
        local sec = IntentStore.view(VIEW)
        local hidden_ids = {}
        for id in pairs(sec.hidden or {}) do table.insert(hidden_ids, id) end
        table.sort(hidden_ids)
        for i, id in ipairs(hidden_ids) do
            if type(sec.hidden[id]) == "table" then
                sec.hidden[id].ordinal = i
            end
        end
    end

    local save_ok = Manager:saveOrder(VIEW)
    ok(save_ok == true, "saveOrder succeeded")
    Manager:reloadFromDisk(VIEW)

    -- Projection split: ordered lists vs the chronological disabled set.
    local order = Manager:loadOrder(VIEW)
    local proj_ordered, disabled_set = {}, {}
    local mkeys = {}
    for k in pairs(order) do mkeys[#mkeys + 1] = k end
    table.sort(mkeys)
    for _, k in ipairs(mkeys) do
        local val = order[k]
        if type(val) == "table" then
            if k == "KOMenu:disabled" then
                local s = {}
                for _, id in ipairs(val) do s[id] = true end
                local sk = {}
                for id in pairs(s) do sk[#sk + 1] = id end
                table.sort(sk)
                disabled_set = sk
            else
                proj_ordered[#proj_ordered + 1] = k .. "="
                    .. FuzzLib.intent_bytes(val)
            end
        else
            proj_ordered[#proj_ordered + 1] = k .. "=" .. tostring(val)
        end
    end

    local sec = IntentStore.view(VIEW)
    return {
        proj_ordered = table.concat(proj_ordered, "|"),
        disabled_set = table.concat(disabled_set, ","),
        normalized = normalize_intent(sec),
        native_bytes = read_file_bytes(KoreaderAdapter.getNativePath(VIEW)),
        intent_path = DataStorage:getSettingsDir() .. "/reorderingmenus_intent.lua",
    }
end

REG0 = Registry.buildFromData(
    util.tableDeepCopy(require("ui/elements/filemanager_menu_order")), {}, {})
ok(#leaf_universe(REG0) > 10, "universe has stock leaves")

-- ---------------------------------------------------------------------
-- Phase 1: chronology tolerated
-- ---------------------------------------------------------------------
local REF = build_and_capture("sorted")
ok(#REF.proj_ordered > 200, "reference projection non-trivial")
ok(REF.native_bytes ~= nil, "native file exists")

local div = { proj = 0, disabled = 0, normalized = 0 }
for turn = 1, TURNS do
    local cap = build_and_capture("shuffled")
    if cap.proj_ordered ~= REF.proj_ordered then div.proj = div.proj + 1 end
    if cap.disabled_set ~= REF.disabled_set then div.disabled = div.disabled + 1 end
    if cap.normalized ~= REF.normalized then div.normalized = div.normalized + 1 end
end
ok(div.proj == 0, string.format(
    "P1: every non-disabled menu array identical across %d shuffled turns (%d divergent)",
    TURNS, div.proj))
ok(div.disabled == 0, string.format(
    "P1: KOMenu:disabled set identical across shuffled turns (%d divergent)",
    div.disabled))
ok(div.normalized == 0, string.format(
    "P1: normalized intent identical across shuffled turns (%d divergent)",
    div.normalized))

-- ---------------------------------------------------------------------
-- Phase 2: canonicalized hidden_order => strict byte identity
-- ---------------------------------------------------------------------
local REF2 = build_and_capture("canon")
local div_native, div_canon = 0, 0
for turn = 1, TURNS do
    local cap = build_and_capture("canon")
    if cap.native_bytes ~= REF2.native_bytes then div_native = div_native + 1 end
    local parsed_ref = parse_lua_table(REF2.intent_path)
    local parsed_got = parse_lua_table(cap.intent_path)
    if FuzzLib.intent_bytes(parsed_ref) ~= FuzzLib.intent_bytes(parsed_got) then
        div_canon = div_canon + 1
    end
end
ok(div_native == 0, string.format(
    "P2: native file BYTE-identical across %d canonicalized turns (%d divergent)",
    TURNS, div_native))
ok(div_canon == 0, string.format(
    "P2: canonical intent serialization BYTE-identical (%d divergent)",
    div_canon))
do
    local defaults =
        util.tableDeepCopy(require("ui/elements/filemanager_menu_order"))
    local regs_base, provs_base = {}, {}
    local n = 0
    for id, node in pairs(Registry.buildFromData(defaults, {}, {}).nodes) do
        n = n + 1
        if node.node_type == "item" and n <= 40 then
            regs_base[id] = { sorting_hint = (n % 3 == 0) and "main" or nil }
            provs_base[id] = "widget_" .. (n % 5)
        end
    end

    local function reg_key(reg)
        local fp = {}
        for id, node in pairs(reg.nodes) do
            fp[#fp + 1] = id .. ">" .. tostring(node.provider)
                .. ">" .. tostring(node.sorting_hint)
                .. ">" .. tostring(node.default_parent)
                .. ">" .. tostring(node.default_index)
        end
        table.sort(fp)
        return table.concat(fp, "|")
    end

    local ref_reg = nil
    local bad = 0
    for i = 1, 60 do
        local regs, provs = {}, {}
        local keys = {}
        for id in pairs(regs_base) do keys[#keys + 1] = id end
        for _, id in ipairs(shuffled_copy(keys)) do
            regs[id] = regs_base[id]
            provs[id] = provs_base[id]
        end
        local r = Registry.buildFromData(
            util.tableDeepCopy(defaults), regs, provs)
        if i == 1 then ref_reg = reg_key(r)
        elseif reg_key(r) ~= ref_reg then bad = bad + 1 end
    end
    ok(bad == 0, string.format(
        "registry/provider build invariant under shuffled insertion "
        .. "(60 builds, %d divergent)", bad))
end

print(string.format("\n=== Insertion-order hunt complete: %d passed, %d failed ===",
    passed, failed))
os.exit(failed == 0 and 0 or 1)

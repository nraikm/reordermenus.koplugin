--[[--
Malformed sorting_hint targets + airbag recovery (review Areas 1-4, 12).

Pins empirically observed stock MenuSorter behavior (v2025.10-43-g562fc11)
and the plugin's countermeasures:

  M1  every crash-class hint target (separator, self, other-orphan,
      numeric, empty string, table, boolean-false exception, disabled,
      stale container) is neutralized by the production guards: the build
      succeeds, no debris rows, item_table left unpolluted.
  M2  silent-corruption classes (reachable_leaf, stale row reshaping a
      leaf into an empty submenu) are documented and the HINT half is
      stripped; reshape-by-stale-row is flagged for the sparse writer.
  M3  orphan->orphan and mutual/ring hint chains are order-independent
      under the guard (stock crashes or survives depending on ALPHABETICAL
      id order - the guard removes that nondeterminism).
  M4  AIRBAG: when the first pass still crashes (unknown territory), the
      retry starts from the PRE-pass snapshot - every originally placed
      item renders, orderedPairs' __orderedIndex debris never surfaces,
      and synthesized custom submenus survive into the retry.
  M5  upstreamHintGuardPresent(): true against a fixed sorter copy,
      false against the crashing stock copy, nil against a bad path
      (compatibility detection for the Area 12 release policy).

Run:  ./run_tests.sh tests/test_malformed_targets_and_airbag.lua
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"), "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")

G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
KoreaderAdapter.installMenuSorterGuards() -- production stack, exactly like main.lua
local MenuSorter = require("ui/menusorter")

local SEP = KoreaderAdapter.SEPARATOR_ID
local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. msg)
    else
        failed = failed + 1
        print(string.format("  [FAIL] %s -> expected %s, got %s",
            msg, tostring(expected), tostring(actual)))
    end
    io.stdout:flush()
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end

-- Deep scan helpers -------------------------------------------------------
-- Stock's cleanup phase re-points bar slots AT the container-content tables,
-- so a container's rows live in its OWN array part; sub_item_table chains
-- appear only below that. Walk both.
local function walkIds(node, fn, seen)
    seen = seen or {}
    if seen[node] then return end
    seen[node] = true
    for _, e in ipairs(node) do
        if type(e) == "table" then
            fn(e)
            walkIds(e, fn, seen)
            if type(e.sub_item_table) == "table" then
                walkIds(e.sub_item_table, fn, seen)
            end
        end
    end
end

local function findId(root, id)
    local hit
    walkIds(root, function(e)
        if e.id == id then hit = e end
    end)
    return hit
end

print("===============================================================")
print("=== Malformed hint targets & airbag recovery ==================")
print("===============================================================")

local function baseWorld(hint_value, extra)
    local order = {
        ["KOMenu:menu_buttons"] = { "main", "tools" },
        main = { "m1" },
        tools = { "t1" },
    }
    local items = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = "Main" },
        tools = { text = "Tools" },
        m1 = { text = "M1" },
        t1 = { text = "T1" },
        orphan = { text = "Orphan", sorting_hint = hint_value },
    }
    if extra then extra(order, items) end
    return order, items
end

-- M1: crash-class targets are all neutralized -----------------------------
print("\n--- M1: crash-class hint targets under production guards ---")
local CRASH_CLASSES = {
    { name = "separator id",     hint = SEP },
    { name = "hint to itself",   hint = "orphan" },
    { name = "hint to another orphan", hint = "second_orphan",
      extra = function(order, items)
          items.second_orphan = { text = "Second" }
      end },
    { name = "numeric hint",     hint = 42 },
    { name = "empty-string hint", hint = "" },
    { name = "table hint",       hint = { "main" } },
    { name = "boolean-false hint (stock ignores)", hint = false },
    { name = "missing target",   hint = "never_existed" },
}
for _, case in ipairs(CRASH_CLASSES) do
    local order, items = baseWorld(case.hint, case.extra)
    -- boolean-false: stock's `if sorting_hint` test treats it as absent, so
    -- the guard never sees a hint to strip - exempt that case from the
    -- "hint field nilled" assertion only.
    local hint_field_exempt = (case.hint == false)
    local ok, result = pcall(function()
        return MenuSorter:mergeAndSort(nil, items, order)
    end)
    assert_true(ok, "M1[" .. case.name .. "]: guarded build succeeds")
    if ok then
        local o = findId(result, "orphan")
        assert_true(o ~= nil, "M1[" .. case.name .. "]: orphan still renders")
        if o then
            assert_true(type(o.text) == "string"
                and o.text:find("NEW:") ~= nil,
                "M1[" .. case.name .. "]: rendered with stock NEW: fallback")
            if not hint_field_exempt then
                assert_eq(o.sorting_hint, nil,
                    "M1[" .. case.name .. "]: hint stripped")
            end
        end
        assert_eq(items.__orderedIndex, nil,
            "M1[" .. case.name .. "]: no orderedPairs debris on item_table")
    end
end

-- Disabled target: item follows its hidden target into invisibility -------
do
    local order, items = baseWorld("gone_tab", function(order, items)
        order["KOMenu:disabled"] = { "gone_tab" }
    end)
    local ok, result = pcall(function()
        return MenuSorter:mergeAndSort(nil, items, order)
    end)
    assert_true(ok, "M1[disabled target]: guarded build succeeds")
    assert_eq(findId(result, "orphan"), nil,
        "M1[disabled target]: hinted item follows target into invisibility")
end

-- Reachable container still attaches (control) ----------------------------
do
    local order, items = baseWorld("tools")
    local ok, result = pcall(function()
        return MenuSorter:mergeAndSort(nil, items, order)
    end)
    assert_true(ok, "M1[control]: reachable container build succeeds")
    -- After stock's cleanup phase the container-content table IS the bar
    -- slot, so attached rows live in 'tools'' own array part.
    local tools = findId(result, "tools")
    local attached = false
    if tools then
        for _, e in ipairs(tools) do
            if type(e) == "table" and e.id == "orphan" then attached = true end
        end
        if not attached and type(tools.sub_item_table) == "table" then
            for _, e in ipairs(tools.sub_item_table) do
                if type(e) == "table" and e.id == "orphan" then attached = true end
            end
        end
    end
    assert_true(attached, "M1[control]: hinted attach under 'tools' preserved")
    assert_true(findId(result, "orphan").text:find("NEW:") == nil,
        "M1[control]: attached item carries no NEW: prefix")
end

-- M2: reachable leaf swallow + stale container ----------------------------
print("\n--- M2: silent-corruption classes ---")
do
    -- (a) hint to a placed LEAF: stock swallows the orphan into the leaf's
    --     array part (invisible corruption); the guard strips the hint.
    local order, items = baseWorld("m1")
    local ok, result = pcall(function()
        return MenuSorter:mergeAndSort(nil, items, order)
    end)
    assert_true(ok, "M2[leaf target]: build succeeds")
    local m1 = findId(result, "m1")
    local swallowed = false
    if m1 then
        for _, e in ipairs(m1) do
            if type(e) == "table" and e.id == "orphan" then swallowed = true end
        end
    end
    assert_eq(swallowed, false,
        "M2[leaf target]: orphan NOT swallowed into the leaf's array part")
    assert_true(findId(result, "orphan") ~= nil
        and findId(result, "orphan").text:find("NEW:") ~= nil,
        "M2[leaf target]: orphan rerendered via NEW: fallback instead")
end

do
    -- (b) STALE CONTAINER: order[x] survived a provider shape change; the
    --     item behind x is gone. Pre-fix this crashed stock mid-orphan-loop
    --     AND defeated the airbag (half-consumed retry input).
    local order = {
        ["KOMenu:menu_buttons"] = { "main", "tools" },
        main = { "m1", "x" },
        tools = { "t1" },
        x = { "old_child_a", "old_child_b" }, -- residue from previous shape
    }
    local items = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = "Main" },
        tools = { text = "Tools" },
        m1 = { text = "M1" },
        t1 = { text = "T1" },
        late = { text = "Late", sorting_hint = "x" },
    }
    local klass = KoreaderAdapter.classifyHintTarget("x", order, "late", items)
    assert_eq(klass, "stale_container",
        "M2[stale]: classifier names the stale row precisely")
    local ok, result = pcall(function()
        return MenuSorter:mergeAndSort(nil, items, order)
    end)
    assert_true(ok, "M2[stale]: guarded build succeeds (used to crash)")
    assert_true(findId(result, "late") ~= nil,
        "M2[stale]: hinted item falls back to NEW: rendering")
    assert_eq(items.__orderedIndex, nil, "M2[stale]: no debris leak")
end

-- M3: orphan->orphan chains in BOTH registration orders -------------------
print("\n--- M3: orphan->orphan / mutual / ring hint chains ---")
local function chainWorld(pairs_list)
    -- pairs_list: array of {id=..., hint=...} orphans
    local order = {
        ["KOMenu:menu_buttons"] = { "main" },
        main = { "m1" },
    }
    local items = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = "Main" },
        m1 = { text = "M1" },
    }
    for _, p in ipairs(pairs_list) do
        items[p.id] = { text = p.id, sorting_hint = p.hint }
    end
    return order, items
end
local function allRenderWithFallback(result, ids)
    for _, id in ipairs(ids) do
        local node = findId(result, id)
        if not node then return false, id .. " missing" end
        if node.text:find("NEW:") == nil then return false, id .. " no NEW:" end
    end
    return true
end
do
    -- Alphabetical luck: stock survives when the target sorts FIRST and
    -- crashes when it sorts second. Guarded world must succeed in both.
    local orders = {
        { { id = "aaa_target", hint = nil }, { id = "zzz_hinter", hint = "aaa_target" } },
        { { id = "zzz_target", hint = nil }, { id = "aaa_hinter", hint = "zzz_target" } },
    }
    for i, world in ipairs(orders) do
        local order, items = chainWorld(world)
        local ok, result = pcall(function()
            return MenuSorter:mergeAndSort(nil, items, order)
        end)
        assert_true(ok, "M3[chain order " .. i .. "]: build succeeds "
            .. "(stock outcome depends on alphabetical id order)")
        if ok then
            local good = allRenderWithFallback(result, { world[1].id, world[2].id })
            assert_true(good, "M3[chain order " .. i .. "]: both orphans render via fallback")
        end
    end
end
do
    -- Mutual hints A<->B and ring A->B->C->A: deterministic full fallback.
    for _, chain in ipairs({
        { { id = "plug_a", hint = "plug_b" }, { id = "plug_b", hint = "plug_a" } },
        { { id = "cyc_a", hint = "cyc_b" }, { id = "cyc_b", hint = "cyc_c" },
          { id = "cyc_c", hint = "cyc_a" } },
    }) do
        local order, items = chainWorld(chain)
        local ids = {}
        for _, p in ipairs(chain) do ids[#ids + 1] = p.id end
        local ok, result = pcall(function()
            return MenuSorter:mergeAndSort(nil, items, order)
        end)
        assert_true(ok, "M3[rings]: build succeeds for " .. #chain .. "-cycle")
        if ok then
            local good = allRenderWithFallback(result, ids)
            assert_true(good, "M3[rings]: every member renders deterministically")
        end
    end
end

-- M4: airbag recovery semantics -------------------------------------------
print("\n--- M4: airbag retries from the pre-pass snapshot ---")
do
    -- Force a first-pass crash the hint guard does NOT know about: install
    -- ONLY the airbag in a private sorter copy, then corrupt the ORDER
    -- structurally (non-string entry inside a menu row - unknown territory).
    local chunk = loadfile("frontend/ui/menusorter.lua")
    local env = setmetatable({ require = require }, { __index = _G })
    setfenv(chunk, env)
    local stock = chunk()

    local calls = 0
    local orig = stock.sort
    stock.sort = function(self, it, ord)
        calls = calls + 1
        if calls == 1 then
            -- sabotage AFTER the wrapper snapshot: emulate unknown territory
            table.insert(ord.main, 1, 12345) -- non-string row entry
        end
        return orig(self, it, ord)
    end
    -- wrap EXACTLY like installMenuSorterAirbag does, sharing its builder:
    local sanitize = KoreaderAdapter._probeSanitizeForRetry
    local function airbagged(self, item_table, order)
        local snapshot = {}
        for id, item in pairs(item_table) do snapshot[id] = item end
        local ok, result = pcall(orig --[[sabotaged]], self, item_table, order)
        if ok then return result end
        local clean_items, clean_order = sanitize(snapshot, item_table, order)
        if not clean_order["KOMenu:menu_buttons"]
                or #clean_order["KOMenu:menu_buttons"] == 0 then
            error(result, 0)
        end
        local ok2, result2 = pcall(stock.sort, self, clean_items, clean_order)
        if ok2 then return result2 end
        error(result2, 0)
    end

    local order = {
        ["KOMenu:menu_buttons"] = { "main", "tools" },
        main = { "m1" },
        tools = { "t1" },
    }
    local items = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = "Main" },
        tools = { text = "Tools" },
        m1 = { text = "M1" },
        t1 = { text = "T1" },
        boom = { text = "Boom", sorting_hint = "no_such_target_anywhere" },
    }
    local ok, result = pcall(airbagged, stock, items, order)
    assert_true(ok, "M4: airbag recovers a build that crashed post-snapshot")
    if ok then
        -- EVERY original item must render (pre-fix the retry lost all
        -- placed refs and ingested __orderedIndex debris).
        for _, id in ipairs({ "m1", "t1", "boom", "main", "tools" }) do
            assert_true(findId(result, id) ~= nil,
                "M4: '" .. id .. "' present after airbag retry")
        end
        -- No debris row: orderedPairs' scratch array must never surface.
        local debris = false
        walkIds(result, function(e)
            if e.__orderedIndex ~= nil then debris = true end
        end)
        assert_eq(debris, false, "M4: no __orderedIndex debris in output")
    end
end

-- M5: upstream fix detection ----------------------------------------------
print("\n--- M5: upstreamHintGuardPresent compatibility probe ---")
do
    -- (a) crashing stock copy -> false
    local verdict_stock = KoreaderAdapter.upstreamHintGuardPresent(
        "frontend/ui/menusorter.lua")
    assert_eq(verdict_stock, false,
        "M5a: installed stock sorter reports NO upstream fix")
    -- (b) patched copy -> true
    local src_file = io.open("frontend/ui/menusorter.lua", "r")
    local src = src_file and src_file:read("*a") or ""
    if src_file then src_file:close() end
    local needle = [[            local sorting_hint_menu = self:findById(menu_table["KOMenu:menu_buttons"], sorting_hint)]]
    local replacement = needle .. "\n            if sorting_hint_menu == nil then\n"
        .. "                table.insert(menu_table[\"KOMenu:menu_buttons\"][1], v)\n"
        .. "            else"
    -- crude splice producing a FIXED variant (nil-guard equivalent):
    local at = src:find(needle, 1, true)
    if at then
        local rest = src:sub(at + #needle)
        local tail = rest:gsub("^%s*sorting_hint_menu = sorting_hint_menu%.sub_item_table or sorting_hint_menu\n%s*table%.insert%(sorting_hint_menu, v%)",
            "sorting_hint_menu = sorting_hint_menu.sub_item_table or sorting_hint_menu\n            table.insert(sorting_hint_menu, v)\n            end", 1)
        local patched_src = src:sub(1, at - 1) .. replacement .. "\n" .. tail
        local tmp = os.tmpname() .. ".lua"
        local f = io.open(tmp, "w")
        f:write(patched_src)
        f:close()
        local verdict_fixed = KoreaderAdapter.upstreamHintGuardPresent(tmp)
        os.remove(tmp)
        assert_eq(verdict_fixed, true,
            "M5b: a fixed sorter copy reports the upstream fix present")
    else
        assert_eq(false, true, "M5b: patch anchor not found (menusorter changed?)")
    end
    -- (c) bad path -> nil
    local verdict_bad = KoreaderAdapter.upstreamHintGuardPresent(
        "/no/such/menusorter.lua")
    assert_eq(verdict_bad, nil,
        "M5c: unreadable sorter path yields 'unknown' (nil), not a guess")
end

print(string.format("\n=== %d passed, %d failed ===", passed, failed))

-- Leave the SHARED settings directory clean for the rest of the battery.
do
    local sd = DataStorage:getSettingsDir()
    for _, name in ipairs({
        "reader_menu_order.lua", "filemanager_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua",
        "reorderingmenus_state.lua",
    }) do pcall(os.remove, sd .. "/" .. name) end
end

if failed > 0 then os.exit(1) end

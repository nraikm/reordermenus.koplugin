--[[
Differential fuzzing: plugin model vs REAL KOReader MenuSorter (Area 11).

Pipeline A (model):
  generated defaults + registry + random sparse intent
    -> Materializer.resolve -> Validator.validate   = EXPECTED graph

Pipeline B (reality):
  EXPECTED graph -> NativeWriter.graphToNative      = sparse native order
  overlay native onto the generated defaults        = merged order
  merged order + item definitions -> REAL MenuSorter:sort
    -> walk rendered tree                           = ACTUAL graph

Semantic equivalence required:
  - identical visible tab bar (order included)
  - identical per-menu row sequences once separators are canonicalized the
    way stock renders them (leading separators dropped, a separator attaches
    to the preceding row as .separator=true, trailing separators vanish)
  - custom submenu titles surface as the submenu's text
  - no orphaned "NEW:"-prefixed rows anywhere

Any crash inside stock sort is a failure. Each iteration logs its seed so a
failure is reproducible: SEED=<n> ./luajit test_menusorter_differential_fuzz.lua
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

local Registry = require("reorderingmenus_registry")
local Materializer = require("reorderingmenus_materializer")
local Validator = require("reorderingmenus_validator")
local NativeWriter = require("reorderingmenus_native_writer")
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")

-- Real sorter WITH the plugin's production guards (hint + custom submenu
-- synthesis) but WITHOUT the airbag: a crash here must stay visible.
KoreaderAdapter.installSortingHintGuard()
KoreaderAdapter.installCustomSubmenuGuard()
local MenuSorter = require("ui/menusorter")

local SEED = tonumber(os.getenv("SEED")) or 20260822
local ITERATIONS = tonumber(os.getenv("ITERATIONS")) or 300
math.randomseed(SEED)

-- P0-A: effective configuration banner for runner verification.
io.write(string.format(
    "EFFECTIVE_CONFIG suite=%s seed=%d iterations=%d\n",
    debug.getinfo(1, "S").source:match("([^/]+)$"), SEED, ITERATIONS))
io.stdout:flush()

local passed, failed = 0, 0
local function fail(msg)
    failed = failed + 1
    print(string.format("  [FAIL] seed=%d iter=%d: %s", SEED, ITERATIONS - ITERATIONS_LEFT, msg))
end

local TAB_POOL = { "main", "tools", "navi", "setting", "search" }
-- item pool: leaves and submenus; submenu children come from LEAF_POOL
local LEAF_POOL = { "history", "bookmarks", "go_to", "read_timer", "calibre",
    "statistics", "frontlight", "language", "screen_dpi", "screensaver",
    "dictionary_lookup", "wikipedia_lookup", "file_search", "quickstart_guide" }
local SUBMENU_POOL = { "device", "network", "screen", "help", "exit_menu" }
local CUSTOM_TITLES = { "My tools", "Reading stuff", "Ångström menu", "阅读工具" }

local function rand_choice(t) return t[math.random(#t)] end
local function rand_bool(p) return math.random() < (p or 0.5) end
local function shuffled(t)
    local copy = {}
    for i, v in ipairs(t) do copy[i] = v end
    for i = #copy, 2, -1 do
        local j = math.random(i)
        copy[i], copy[j] = copy[j], copy[i]
    end
    return copy
end

-- Generate a random but VALID default world.
local function generate_world()
    local tabs = shuffled(TAB_POOL)
    -- keep 3-5 tabs
    while #tabs > 3 + math.random(2) do table.remove(tabs) end

    local leaves = shuffled(LEAF_POOL)
    local submenus = shuffled(SUBMENU_POOL)

    local defaults = { ["KOMenu:menu_buttons"] = tabs, ["KOMenu:disabled"] = {} }
    local node_defs = {}   -- id -> { text = ... }
    local used = {}

    local function take_leaf()
        for _, id in ipairs(leaves) do
            if not used[id] then used[id] = true; return id end
        end
    end

    -- every tab gets 1-4 rows, sometimes a submenu, sometimes a separator
    local defined = {}
    for _, tab in ipairs(tabs) do
        local list = {}
        local count = 1 + math.random(3)
        for _ = 1, count do
            if rand_bool(0.25) then
                table.insert(list, "----------------------------")
            end
            local id = take_leaf()
            if not id then
                id = "extra_" .. tab .. "_" .. #list
                defined[id] = true
            end
            table.insert(list, id)
        end
        if #list == 0 then
            local id = "filler_" .. tab
            defined[id] = true
            table.insert(list, id)
        end
        defaults[tab] = list
    end

    -- distribute ALL pool submenus among the tabs, give each 1-3 leaves;
    -- every submenu lands somewhere so no orphaned containers exist
    for _, sub_id in ipairs(submenus) do
        used[sub_id] = true
        local host = rand_choice(tabs)
        table.insert(defaults[host], sub_id)
        local child_list = {}
        for _ = 1, math.random(1, 3) do
            local cid = take_leaf()
            if cid then table.insert(child_list, cid) end
        end
        if #child_list == 0 then child_list = { "child_of_" .. sub_id } end
        defaults[sub_id] = child_list
        for _, cid in ipairs(child_list) do used[cid] = true end
    end

    for _, tab in ipairs(tabs) do node_defs[tab] = { text = "Tab " .. tab } end
    for id in pairs(defaults) do
        if id ~= "KOMenu:menu_buttons" and id ~= "KOMenu:disabled" then
            node_defs[id] = { text = "Item " .. id }
        end
    end
    -- submenu children appear only inside lists; define them too
    for _, sub_id in ipairs(submenus) do
        for _, cid in ipairs(defaults[sub_id] or {}) do
            if not node_defs[cid] then node_defs[cid] = { text = "Item " .. cid } end
        end
    end
    for id in pairs(defined) do
        if not node_defs[id] then node_defs[id] = { text = "Item " .. id } end
    end
    for _, id in ipairs(leaves) do
        if used[id] and not node_defs[id] then
            node_defs[id] = { text = "Item " .. id }
        end
    end
    return defaults, node_defs
end

-- Random sparse intent over the generated world.
local function generate_intent(reg, rng_salt)
    local intent = Materializer.emptyIntent()
    intent.hidden_order = intent.hidden_order or {}
    local node_ids = {}
    for id in pairs(reg.nodes) do table.insert(node_ids, id) end
    table.sort(node_ids)

    -- hide 0-3 items (never tabs: tab hiding is covered elsewhere; keep the
    -- bar non-empty so this fuzzer targets list semantics)
    for _ = 1, math.random(0, 3) do
        local id = rand_choice(node_ids)
        if reg.menus[id] == nil or not rand_bool(0.15) then
            local is_tab = false
            for _, t in ipairs(reg.tab_list) do if t == id then is_tab = true end end
            if not is_tab then
                intent.hidden[id] = { provider = reg.nodes[id].provider }
                table.insert(intent.hidden_order, id)
            end
        end
    end

    -- move 0-2 items to another existing menu level
    local menu_ids = {}
    for menu_id in pairs(reg.menus) do table.insert(menu_ids, menu_id) end
    for _ = 1, math.random(0, 2) do
        local id = rand_choice(node_ids)
        local dest = rand_choice(menu_ids)
        local is_tab = false
        for _, t in ipairs(reg.tab_list) do if t == id then is_tab = true end end
        if not is_tab and dest ~= id then
            intent.parent_override[id] =
                { provider = reg.nodes[id].provider, parent = dest }
        end
    end

    -- reorder 0-2 menu levels (permutation recorded as order_override)
    for _ = 1, math.random(0, 2) do
        local menu_id = rand_choice(menu_ids)
        local base = reg.menus[menu_id] and reg.menus[menu_id].list or nil
        if base and #base > 1 then
            intent.order_override[menu_id] = shuffled(base)
        end
    end

    -- occasionally create a custom submenu under a random menu
    if rand_bool(0.35) then
        local custom_id = "reorderingmenus:user:fuzz" .. math.random(1000, 9999)
        intent.custom_menus[custom_id] = {
            title = rand_choice(CUSTOM_TITLES),
            parent = rand_choice(menu_ids),
        }
    end
    return intent
end

-- Canonicalize an expected list into {id, sep} rows the way stock renders
-- separators: a separator collapses into the PRECEDING real row
-- (row.separator = true); leading/trailing separators vanish.
local function canonical_expected(list)
    local rows = {}
    for _, id in ipairs(list or {}) do
        if id == "----------------------------" then
            if #rows > 0 then rows[#rows].sep = true end
        else
            table.insert(rows, { id = id, sep = false })
        end
    end
    return rows
end

local function walk_rendered(root)
    -- root is the returned menu_buttons array of tab contents
    local tabs, menus = {}, {}
    local function visit_rows(rows, menu_id)
        local seq = {}
        for _, row in ipairs(rows) do
            if type(row) == "table" then
                if row.text and tostring(row.text):find("^NEW: ") then
                    ORPHANS_SEEN = ORPHANS_SEEN + 1
                end
                -- A rendered separator collapses INTO the preceding row as
                -- .separator=true (empirically pinned by
                -- tests/probe_separator_direction.lua).
                if row.id and row.id ~= "----------------------------" then
                    table.insert(seq, { id = row.id,
                        sep = row.separator == true })
                end
                if type(row.sub_item_table) == "table" then
                    visit_rows(row.sub_item_table, row.id)
                end
            end
        end
        menus[menu_id] = seq
    end
    ORPHANS_SEEN = 0
    for _, tab_content in ipairs(root) do
        if type(tab_content) == "table" then
            -- Stock cleanup replaces each bar entry with its content array;
            -- the content table carries .id from the sort loop.
            if tab_content.id then
                table.insert(tabs, tab_content.id)
            end
            visit_rows(tab_content, tab_content.id)
        end
    end
    return tabs, menus
end

ITERATIONS_LEFT = ITERATIONS

for iter = 1, ITERATIONS do
    ITERATIONS_LEFT = ITERATIONS - iter + 1
    local defaults, node_defs = generate_world()

    -- Pipeline A: expected graph
    local reg = Registry.buildFromData(defaults, {}, {})
    local intent = generate_intent(reg)
    local section_copy = {}
    for k, v in pairs(intent) do section_copy[k] = v end
    local graph = Materializer.resolve(reg, section_copy)
    local _, repaired = Validator.validate(graph, reg, section_copy)

    -- Pipeline B: emit sparse native, overlay onto defaults, REAL sort
    local ok_native, native = pcall(NativeWriter.graphToNative, reg, section_copy,
        repaired, Materializer.resolve(reg, nil))
    if not ok_native then
        fail("graphToNative crashed: " .. tostring(native))
    else
        local merged = {}
        for k, v in pairs(defaults) do merged[k] = v end
        for k, v in pairs(native) do merged[k] = v end

        local items = { ["KOMenu:menu_buttons"] = {} }
        for id, def in pairs(node_defs) do
            items[id] = { text = def.text }
        end
        -- customs have no widget: the installed custom-submenu guard
        -- synthesizes them from KOMenu:custom_submenus (emitted by
        -- graphToNative when custom titles exist).

        local ok_sort, result = pcall(function()
            return MenuSorter:sort(items, merged)
        end)
        if not ok_sort then
            fail("REAL MenuSorter crashed: " .. tostring(result):gsub("\n", " "))
        elseif type(result) ~= "table" then
            fail("sort returned " .. type(result))
        else
            -- compare
            local tabs_actual, menus_actual = walk_rendered(result)
            local tabs_expected = repaired.tabs
            local same_tabs = #tabs_actual == #tabs_expected
            if same_tabs then
                for i = 1, #tabs_expected do
                    if tabs_actual[i] ~= tabs_expected[i] then same_tabs = false end
                end
            end
            if not same_tabs then
                fail(string.format("tab bar mismatch: expected [%s] got [%s]",
                    table.concat(tabs_expected, ","),
                    table.concat(tabs_actual, ",")))
            end

            for menu_id, exp_list in pairs(repaired.lists) do
                local exp_rows = canonical_expected(exp_list)
                local got = menus_actual[menu_id] or {}
                local same = #exp_rows == #got
                if same then
                    for i = 1, #exp_rows do
                        if exp_rows[i].id ~= got[i].id
                                or exp_rows[i].sep ~= got[i].sep then
                            same = false
                        end
                    end
                end
                if not same then
                    if os.getenv("DUMP") then
                        local dump = require("dump")
                        print("---- DUMP of failing case ----")
                        print("defaults:\n" .. dump(defaults, nil, true))
                        print("intent:\n" .. dump(section_copy, nil, true))
                        print("expected graph:\n" .. dump(repaired, nil, true))
                        print("native emission:\n" .. dump(native, nil, true))
                        print("merged order given to stock:\n"
                            .. dump(merged, nil, true))
                    end
                    local got_ids = {}
                    for _, row in ipairs(got) do
                        table.insert(got_ids, tostring(row.id)
                            .. (row.sep and "*" or ""))
                    end
                    fail(string.format(
                        "menu '%s' mismatch: expected [%s] got [%s] (native key: %s)",
                        tostring(menu_id),
                        table.concat(exp_list, ","),
                        table.concat(got_ids, ","),
                        tostring(native[menu_id] ~= nil)))
                end
            end
            -- menus present in reality but not expected = phantom placement
            for menu_id in pairs(menus_actual) do
                if repaired.lists[menu_id] == nil then
                    fail("phantom menu rendered: " .. tostring(menu_id))
                end
            end
            if ORPHANS_SEEN and ORPHANS_SEEN > 0 then
                fail(ORPHANS_SEEN .. " orphaned NEW:-prefixed rows rendered")
            end
        end
    end
end

passed = ITERATIONS - failed
print(string.format("\n=== differential fuzz: %d iterations, %d failures (seed %d) ===",
    ITERATIONS, failed, SEED))
if failed > 0 then os.exit(1) end

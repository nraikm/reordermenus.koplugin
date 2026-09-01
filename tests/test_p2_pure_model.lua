--[[--
test_p2_pure_model.lua — P2 pure/derived internal model layer test suite.

Covers:
  1. Cross-process determinism (separate luajit processes, independent hash seeds).
  2. Validator honesty & pure non-mutating repair contract.
  3. MenuTitles live item priority & redundant helper removal.
  4. Purity of Materializer and Validator (zero mutation of inputs).
  5. Schema constants, view definitions, and empty canonical state constructors.
  6. Multi-scale performance benchmarks (Realistic, Medium synthetic, Stress synthetic).
--]]

local koreader_root = os.getenv("KOREADER_DIR") or "/Applications/KOReader.app/Contents/koreader"
dofile(koreader_root .. "/setupkoenv.lua")

local ARG = arg or {}

local is_child = false
local trial_idx = nil
for i = 1, #ARG do
    if ARG[i] == "--trial" and ARG[i + 1] then
        is_child = true
        trial_idx = tonumber(ARG[i + 1])
    end
end

local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = test_path:match("^(.*)/tests/[^/]+$") or os.getenv("PLUGIN_DIR") or "/Users/nr/Development/ReorderingMenus"
package.path = project_dir .. "/?.lua;" .. package.path

local MenuSchema = require("menu_schema")
local Materializer = require("materializer")
local Validator = require("validator")
local MenuTitles = require("menu_titles")
local Registry = require("registry")

local SEP = MenuSchema.SEPARATOR_ID
local BUTTONS = MenuSchema.MENU_BUTTONS_KEY

local passed, failed = 0, 0
local failures = {}
local function ok(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = msg
        print("[FAIL] " .. msg)
    end
end

local function eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = msg
        print(string.format("[FAIL] %s expected=%s got=%s", msg, tostring(expected), tostring(actual)))
    end
end

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepcopy(v) end
    return out
end

local function deepeq(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do
        if not deepeq(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function serializeSorted(val, indent)
    indent = indent or ""
    local t = type(val)
    if t == "number" or t == "boolean" then return tostring(val) end
    if t == "string" then return string.format("%q", val) end
    if t ~= "table" then return tostring(val) end

    local is_array = true
    local max_n = 0
    for k, _ in pairs(val) do
        if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
            is_array = false
            break
        end
        if k > max_n then max_n = k end
    end
    if is_array and max_n == #val then
        local parts = {}
        for i = 1, #val do
            parts[i] = serializeSorted(val[i], indent .. "  ")
        end
        return "[" .. table.concat(parts, ", ") .. "]"
    end

    local keys = {}
    for k in pairs(val) do table.insert(keys, k) end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = string.format("%s: %s", tostring(k), serializeSorted(val[k], indent .. "  "))
    end
    return "{\n" .. indent .. "  " .. table.concat(parts, ",\n" .. indent .. "  ") .. "\n" .. indent .. "}"
end

-- -------------------------------------------------------------------------
-- Determinism scenario generator
-- -------------------------------------------------------------------------
local function buildComplexScenario()
    local defaults = {
        [BUTTONS] = { "tools", "navi", "typeset", "search", "main" },
        tools = { "statistics", "calibre", "reordering_menus", "doc_setting_tweak", SEP, "advanced_settings" },
        navi = { "table_of_contents", "bookmarks", "page_map" },
        typeset = { "document_settings", "set_render_style", "style_tweaks" },
        search = { "dictionary_lookup", "wikipedia_lookup", "fulltext_search" },
        main = { "history", "favorites", "collections", "ota_update" },
        more_tools = { "terminal", "patch_management", "reordering_menus" },
    }
    local registrations = {
        reordering_menus = { sorting_hint = "tools" },
        custom_plugin_a = { sorting_hint = "more_tools" },
        custom_plugin_b = { sorting_hint = "navi" },
    }
    local providers = {
        reordering_menus = "reordering_menus",
        custom_plugin_a = "plugin_a",
        custom_plugin_b = "plugin_b",
    }
    local reg = Registry.buildFromData(defaults, registrations, providers)

    local intent = MenuSchema.newViewSection()
    intent.custom_menus["my_custom_sub"] = { title = "My Custom Submenu", after = "calibre" }
    intent.parent_override["my_custom_sub"] = { parent = "tools" }
    intent.custom_menus["my_nested_sub"] = { title = "Nested Submenu" }
    intent.parent_override["my_nested_sub"] = { parent = "my_custom_sub" }

    -- Introduce duplicate placements in intent raw/order and multiple cross-moves
    intent.order_override["tools"] = {
        entries = {
            { id = "calibre" },
            { id = "my_custom_sub" },
            { id = "statistics" },
            { separator = true },
            { id = "doc_setting_tweak" },
            { id = "reordering_menus" },
        }
    }
    intent.parent_override["bookmarks"] = { parent = "my_custom_sub" }
    intent.parent_override["page_map"] = { parent = "my_nested_sub" }
    intent.parent_override["ghost_item_x"] = { parent = "tools" }

    intent.hidden["ota_update"] = MenuSchema.newHiddenRecord({ ordinal = 1, origin = "main" })
    intent.hidden["fulltext_search"] = MenuSchema.newHiddenRecord({ ordinal = 2, origin = "search" })

    return reg, intent
end

-- If running as child trial, serialize projection + warnings and exit
if is_child then
    local reg, intent = buildComplexScenario()
    local graph = Materializer.resolve(reg, intent)
    local _, repaired, warnings = Validator.validate(graph, reg, intent)

    local out = {
        graph = repaired,
        warnings = warnings,
    }
    print(serializeSorted(out))
    os.exit(0)
end

-- =========================================================================
-- Parent Process: Run Full Test Suite
-- =========================================================================

print("=== P2 Pure Model Layer Suite ===")

-- -------------------------------------------------------------------------
-- 1. Schema Constants & Empty Constructors
-- -------------------------------------------------------------------------
print("\n--- 1. Schema Constants & Empty Constructors ---")
eq(MenuSchema.SCHEMA_VERSION, 3, "Schema version is 3")
eq(MenuSchema.SEPARATOR_ID, "----------------------------", "SEPARATOR_ID matches")
eq(MenuSchema.VIEWS[1], "reader", "VIEWS has reader")
eq(MenuSchema.VIEWS[2], "filemanager", "VIEWS has filemanager")
ok(MenuSchema.MAP_COLLECTIONS ~= nil and #MenuSchema.MAP_COLLECTIONS == 7, "MAP_COLLECTIONS defined with 7 collections")
ok(MenuSchema.SEQUENCE_FIELDS ~= nil and MenuSchema.SEQUENCE_FIELDS[1] == "tab_order", "SEQUENCE_FIELDS defined")
ok(MenuSchema.PROTECTED_ITEMS.reordering_menus == true, "PROTECTED_ITEMS contains reordering_menus")
ok(MenuSchema.PROTECTED_TABS.tools == true, "PROTECTED_TABS contains tools")

local empty_root = MenuSchema.newCanonicalState()
eq(empty_root.version, 3, "newCanonicalState version is 3")
ok(type(empty_root.views.reader) == "table", "newCanonicalState has reader view")
ok(type(empty_root.views.filemanager) == "table", "newCanonicalState has filemanager view")
eq(empty_root.meta.generation, 0, "newCanonicalState meta generation is 0")
eq(empty_root.meta.view_generations.reader, 0, "newCanonicalState reader generation is 0")
eq(empty_root.meta.view_generations.filemanager, 0, "newCanonicalState filemanager generation is 0")

local empty_view = MenuSchema.newViewSection()
ok(type(empty_view.hidden) == "table", "newViewSection has hidden")
ok(type(empty_view.parent_override) == "table", "newViewSection has parent_override")
ok(type(empty_view.position_override) == "table", "newViewSection has position_override")
ok(type(empty_view.order_override) == "table", "newViewSection has order_override")
ok(type(empty_view.custom_menus) == "table", "newViewSection has custom_menus")
ok(type(empty_view.separators) == "table", "newViewSection has separators")
ok(type(empty_view.raw_override) == "table", "newViewSection has raw_override")
eq(empty_view.tab_order, nil, "newViewSection tab_order is nil")

-- -------------------------------------------------------------------------
-- 2. MenuTitles Live Preference & Redundant Helper Removal
-- -------------------------------------------------------------------------
print("\n--- 2. MenuTitles Live Preference & Lookups ---")
-- Root tab static titles
eq(MenuTitles:getTitle("tools"), "Tools", "Static root tab title")
eq(MenuTitles:getTitle("navi"), "Navigation", "Static root tab title")
eq(MenuTitles:getIcon("tools"), "appbar.tools", "Root tab icon")

-- Static fallback
eq(MenuTitles:getTitle("frontlight"), "Frontlight", "Static item title")
eq(MenuTitles:getTitle("custom_plugin_action"), "Custom Plugin Action", "Humanize fallback")

-- Live item preference over static items catalog
local mock_live_items = {
    frontlight = { text = "Screen Brightness (Live Text)" },
    statistics = {
        text_func = function() return "Reading Stats (Dynamic Func)" end
    },
}
eq(MenuTitles:getTitle("frontlight", mock_live_items), "Screen Brightness (Live Text)", "Live text overrides static catalog")
eq(MenuTitles:getTitle("statistics", mock_live_items), "Reading Stats (Dynamic Func)", "Live text_func overrides static catalog")
eq(MenuTitles:getTitle("bookmarks", mock_live_items), "Bookmarks", "Missing live item falls back to static catalog")

-- Verify redundant classification methods removed
eq(rawget(MenuTitles, "isSubmenu"), nil, "isSubmenu removed from MenuTitles")
eq(rawget(MenuTitles, "isTab"), nil, "isTab removed from MenuTitles")

-- -------------------------------------------------------------------------
-- 3. Purity & Immutability of Materializer and Validator
-- -------------------------------------------------------------------------
print("\n--- 3. Purity & Immutability Verification ---")
local reg, intent = buildComplexScenario()
local reg_copy = deepcopy(reg)
local intent_copy = deepcopy(intent)

local graph = Materializer.resolve(reg, intent)
ok(deepeq(reg, reg_copy), "Materializer.resolve did not mutate registry")
ok(deepeq(intent, intent_copy), "Materializer.resolve did not mutate intent")

local graph_copy = deepcopy(graph)
local ok_val, repaired, warnings = Validator.validate(graph, reg, intent)
ok(ok_val == true, "Validator.validate returned true status")
ok(type(repaired) == "table", "Validator.validate returned repaired graph")
ok(type(warnings) == "table", "Validator.validate returned warnings list")
ok(deepeq(reg, reg_copy), "Validator.validate did not mutate registry")
ok(deepeq(intent, intent_copy), "Validator.validate did not mutate intent")
ok(deepeq(graph, graph_copy), "Validator.validate did not mutate input graph in-place")

-- -------------------------------------------------------------------------
-- 4. Cross-Process Determinism (Independent LuaJIT Processes)
-- -------------------------------------------------------------------------
print("\n--- 4. Cross-Process Determinism ---")
local subprocess_outputs = {}
local TRIALS = 5

for trial = 1, TRIALS do
    local cmd = string.format(
        "cd /Applications/KOReader.app/Contents/koreader && ./luajit %s --trial %d",
        "/Users/nr/Development/ReorderingMenus/tests/test_p2_pure_model.lua",
        trial
    )
    local p = io.popen(cmd)
    local out = p:read("*a")
    p:close()
    ok(out and #out > 0, string.format("Trial %d subprocess executed successfully", trial))
    subprocess_outputs[trial] = out
end

local reference_output = subprocess_outputs[1]
local all_identical = true
for trial = 2, TRIALS do
    if subprocess_outputs[trial] ~= reference_output then
        all_identical = false
        print(string.format("[FAIL] Subprocess output mismatch between trial 1 and trial %d", trial))
    end
end
ok(all_identical, string.format("All %d independent LuaJIT processes produced byte-identical output (graph + warnings)", TRIALS))

-- -------------------------------------------------------------------------
-- 5. Multi-Scale Benchmarks
-- -------------------------------------------------------------------------
print("\n--- 5. Performance Benchmarks ---")

local function runBenchmark(name, num_menus, items_per_menu, iterations)
    local defaults = { [BUTTONS] = {} }
    local registrations = {}
    local providers = {}

    for m = 1, num_menus do
        local menu_id = "menu_" .. m
        defaults[BUTTONS][#defaults[BUTTONS] + 1] = menu_id
        defaults[menu_id] = {}
        for it = 1, items_per_menu do
            local item_id = string.format("item_%d_%d", m, it)
            defaults[menu_id][#defaults[menu_id] + 1] = item_id
            if it % 5 == 0 then
                defaults[menu_id][#defaults[menu_id] + 1] = SEP
            end
            if it % 3 == 0 then
                registrations[item_id] = { sorting_hint = menu_id }
                providers[item_id] = "plugin_" .. (it % 7)
            end
        end
    end

    local reg = Registry.buildFromData(defaults, registrations, providers)
    local intent = MenuSchema.newViewSection()
    -- Hide 10% of items, reorder 20% of menus
    for m = 1, num_menus do
        local menu_id = "menu_" .. m
        if m % 5 == 0 then
            local entries = {}
            for _, id in ipairs(defaults[menu_id]) do
                if id == SEP then
                    entries[#entries + 1] = { separator = true }
                else
                    entries[#entries + 1] = { id = id, provider = providers[id] }
                end
            end
            intent.order_override[menu_id] = { entries = entries }
        end
        for it = 1, items_per_menu do
            local item_id = string.format("item_%d_%d", m, it)
            if (m + it) % 10 == 0 then
                intent.hidden[item_id] = MenuSchema.newHiddenRecord({ ordinal = it, origin = menu_id })
            end
        end
    end

    -- Warm up JIT
    for _ = 1, 5 do
        local g = Materializer.resolve(reg, intent)
        Validator.validate(g, reg, intent)
    end

    local start_mem = collectgarbage("count")
    local start_t = os.clock()
    for _ = 1, iterations do
        local g = Materializer.resolve(reg, intent)
        Validator.validate(g, reg, intent)
    end
    local end_t = os.clock()
    local elapsed_ms = (end_t - start_t) * 1000
    local per_resolve_us = (elapsed_ms / iterations) * 1000

    print(string.format("  [%s] %d menus, %d items total | %d iters in %.2f ms | %.2f µs / resolve (mem: ~%.1f KB)",
        name, num_menus, num_menus * items_per_menu, iterations, elapsed_ms, per_resolve_us, collectgarbage("count") - start_mem))
end

-- Realistic scale: ~10 menus, ~100 items (KOReader default scale)
runBenchmark("Realistic", 10, 10, 1000)

-- Medium synthetic: ~30 menus, ~600 items
runBenchmark("Medium Synthetic", 30, 20, 500)

-- Stress synthetic: ~100 menus, ~3000 items
runBenchmark("Stress Synthetic", 100, 30, 100)

print(string.format("\n==================================================="))
print(string.format("Result: %d passed, %d failed", passed, failed))

if failed > 0 then
    os.exit(1)
end
os.exit(0)

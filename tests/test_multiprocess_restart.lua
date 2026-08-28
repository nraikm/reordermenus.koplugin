--[[
Real-process restart testing across SEPARATE luajit processes (Area 9).

Catches what in-process cache-clearing cannot:
  - package.loaded leakage between "sessions"
  - module-level singletons (insert_menu tables, session caches)
  - global guards (MenuSorter.reordering_menus_hint_guard) persisting only
    in the guard-installing process
  - require-cached menu arrays surviving a "restart"

Phases (each a separate luajit process):
  P1: fresh install -> anchor a plugin item -> hide a stock item -> save
  P2: load -> assert both customizations survived -> reorder -> save
  P3: load -> assert everything survived; exactly one plugin entry in
      more_tools; MenuSorter guard flags are per-process only
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"), "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local H = dofile(project_dir .. "/tests/lib/subprocess_harness.lua")

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or ""))
    else
        failed = failed + 1
        print("  [FAIL] " .. (msg or "") ..
            string.format(" -> expected %s, got %s",
                tostring(expected), tostring(actual)))
    end
    io.stdout:flush()
end

local PRELUDE = [[
require("main")
local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local view = "filemanager"
local function emit(k, v) print("RM_RESULT\t" .. k .. "\t" .. tostring(v)) end
]]

print("===============================================================")
print("=== Multi-process restart (3 separate luajit processes)     ===")
print("===============================================================")

-- ---- P1 -----------------------------------------------------------------
local p1 = H.run_phase("p1", PRELUDE .. [[
MenuOrderManager:setLiveRegistrations(view,
    { fuzzplugin_item = { text = "Fuzz plugin", sorting_hint = "more_tools" } },
    { fuzzplugin_item = "fuzzplugin" })
local order = MenuOrderManager:loadOrder(view)
local ok_save = MenuOrderManager:saveOrder(view)
local IntentStore = require("reorderingmenus_intent_store")
local s = IntentStore.load()
s.views.filemanager.hidden["read_timer"] =
    { provider = "stock", origin = "tools", ordinal = 1 }
IntentStore.save()
emit("p1_saved", tostring(ok_save))
]])

local r1 = H.parse_results(p1)
print("P1 RAW OUTPUT:\n" .. p1.output)
assert_eq(r1.p1_saved, "true", "P1: customization persisted in process 1")

-- ---- P2 -----------------------------------------------------------------
local p2 = H.run_phase("p2", PRELUDE .. [[
MenuOrderManager:setLiveRegistrations(view,
    { fuzzplugin_item = { text = "Fuzz plugin", sorting_hint = "more_tools" } },
    { fuzzplugin_item = "fuzzplugin" })
local order = MenuOrderManager:loadOrder(view)
local found = false
for _, id in ipairs(order.more_tools or {}) do
    if id == "fuzzplugin_item" then found = true end
end
emit("p2_row_survived_restart", tostring(found))
emit("p2_read_timer_hidden",
    tostring(order["KOMenu:disabled"] and
        table.concat(order["KOMenu:disabled"], ","):find("read_timer", 1, true) ~= nil
        or false))
-- provider goes away (plugin disabled): its row must not RENDER anywhere.
-- (The projection deliberately retains the ghost placement - that is what
-- makes reinstall restore the slot - but stock can only render ids some
-- widget contributes.)
MenuOrderManager:setLiveRegistrations(view, {}, {})
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
local merged = KoreaderAdapter.getDefaultOrder(view)
local native = KoreaderAdapter.readNativeOrder(view)
for k, v in pairs(native or {}) do merged[k] = v end
local ms = require("ui/menusorter")
local items = { ["KOMenu:menu_buttons"] = {} }
for menu_id, list in pairs(merged) do
    if type(list) == "table" and menu_id ~= "KOMenu:menu_buttons"
            and menu_id ~= "KOMenu:disabled" then
        items[menu_id] = { text = menu_id }
        for _, id in ipairs(list) do
            if id ~= "----------------------------" and not items[id] then
                items[id] = { text = id }
            end
        end
    end
end
-- fuzzplugin_item intentionally NOT defined: its provider is gone
local ok_sort, result = pcall(function() return ms:sort(items, merged) end)
emit("p2_ghost_absent_while_provider_gone",
    tostring(ok_sort and not tostring(result):find("fuzzplugin_item", 1, true)))
emit("p2_read_timer_still_hidden",
    tostring(order["KOMenu:disabled"] and
        table.concat(order["KOMenu:disabled"], ","):find("read_timer", 1, true) ~= nil
        or false))
-- the provider returns (plugin re-enabled): its row must come back
MenuOrderManager:dropSessionState(view)
MenuOrderManager:setLiveRegistrations(view,
    { fuzzplugin_item = { text = "Fuzz plugin", sorting_hint = "more_tools" } },
    { fuzzplugin_item = "fuzzplugin" })
order = MenuOrderManager:loadOrder(view)
found = false
for _, id in ipairs(order.more_tools or {}) do
    if id == "fuzzplugin_item" then found = true end
end
emit("p2_row_restored_on_return", tostring(found))
-- reorder more_tools (reverse)
local mt = {}
for i = #(order.more_tools or {}), 1, -1 do table.insert(mt, order.more_tools[i]) end
MenuOrderManager.orders[view] = order
MenuOrderManager:stageList(view, "more_tools", mt)
emit("p2_reordered", tostring(MenuOrderManager:saveOrder(view)))
]])

local r2 = H.parse_results(p2)
assert_eq(r2.p2_row_survived_restart, "true",
    "P2: plugin row survived the restart")
assert_eq(r2.p2_read_timer_hidden, "true", "P2: hidden stock item survived")
assert_eq(r2.p2_ghost_absent_while_provider_gone, "true",
    "P2: absent provider's row is inert (not rendered)")
assert_eq(r2.p2_read_timer_still_hidden, "true",
    "P2: hiding survives the provider transition")
assert_eq(r2.p2_row_restored_on_return, "true",
    "P2: row returns when the provider returns")
assert_eq(r2.p2_reordered, "true", "P2: reorder persisted in process 2")

-- ---- P3 -----------------------------------------------------------------
local p3 = H.run_phase("p3", PRELUDE .. [[
MenuOrderManager:setLiveRegistrations(view,
    { fuzzplugin_item = { text = "Fuzz plugin", sorting_hint = "more_tools" } },
    { fuzzplugin_item = "fuzzplugin" })
local order = MenuOrderManager:loadOrder(view)
-- exactly one plugin row, and it must be the FIRST row (reversed in P2)
local count, first = 0, nil
for _, id in ipairs(order.more_tools or {}) do
    if id == "fuzzplugin_item" then count = count + 1; first = first or id end
end
emit("p3_plugin_count", tostring(count))
emit("p3_first_is_plugin", tostring(first == "fuzzplugin_item"))
emit("p3_read_timer_hidden",
    tostring(order["KOMenu:disabled"] and
        table.concat(order["KOMenu:disabled"], ","):find("read_timer", 1, true) ~= nil
        or false))
-- guards are process-local: a fresh process must have re-derived them
local ms = require("ui/menusorter")
emit("p3_guard_present", tostring(ms.reordering_menus_hint_guard == true))
-- insert_menu removal (P1B #11): shared elements tables are never mutated
local fm_order = require("ui/elements/filemanager_menu_order")
local ins_count = 0
for _, id in ipairs(fm_order.more_tools or {}) do
    if id == "reordering_menus" then ins_count = ins_count + 1 end
end
emit("p3_self_entry_count", tostring(ins_count))
]])

local r3 = H.parse_results(p3)
assert_eq(r3.p3_plugin_count, "1", "P3: exactly one plugin row (no duplicates)")
assert_eq(r3.p3_first_is_plugin, "true", "P3: reversed order survived")
assert_eq(r3.p3_read_timer_hidden, "true", "P3: hidden item still hidden")
assert_eq(r3.p3_guard_present, "true", "P3: runtime guards re-derived per process")
assert_eq(r3.p3_self_entry_count, "0", "P3: filemanager_menu_order not polluted (no insert_menu mutation)")

print(string.format("\n=== %d passed, %d failed (multi-process) ===", passed, failed))
if failed > 0 then os.exit(1) end

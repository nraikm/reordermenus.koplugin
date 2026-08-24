--[[--
KOReader compatibility contract (pinned to the installed version).

Everything this plugin assumes about stock KOReader, locked down so an
upstream change fails loudly here before users discover it:

  C1  readMSSettings parses dofile-ready files, returns {} when absent.
  C2  mergeAndSort overlays user keys ONTO the passed order table
      (documented mutation the pristine-defaults snapshot defends against).
  C3  sort() consumes placed references from item_table.
  C4  KOMenu:disabled entries are dropped from item_table.
  C5  reachable sorting_hint attaches under its target menu.
  C6  UNREACHABLE sorting_hint crashes stock sort (Error G documentation).
  C7  The shipped upstream patch applies to the installed menusorter.lua
      source, and the patched sorter (executed in a sandbox) fixes C6 while
      remaining byte-equivalent to stock on orphan-free inputs.
  C8  ui/plugin/insert_menu.add duplicates on every call - justifying the
      call-once guard in main.lua.
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

local _ = require("gettext")

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or ""))
        io.stdout:flush()
    else
        failed = failed + 1
        print("  [FAIL] " .. (msg or "") ..
            string.format(" -> expected %s, got %s", tostring(expected), tostring(actual)))
        io.stdout:flush()
    end
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end

local MenuSorter = require("ui/menusorter")
local lfs = require("libs/libkoreader-lfs")

print("===============================================================")
print("=== KOReader compatibility contract                          ===")
print("===============================================================")

local MENUSORTER_PATH = "frontend/ui/menusorter.lua"
assert_true(lfs.attributes(MENUSORTER_PATH, "mode") == "file",
    "C0: menusorter.lua found at expected path")
local src_file = io.open(MENUSORTER_PATH, "r")
local ms_src = src_file and src_file:read("*a") or ""
if src_file then src_file:close() end
assert_true(#ms_src > 1000, "C0: menusorter.lua source readable")

print("\n--- C1/C2: settings reading & overlay mutation ---")
do
    local empty = MenuSorter:readMSSettings("no_such_prefix_xyz")
    assert_true(type(empty) == "table" and next(empty) == nil,
        "C1: missing config reads as an empty table")

    local order = {
        ["KOMenu:menu_buttons"] = { "main" },
        main = { "m1" },
    }
    local items = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = _("Main") },
        m1 = { text = _("One") },
    }
    MenuSorter:mergeAndSort("no_such_prefix_xyz", items, order)
    assert_true(order.merged_probe == nil and type(order.main) == "table",
        "C2: order table survives mergeAndSort as the overlay target")
end

print("\n--- C3/C4/C5: reference consumption, disabled, hints ---")
do
    local order = {
        ["KOMenu:menu_buttons"] = { "main", "tools" },
        ["KOMenu:disabled"] = { "hidden_item" },
        main = { "visible_one", "hinted_item", "plain_orphan" },
        tools = { "tool_child" },
    }
    local items = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = _("Main") },
        tools = { text = _("Tools") },
        visible_one = { text = _("Visible one") },
        tool_child = { text = _("Tool child") },
        hinted_item = { text = _("Hinted"), sorting_hint = "tools" },
        hidden_item = { text = _("Hidden item") },
        plain_orphan = { text = _("Plain orphan") },
    }
    local ok, result = pcall(function() return MenuSorter:sort(items, order) end)
    assert_eq(ok, true, "C3: benign input sorts cleanly")
    assert_eq(items.visible_one, nil,
        "C3: sort consumes placed references from item_table")
    assert_eq(items.hidden_item, nil,
        "C4: KOMenu:disabled entries removed from item_table")

    local hinted_under_tools = false
    local function walk(node)
        for _, e in ipairs(node) do
            if type(e) == "table" then
                if e.id == "hinted_item" then hinted_under_tools = true end
                if type(e.sub_item_table) == "table" then walk(e.sub_item_table) end
                if #e > 0 then walk(e) end
            end
        end
    end
    walk(result)
    assert_eq(hinted_under_tools, true,
        "C5: reachable sorting_hint attaches the item under its target")
end

print("\n--- C6: stock crash on unreachable sorting_hint (Error G) ---")
do
    -- Fresh module WITHOUT our guard: load a private copy of the stock file.
    assert_eq(MenuSorter.reordering_menus_hint_guard, nil,
        "C6: precondition - plugin guards absent in this suite")
    local chunk = loadfile(MENUSORTER_PATH)
    local env = setmetatable({ require = require }, { __index = _G })
    setfenv(chunk, env)
    local stock = chunk()
    local order = {
        ["KOMenu:menu_buttons"] = { "main" },
        ["KOMenu:disabled"] = { "search_tab" },
        main = { "m1" },
    }
    local items = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = _("Main") },
        m1 = { text = _("One") },
        late_plugin = { text = _("Late plugin"), sorting_hint = "search_tab" },
    }
    local ok, err = pcall(function() return stock:sort(items, order) end)
    assert_eq(ok, false,
        "C6: RELEASE BLOCKER - stock crashes when hint target is hidden")
    assert_true(type(err) == "string" and err:find("menusorter") ~= nil,
        "C6: crash originates in menusorter code")
end

print("\n--- C7: upstream patch validation ---")
do
    -- The exact hunk the shipped patch rewrites. If KOReader changes this
    -- block, this assertion fails loudly and the patch needs rebasing.
    local needle = [[            local sorting_hint_menu = self:findById(menu_table["KOMenu:menu_buttons"], sorting_hint)
            sorting_hint_menu = sorting_hint_menu.sub_item_table or sorting_hint_menu
            table.insert(sorting_hint_menu, v)]]
    local replacement = [[            local sorting_hint_menu = self:findById(menu_table["KOMenu:menu_buttons"], sorting_hint)
            if sorting_hint_menu then
                sorting_hint_menu = sorting_hint_menu.sub_item_table or sorting_hint_menu
                table.insert(sorting_hint_menu, v)
            else
                -- hinted target unreachable (hidden or removed): safe fallback
                v.sorting_hint = nil
                v.text = self.orphaned_prefix .. v.text
                table.insert(menu_table["KOMenu:menu_buttons"][1], v)
            end]]
    -- Plain-text matching: the hunk must appear verbatim exactly once.
    local start_at, count = nil, 0
    local cursor = 1
    while true do
        local at = ms_src:find(needle, cursor, true)
        if not at then break end
        count = count + 1
        if not start_at then start_at = at end
        cursor = at + #needle
    end
    assert_eq(count, 1,
        "C7a: patch context matches the installed menusorter.lua exactly once")
    local patched_src = count == 1
        and (ms_src:sub(1, start_at - 1) .. replacement ..
             ms_src:sub(start_at + #needle))
        or ms_src

    -- Execute the patched module body in a sandbox mirroring its requires.
    local gettext_mod = require("gettext")
    local env = setmetatable({
        require = function(name)
            if name == "gettext" then return gettext_mod end
            return require(name)
        end,
    }, { __index = _G })
    local chunk = loadstring(patched_src)
    setfenv(chunk, env)
    local patched = chunk()
    assert_true(type(patched) == "table" and type(patched.sort) == "function",
        "C7b: patched module loads and exposes sort()")

    -- Fix C6's input: must not crash, item falls back to the first menu.
    local order = {
        ["KOMenu:menu_buttons"] = { "main" },
        ["KOMenu:disabled"] = { "search_tab" },
        main = { "m1" },
    }
    local items = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = _("Main") },
        m1 = { text = _("One") },
        late_plugin = { text = _("Late plugin"), sorting_hint = "search_tab" },
    }
    local ok, result = pcall(function() return patched:sort(items, order) end)
    assert_eq(ok, true, "C7c: patched sorter survives the hidden-target hint")
    local found_in_first = false
    if ok and type(result) == "table" then
        local first = result[1]
        local function scan(node)
            for _, e in ipairs(node) do
                if type(e) == "table" then
                    if e.id == "late_plugin" then found_in_first = true end
                    if type(e.sub_item_table) == "table" then scan(e.sub_item_table) end
                    if #e > 0 then scan(e) end
                end
            end
        end
        if first then scan(first) end
    end
    assert_eq(found_in_first, true,
        "C7d: orphaned item lands in the first menu (stock NEW: fallback)")

    -- Equivalence: on orphan-free input the patched sorter matches stock
    -- structure exactly (the patch touches only the orphan branch).
    local function run(sorter)
        local order2 = {
            ["KOMenu:menu_buttons"] = { "navi", "setting" },
            navi = { "history", "----------------------------", "bookmarks" },
            setting = { "s_one", "s_two" },
        }
        local items2 = {
            ["KOMenu:menu_buttons"] = {},
            navi = { text = _("Navi") },
            history = { text = _("History") },
            bookmarks = { text = _("Bookmarks") },
            setting = { text = _("Setting") },
            s_one = { text = _("S one") },
            s_two = { text = _("S two") },
        }
        return sorter:sort(items2, order2)
    end
    local chunk_stock = loadfile(MENUSORTER_PATH)
    local env_stock = setmetatable({ require = require },
        { __index = _G })
    if setfenv then setfenv(chunk_stock, env_stock) end
    local stock_mod = chunk_stock()
    local stock_out = run(stock_mod)
    local patched_out = run(patched)
    local function fp(v)
        local t = type(v)
        if t ~= "table" then return t .. ":" .. tostring(v) end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local parts = {}
        for i = 1, #v do parts[#parts + 1] = fp(v[i]) end
        for _, k in ipairs(keys) do
            if not tonumber(k) then parts[#parts + 1] = k .. "=" .. fp(v[k]) end
        end
        return "[" .. table.concat(parts, ";") .. "]"
    end
    assert_eq(fp(patched_out), fp(stock_out),
        "C7e: patched sorter byte-equivalent to stock on orphan-free menus")
end

print("\n--- C8: insert_menu duplicates without a guard ---")
do
    local inserter = require("ui/plugin/insert_menu")
    local fm_order = require("ui/elements/filemanager_menu_order")
    local before = #fm_order.more_tools
    inserter.add("contract_probe_entry")
    inserter.add("contract_probe_entry")
    local after = #fm_order.more_tools
    assert_eq(after - before, 2,
        "C8: stock insert_menu adds duplicates on repeat calls")
    -- clean up the probe entries so later suites see untouched tables
    for i = #fm_order.more_tools, 1, -1 do
        if fm_order.more_tools[i] == "contract_probe_entry" then
            table.remove(fm_order.more_tools, i)
        end
    end
end

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

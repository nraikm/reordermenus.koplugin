--[[--
Area 12: release-blocker mitigation - compatibility detection & recovery.

  P1  tabHidingSafety() reports "unsafe" on stock KOReader (no upstream
      nil-guard) and caches the verdict.
  P2  prepareForPluginRemoval() unhides EVERYTHING hidden in both views,
      persists the clean world, and returns per-view restored lists.
  P3  After preparation, the Error-G world cannot recur: a simulated late
      plugin hinting at the formerly-hidden tab builds fine under REAL
      stock code with NO plugin guards (the post-uninstall condition).
  P4  The UI layer loads with the mitigation wired (button present in both
      dialog builders) - source-level pin so it cannot silently vanish.

Run:  ./run_tests.sh tests/test_removal_safety_policy.lua
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

require("main") -- production environment exactly like a launch

local UIManager = require("ui/uimanager")
local KoreaderAdapter = require("lib.koreader_adapter")
local MenuOrderManager = require("lib.menuorder_manager")

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

print("===============================================================")
print("=== Removal-safety policy (Error G mitigation) ================")
print("===============================================================")

-- Deterministic baseline ---------------------------------------------------
do
    local sd = DataStorage:getSettingsDir()
    for _, name in ipairs({
        "reader_menu_order.lua", "filemanager_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua",
        "reorderingmenus_state.lua",
    }) do pcall(os.remove, sd .. "/" .. name) end
end

-- P1: safety verdict --------------------------------------------------------
print("\n--- P1: compatibility detection ---")
local verdict = KoreaderAdapter.tabHidingSafety()
assert_eq(verdict, "unsafe",
    "P1a: stock build reports 'unsafe' (no upstream fix)")
assert_eq(KoreaderAdapter.tabHidingSafety(), "unsafe",
    "P1b: verdict is cached within one process")
assert_eq(KoreaderAdapter.upstreamHintGuardPresent(), false,
    "P1c: raw probe confirms absence of upstream fix")

-- P2/P3: prepare-for-removal recovery ---------------------------------------
print("\n--- P2/P3: prepare for removal ---")
do
    local view = "filemanager"
    -- Hide a stock leaf and a stock TAB through the real manager.
    assert_eq(MenuOrderManager:setItemHidden(view, "history", true), true,
        "P2: setup - hide 'history'")
    assert_eq(MenuOrderManager:setTabHidden(view, "search", true), true,
        "P2: setup - hide 'search' tab")
    MenuOrderManager:saveOrder(view)

    local order_before = MenuOrderManager:loadOrder(view)
    local hidden_count_before = #(order_before["KOMenu:disabled"] or {})
    assert_true(hidden_count_before >= 2,
        "P2: two rows persisted as hidden before preparation")

    local restored = KoreaderAdapter.prepareForPluginRemoval()
    assert_true(#restored.filemanager >= 2,
        "P2: preparation reports restored rows (got "
        .. #restored.filemanager .. ")")

    local order_after = MenuOrderManager:loadOrder(view)
    local still_hidden = {}
    for _, id in ipairs(order_after["KOMenu:disabled"] or {}) do
        still_hidden[id] = true
    end
    assert_eq(still_hidden.history, nil, "P2: 'history' unhidden")
    assert_eq(still_hidden.search, nil, "P2: 'search' tab unhidden")

    -- P3: the world left behind must be crash-free WITHOUT any guard, even
    -- for a hypothetical plugin whose orphan hints at the formerly hidden
    -- tab. Execute REAL stock menusorter from disk in a private sandbox.
    local chunk = loadfile("frontend/ui/menusorter.lua")
    local env = setmetatable({ require = require }, { __index = _G })
    setfenv(chunk, env)
    local stock = chunk()
    -- The restored world: 'search' VISIBLE again - present in the bar and
    -- backed by its container row - exactly what prepareForPluginRemoval
    -- leaves behind for any plugin still installed.
    local sim_order = {
        ["KOMenu:menu_buttons"] = { "main", "search" },
        main = { "m1" },
        search = { "s1" },
    }
    local sim_items = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = "Main" },
        search = { text = "Search" },
        m1 = { text = "M1" },
        s1 = { text = "S1" },
        late_plugin = { text = "Late", sorting_hint = "search" },
    }
    local ok, result = pcall(function() return stock:sort(sim_items, sim_order) end)
    assert_true(ok, "P3: post-removal simulation builds under UNGUARDED stock"
        .. (ok and "" or (" (" .. tostring(result) .. ")")))
    if ok then
        -- and the hinted item attaches under the now-visible target:
        local attached = false
        local function scan(node)
            for _, e in ipairs(node) do
                if type(e) == "table" then
                    if e.id == "late_plugin" then attached = true end
                    if type(e.sub_item_table) == "table" then scan(e.sub_item_table) end
                    if #e > 0 then scan(e) end
                end
            end
        end
        scan(result)
        assert_true(attached,
            "P3: late plugin attaches under the restored 'search' container")
    end
end

-- P4: UI wiring pins ---------------------------------------------------------
print("\n--- P4: mitigation stays wired into the UI ---")
do
    -- P0 note: the module file was renamed to ui_screens.lua, then moved
    -- to lib/ui_screens.lua; the wiring pin follows the move.
    local f = io.open(project_dir .. "/lib/ui_screens.lua", "r")
    local src = f and f:read("*a") or ""
    if f then f:close() end
    assert_true(src:find("Prepare for plugin removal", 1, true) ~= nil,
        "P4: 'Prepare for plugin removal' present in UI")
    assert_true(src:find("confirmPrepareForRemoval", 1, true) ~= nil,
        "P4: confirmPrepareForRemoval flow wired in UI")
    assert_true(src:find("tabHidingSafety()", 1, true) ~= nil,
        "P4: unsafe-mode hide warning consults the policy")
end

print(string.format("\n=== %d passed, %d failed ===", passed, failed))

-- Leave the SHARED settings directory clean: the full battery runs every
-- suite against the same dir and our hidden-then-restored rows would
-- otherwise leak into later suites.
do
    local sd = DataStorage:getSettingsDir()
    for _, name in ipairs({
        "reader_menu_order.lua", "filemanager_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua",
        "reorderingmenus_state.lua",
    }) do pcall(os.remove, sd .. "/" .. name) end
end

if failed > 0 then os.exit(1) end

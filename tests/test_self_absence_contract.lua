--[[--
Contract suite for "Reordering Menus itself is absent" (Error G).

Stock KOReader's MenuSorter:sort dereferences the result of findById on an
orphaned item's sorting_hint without a nil check:

    local sorting_hint_menu = self:findById(menu_table["KOMenu:menu_buttons"], sorting_hint)
    sorting_hint_menu = sorting_hint_menu.sub_item_table or sorting_hint_menu
    table.insert(sorting_hint_menu, v)

When a hinted target is not reachable in the rendered tree - typically because
a hidden tab removed it - findById returns nil and the menu build CRASHES.

This plugin can leave such a world behind: hiding tab X persists into
KOMenu:disabled; if Reordering Menus is later disabled or uninstalled, the
guard that neutralizes orphaned hints disappears with it, and any plugin
whose item hints at X will crash stock KOReader on every launch.

S1 reproduces the crash against REAL stock code with the plugin's guards
   deliberately absent (release-blocking documentation).
S2 proves the guard neutralizes exactly this input while installed.
S3 pins the upstreamable defensive patch shipped alongside this suite.
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

-- Deliberately NOT requiring main.lua here: this suite contracts the world
-- WITHOUT this plugin running.
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
local KoreaderAdapter = require("lib.koreader_adapter")
local _ = require("gettext")

print("===============================================================")
print("=== Self-absence contract (stock MenuSorter hazards)         ===")
print("===============================================================")

-- A hidden search tab plus a third-party plugin whose item hints at search:
-- exactly the world Reordering Menus can leave behind after being removed.
local function hazardous_world()
    local order = {
        ["KOMenu:menu_buttons"] = { "main", "tools" }, -- search hidden: absent
        ["KOMenu:disabled"] = { "search" },
        main = { "history" },
        tools = { "more_tools" },
        more_tools = { "plugin_management" },
    }
    local items = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = _("Main") },
        history = { text = _("History") },
        tools = { text = _("Tools") },
        more_tools = { text = _("More tools") },
        plugin_management = { text = _("Plugin management") },
        annas_archive = {
            text = _("Anna's Archive"),
            sorting_hint = "search", -- target unreachable
        },
    }
    return items, order
end

print("\n--- S1: stock KOReader without the plugin ---")
do
    -- Ensure NO guard is wrapped (this suite never required main).
    assert_eq(MenuSorter.reordering_menus_hint_guard, nil,
        "S1: precondition - plugin guards absent")

    local items, order = hazardous_world()
    local ok, err = pcall(function() return MenuSorter:sort(items, order) end)
    assert_eq(ok, false,
        "S1: RELEASE BLOCKER - stock sort crashes on hint to hidden tab")
    assert_true(type(err) == "string" and err:find("menusorter") ~= nil,
        "S1: crash originates in stock menusorter.lua")
end

print("\n--- S2: with the plugin's guard installed ---")
do
    KoreaderAdapter.installMenuSorterGuards()
    assert_eq(MenuSorter.reordering_menus_hint_guard, true,
        "S2: precondition - guards installed")

    local items, order = hazardous_world()
    local ok, result = pcall(function() return MenuSorter:sort(items, order) end)
    assert_eq(ok, true, "S2: menu build survives the same input")
    local found = false
    local function walk(node)
        for _, e in ipairs(node) do
            if type(e) == "table" then
                if e.id == "annas_archive" then found = true end
                if type(e.sub_item_table) == "table" then walk(e.sub_item_table) end
                if #e > 0 then walk(e) end
            end
        end
    end
    if ok and type(result) == "table" then walk(result) end
    assert_eq(found, false, "S2: hinted-at-hidden-target item stays contained")
end

print("\n--- S3: unknown (never-rendered) hint target fallback ---")
do
    -- Without ANY disabled entry: unknown hint targets are handled by stock
    -- orphan logic once the guard strips the dead hint.
    local order = {
        ["KOMenu:menu_buttons"] = { "main" },
        main = { "history" },
    }
    local items = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = _("Main") },
        history = { text = _("History") },
        ghost_hinted = { text = _("Ghost"), sorting_hint = "nonexistent_tab_xyz" },
    }
    local ok, result = pcall(function() return MenuSorter:sort(items, order) end)
    assert_eq(ok, true, "S3: unknown hint target builds safely with guard")
    if ok and type(result) == "table" then
        local found = false
        local function walk(node)
            for _, e in ipairs(node) do
                if type(e) == "table" then
                    if e.id == "ghost_hinted" then found = true end
                    if type(e.sub_item_table) == "table" then walk(e.sub_item_table) end
                    if #e > 0 then walk(e) end
                end
            end
        end
        walk(result)
        assert_eq(found, true, "S3: item still reachable (stock NEW: fallback)")
    end
end

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

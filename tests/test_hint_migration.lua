--[[--
Hint/default migration matrix (Errors A and B).

Governing rules of the sparse-intent architecture:

    Untouched things follow the future.
    Explicitly customized things follow the user.

Plugin upgrade (sorting_hint change), table-driven:
    v1 state     user action         v2 provider change   expected
    foo -> A     none                foo -> B             B
    foo -> A     move -> C           foo -> B             C
    foo -> A     hide                foo -> B             hidden
    foo -> A     hide; unhide after  foo -> B             B
                 upgrade
    foo -> A     move -> C + hide    foo -> B             hidden, C retained
    foo -> A     restore default     foo -> B             B

KOReader update moving a built-in between menus:
    untouched -> follows new default; explicitly moved -> user wins;
    hidden -> stays hidden; restored -> follows new default.
Plus: upstream in-menu reorder flows through untouched menus and around
single manual anchors, and a new root tab slots near its default neighbours.
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

require("main") -- installs guards exactly like a launch

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or ""))
    else
        failed = failed + 1
        io.stdout:flush()
        print("  [FAIL] " .. (msg or "") ..
            string.format(" -> expected %s, got %s", tostring(expected), tostring(actual)))
    end
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end

local MenuOrderManager = require("lib.menuorder_manager")
local UIScreens = require("lib.ui_screens")
local IntentStore = require("lib.intent_store")

local view = "filemanager"
local settings_dir = DataStorage:getSettingsDir()

local function make_defaults_v1()
    return {
        ["KOMenu:menu_buttons"] = { "main", "tools", "setting" },
        ["KOMenu:disabled"] = {},
        main = { "main_first", "main_second" },
        tools = { "tool_a", "tool_b", "tool_c", "tool_d", "more_tools" },
        setting = { "set_a", "set_b" },
        more_tools = { "plugin_row_x", "plugin_row_y" },
    }
end
local function make_defaults_v2()
    local d = make_defaults_v1()
    d.tools = { "tool_a", "tool_b", "tool_d", "more_tools" }
    d.setting = { "set_a", "tool_c", "set_b" }
    return d
end
local function make_defaults_v2_reordered()
    local d = make_defaults_v1()
    d.tools = { "tool_a", "tool_c", "tool_b", "tool_d", "more_tools" }
    return d
end
local function make_defaults_v2_newtab()
    local d = make_defaults_v1()
    d.future_tab = { "future_child" }
    table.insert(d["KOMenu:menu_buttons"], "future_tab")
    return d
end

local mock_ui_fm = {
    registerTouchZones = function() end,
    onSetSortBy = function() end,
    registerModule = function(self, name, mod) self[name] = mod end,
}

local function make_stub(item_id, hint, name)
    return {
        name = name or ("fixture_" .. item_id),
        addToMainMenu = function(self, menu_items)
            if not self.ui.view then
                menu_items[item_id] = {
                    text = string.format(_("Stub %s"), item_id),
                    sorting_hint = hint,
                    callback = function() end,
                }
            end
        end,
    }
end

local function wipe_state()
    os.remove(settings_dir .. "/" .. view .. "_menu_order.lua")
    os.remove(settings_dir .. "/reorderingmenus_intent.lua")
    os.remove(settings_dir .. "/reorderingmenus_materialization.lua")
    os.remove(settings_dir .. "/reorderingmenus_state.lua")
    IntentStore.load(true)
    MenuOrderManager:dropSessionState(view)
    MenuOrderManager.default_orders[view] = nil
    MenuOrderManager.recent_moves[view] = {}
end

mock_ui_fm.menu = { registered_widgets = {} }

local function launch(stubs)
    -- Register stub widgets like KOReader does; reconciliation collects from
    -- the menu's registered_widgets, attributing providers by widget name.
    mock_ui_fm.menu.registered_widgets = {}
    for i, stub in ipairs(stubs or {}) do
        stub.ui = mock_ui_fm
        mock_ui_fm.menu.registered_widgets["stub_" .. i .. "_" .. stub.name] = stub
    end
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, false)
end

-- Simulate a full process restart: drop every in-memory artefact while
-- keeping the persisted files.
local function restart()
    MenuOrderManager:dropSessionState(view)
    package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
end

local function parents_of(item_id)
    local found = {}
    for menu_id, list in pairs(MenuOrderManager:loadOrder(view)) do
        if menu_id ~= "KOMenu:disabled" and type(list) == "table" then
            for _, id in ipairs(list) do
                if id == item_id then table.insert(found, menu_id) end
            end
        end
    end
    return found
end

print("===============================================================")
print("=== Hint / default migration matrix                         ===")
print("===============================================================")

print("\n--- P1..P6: provider changes its sorting_hint ---")

local function plugin_case(case_name, user_action, post_upgrade_action, expect_fn)
    wipe_state()
    local stub = make_stub("migrated_item", "more_tools")
    launch({ stub })
    MenuOrderManager:saveOrder(view)
    restart()
    launch({ stub })

    if user_action then user_action(case_name) end

    restart()
    launch({ make_stub("migrated_item", "tools") })
    MenuOrderManager:saveOrder(view)

    if post_upgrade_action then post_upgrade_action(case_name) end
    expect_fn(case_name)
end

plugin_case("P1", nil, nil, function(name)
    assert_eq(MenuOrderManager:getParentMenu(view, "migrated_item"), "tools",
        name .. ": untouched item follows the provider's new hint")
end)

plugin_case("P2", function()
    assert_true(MenuOrderManager:moveItemToMenu(view, "migrated_item", "more_tools", "setting"),
        "P2: move accepted")
    MenuOrderManager:saveOrder(view)
end, nil, function(name)
    assert_eq(MenuOrderManager:getParentMenu(view, "migrated_item"), "setting",
        name .. ": explicitly moved item keeps the user location")
end)

plugin_case("P3", function()
    MenuOrderManager:setItemHidden(view, "migrated_item", true, "more_tools")
    MenuOrderManager:saveOrder(view)
end, nil, function(name)
    assert_true(MenuOrderManager:isItemHidden(view, "migrated_item"),
        name .. ": hidden item stays hidden through the hint change")
end)

plugin_case("P4", function()
    MenuOrderManager:setItemHidden(view, "migrated_item", true, "more_tools")
    MenuOrderManager:saveOrder(view)
end, function()
    MenuOrderManager:setItemHidden(view, "migrated_item", false)
end, function(name)
    assert_eq(MenuOrderManager:getParentMenu(view, "migrated_item"), "tools",
        name .. ": unhide after upgrade lands at the new hint home")
end)

plugin_case("P5", function()
    MenuOrderManager:moveItemToMenu(view, "migrated_item", "more_tools", "setting")
    MenuOrderManager:setItemHidden(view, "migrated_item", true, "setting")
    MenuOrderManager:saveOrder(view)
end, nil, function(name)
    assert_true(MenuOrderManager:isItemHidden(view, "migrated_item"),
        name .. ": moved+hidden item remains hidden")
    assert_eq(MenuOrderManager:getHiddenItemParent(view, "migrated_item"), "setting",
        name .. ": customized origin retained behind the hide")
end)

plugin_case("P6", function()
    MenuOrderManager:moveItemToMenu(view, "migrated_item", "more_tools", "setting")
    MenuOrderManager:saveOrder(view)
    assert_true(MenuOrderManager:restoreItemDefault(view, "migrated_item"),
        "P6: restore accepts the hinted plugin entry")
    -- Production always persists after mutating verbs; staging alone must
    -- never be relied on to survive a restart.
    assert_true(MenuOrderManager:saveOrder(view),
        "P6: post-restore save persists the cleared customization")
end, nil, function(name)
    assert_eq(MenuOrderManager:getParentMenu(view, "migrated_item"), "tools",
        name .. ": restored entry adopts the provider's current default")
end)

print("\n--- K1..K4: KOReader update relocates a built-in ---")

local function koreader_case(user_action, expect_fn, v2_factory)
    wipe_state()
    MenuOrderManager.default_orders[view] = make_defaults_v1()
    launch({})
    MenuOrderManager:saveOrder(view)
    restart()
    launch({})

    if user_action then user_action() end

    MenuOrderManager.default_orders[view] = (v2_factory or make_defaults_v2)()
    restart()
    launch({})
    MenuOrderManager:saveOrder(view)
    expect_fn()
end

koreader_case(nil, function()
    assert_eq(MenuOrderManager:getParentMenu(view, "tool_c"), "setting",
        "K1: untouched built-in follows the update into its new menu")
    assert_eq(#parents_of("tool_c"), 1,
        "K1: relocated built-in has exactly one parent")
end)

koreader_case(function()
    assert_true(MenuOrderManager:moveItemToMenu(view, "tool_c", "tools", "main"),
        "K2: move accepted")
    MenuOrderManager:saveOrder(view)
end, function()
    assert_eq(MenuOrderManager:getParentMenu(view, "tool_c"), "main",
        "K2: user move beats the updated default placement")
end)

koreader_case(function()
    MenuOrderManager:setItemHidden(view, "tool_c", true, "tools")
    MenuOrderManager:saveOrder(view)
end, function()
    assert_true(MenuOrderManager:isItemHidden(view, "tool_c"),
        "K3: hidden built-in stays hidden through the update")
end)

koreader_case(function()
    assert_true(MenuOrderManager:moveItemToMenu(view, "tool_b", "tools", "setting"),
        "K4: pre-move accepted")
    MenuOrderManager:saveOrder(view)
    assert_true(MenuOrderManager:restoreItemDefault(view, "tool_b"),
        "K4: restore succeeds")
    assert_true(MenuOrderManager:saveOrder(view),
        "K4: post-restore save persists the cleared customization")
end, function()
    assert_eq(MenuOrderManager:getParentMenu(view, "tool_b"), "tools",
        "K4: restored entry follows the current (updated) default")
end)

print("\n--- K5/K6: upstream reorder and new root tab ---")

wipe_state()
MenuOrderManager.default_orders[view] = make_defaults_v1()
launch({})
MenuOrderManager.default_orders[view] = make_defaults_v2_reordered()
restart()
launch({})
local tools_list = MenuOrderManager:getMenuItems(view, "tools")
assert_eq(table.concat(tools_list, "|"),
    "tool_a|tool_c|tool_b|tool_d|more_tools",
    "K5: untouched menu receives the upstream reorder verbatim")

wipe_state()
MenuOrderManager.default_orders[view] = make_defaults_v1()
launch({})
-- Single manual drag: tool_d one slot up (a b d c more_tools).
local dragged = MenuOrderManager:getMenuItems(view, "tools")
table.remove(dragged, 4)
table.insert(dragged, 3, "tool_d")
MenuOrderManager:stageList(view, "tools", dragged)
MenuOrderManager:saveOrder(view)
MenuOrderManager.default_orders[view] = make_defaults_v2_reordered()
restart()
launch({})
tools_list = MenuOrderManager:getMenuItems(view, "tools")
assert_eq(table.concat(tools_list, "|"),
    "tool_a|tool_b|tool_d|tool_c|more_tools",
    "K6: anchored pair (c after d) keeps its spot; upstream reorder of untouched rows flows through")

wipe_state()
MenuOrderManager.default_orders[view] = make_defaults_v1()
launch({})
-- Curate a reordered bar.
MenuOrderManager:reorderTabs(view, { "tools", "main", "setting" })
MenuOrderManager:saveOrder(view)
MenuOrderManager.default_orders[view] = make_defaults_v2_newtab()
restart()
launch({})
local tabs_now = MenuOrderManager:getTabs(view)
local pos_tools, pos_future = nil, nil
for i, t in ipairs(tabs_now) do
    if t == "tools" then pos_tools = i end
    if t == "future_tab" then pos_future = i end
end
assert_true(pos_future ~= nil, "K7: update tab appears in a curated bar")
assert_true(pos_tools ~= nil and pos_future > pos_tools,
    "K7: new tab trails its nearest surviving default neighbour (setting)")
assert_eq(tabs_now[#tabs_now - 0], "future_tab",
    "K7: no default sibling survives behind it -> appends at the end")

wipe_state()
os.remove(settings_dir .. "/reorderingmenus_intent.lua")
os.remove(settings_dir .. "/reorderingmenus_materialization.lua")

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

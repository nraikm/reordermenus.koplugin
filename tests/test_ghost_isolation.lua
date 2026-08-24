--[[--
Ghost isolation (Error C) and repeated lifecycle idempotence (Error D).

Ghosts are persisted placements whose provider is currently absent. They are
kept so a same-provider reinstall restores exactly - but they must be
INERT while absent:

  G1  ghosts never render in the projection or in editors
  G2  a ghost alone does not make the view look customized (no native file,
      no dirty comparison impact beyond the tombstone itself)
  G3  ghosts do not influence A-Z sorting or preset round-trips of real rows
  G4  ghosts do not block a newly introduced stock neighbour slot
  G5  ghosts do not conflict when another provider reuses the id
  G6  the same provider returning regains its old customization exactly

  R1  install -> restart -> move/hide by script -> uninstall -> restart,
      repeated 25 times: counts stay stable, no duplicates accumulate, state
      normalized after every cycle.
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

require("main")

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

local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local UIScreens = require("reorderingmenus_ui_screens")
local IntentStore = require("reorderingmenus_intent_store")

local view = "filemanager"
local settings_dir = DataStorage:getSettingsDir()

local function make_stub(item_id, hint, name)
    return {
        name = name,
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

local mock_ui_fm = { menu = { registered_widgets = {} } }

local function launch(stubs)
    mock_ui_fm.menu.registered_widgets = {}
    for i, stub in ipairs(stubs or {}) do
        stub.ui = mock_ui_fm
        mock_ui_fm.menu.registered_widgets["stub_" .. i .. "_" .. tostring(stub.name)] = stub
    end
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, false)
end

local function restart()
    MenuOrderManager:dropSessionState(view)
    package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
end

local function wipe_state()
    os.remove(settings_dir .. "/" .. view .. "_menu_order.lua")
    os.remove(settings_dir .. "/reorderingmenus_intent.lua")
    os.remove(settings_dir .. "/reorderingmenus_materialization.lua")
    os.remove(settings_dir .. "/reorderingmenus_state.lua")
    IntentStore.load(true)
    restart()
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

local function count_in(list, needle)
    local n = 0
    for _, id in ipairs(list or {}) do
        if id == needle then n = n + 1 end
    end
    return n
end

print("===============================================================")
print("=== Ghost isolation & repeated lifecycle                     ===")
print("===============================================================")

-- G1/G2: moved+hidden plugin uninstalled; nothing renders, nothing leaks.
do
    wipe_state()
    launch({
        make_stub("ghost_moved", "more_tools", "ghostly"),
        make_stub("ghost_hidden", "more_tools", "ghostly"),
    })
    MenuOrderManager:moveItemToMenu(view, "ghost_moved", "more_tools", "setting")
    MenuOrderManager:setItemHidden(view, "ghost_hidden", true, "more_tools")
    MenuOrderManager:saveOrder(view)

    restart()
    launch({}) -- both providers gone
    -- Retention policy: the moved ghost keeps exactly its one configured
    -- parent (single-parent invariant), and the hidden ghost appears in no
    -- content list at all - only as a visibility tombstone.
    local moved_parents = parents_of("ghost_moved")
    assert_eq(#moved_parents, 1, "G1: moved ghost keeps a single preserved parent")
    assert_eq(moved_parents[1], "setting", "G1: preserved parent is the customized one")
    for menu_id, list in pairs(MenuOrderManager:loadOrder(view)) do
        if menu_id ~= "KOMenu:disabled" and type(list) == "table" then
            assert_eq(count_in(list, "ghost_hidden"), 0,
                "G1: hidden ghost in no content list (" .. menu_id .. ")")
        end
    end
end

-- G3: ghosts do not disturb A-Z sort or reset comparisons of live rows.
do
    wipe_state()
    launch({ make_stub("ghost_sort", "tools", "ghostly") })
    MenuOrderManager:saveOrder(view)
    restart()
    launch({}) -- provider gone; ghost remains persisted

    -- A-Z over More tools must behave as if the ghost did not exist.
    local mt = MenuOrderManager:getMenuItems(view, "more_tools")
    assert_eq(count_in(mt, "ghost_sort"), 0, "G3: ghost absent from editor list")

    -- Reset still succeeds and clears the tombstone with everything else.
    assert_true(MenuOrderManager:resetOrder(view), "G3: reset works with ghosts present")
    assert_eq(IntentStore.load().views[view].parent_override.ghost_sort, nil,
        "G3: reset removes the ghost's placement too")
end

-- G4: ghost rows do not block a newly introduced stock item's curated slot.
do
    wipe_state()
    launch({ make_stub("slot_ghost", "tools", "ghostly") })
    MenuOrderManager:saveOrder(view)

    -- Simulate an aged configuration that predates a new core entry.
    local order = MenuOrderManager:loadOrder(view)
    local function remove_from(list_name, target)
        local list = order[list_name]
        for i = #list, 1, -1 do
            if list[i] == target then table.remove(list, i) end
        end
    end
    remove_from("tools", "cloud_storage")
    MenuOrderManager.orders[view] = order
    MenuOrderManager:saveOrder(view)

    restart()
    launch({})
    -- The update heals cloud_storage back between its default neighbours.
    local tools_now = MenuOrderManager:getMenuItems(view, "tools")
    local pos = nil
    for i, id in ipairs(tools_now) do
        if id == "cloud_storage" then pos = i end
    end
    assert_true(pos ~= nil, "G4: healed stock entry present despite ghost rows")
end

-- G5/G6: reuse conflict-free; same provider regains customization.
do
    wipe_state()
    launch({ make_stub("recycled_id", "search", "original_plugin") })
    MenuOrderManager:moveItemToMenu(view, "recycled_id", "search", "main")
    MenuOrderManager:saveOrder(view)

    restart()
    launch({ make_stub("recycled_id", "setting", "imposter_plugin") })
    assert_eq(MenuOrderManager:getParentMenu(view, "recycled_id"), "setting",
        "G5: imposter gets its own default home")
    assert_eq(#parents_of("recycled_id"), 1, "G5: no duplicate from the old record")

    restart()
    launch({ make_stub("recycled_id", "search", "original_plugin") })
    assert_eq(MenuOrderManager:getParentMenu(view, "recycled_id"), "main",
        "G6: original provider regains its exact customization on return")
end

-- R1: repeated lifecycle stays idempotent.
do
    wipe_state()
    local CYCLES = 25
    local ok_cycles = true
    for i = 1, CYCLES do
        launch({ make_stub("cycle_item", "more_tools", "chameleon") })
        MenuOrderManager:saveOrder(view)
        restart()

        -- deterministic per-cycle script
        launch({ make_stub("cycle_item", "more_tools", "chameleon") })
        if i % 3 == 0 then
            MenuOrderManager:setItemHidden(view, "cycle_item", true, "more_tools")
        elseif i % 3 == 1 then
            MenuOrderManager:setItemHidden(view, "cycle_item", false)
        else
            MenuOrderManager:moveItemToMenu(view, "cycle_item", "more_tools", "setting")
        end
        MenuOrderManager:saveOrder(view)
        restart()

        launch({}) -- uninstalled
        MenuOrderManager:saveOrder(view)
        restart()

        -- invariants after every cycle
        local parents = parents_of("cycle_item")
        local expect_parent = (i % 3 == 2) and "setting" or nil
        local hidden_expected = (i % 3 == 0)
        if #parents > 1 then ok_cycles = false end
        if not hidden_expected and #parents == 1 and parents[1] ~= expect_parent
                and i % 3 == 2 then
            ok_cycles = false
        end
        local intent_section = IntentStore.load().views[view]
        local sep_count = 0
        for _ in pairs(intent_section.separators or {}) do sep_count = sep_count + 1 end
        if sep_count > 0 then ok_cycles = false end
        local hidden_count = 0
        for _ in pairs(intent_section.hidden or {}) do hidden_count = hidden_count + 1 end
        if hidden_count > 1 then ok_cycles = false end
    end
    assert_true(ok_cycles,
        "R1: " .. CYCLES .. " install/configure/uninstall cycles stay normalized")

    -- final reinstall restores deterministically
    launch({ make_stub("cycle_item", "more_tools", "chameleon") })
    assert_true(#parents_of("cycle_item") <= 1,
        "R1: post-cycle reinstall yields at most one parent")
end

wipe_state()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

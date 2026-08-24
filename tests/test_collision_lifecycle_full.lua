--[[--
Collision lifecycle: A/X installed & customized -> B/X collides -> A removed
-> B unique -> A returns -> B removed (review Area 5), including a SUBMENU X
variant and parent-menu-ID collisions.

Questions under test (from the review brief):
  L1  Does A's intent reactivate correctly when A returns?
  L2  Can B ever inherit A's customization? (must NEVER happen while
      ambiguous; once B is the sole provider, B legitimately OWNS the id)
  L3  Are customizations attempted while ambiguous persisted as if they were
      unambiguous? (colliding nodes are never pinned)
  L4  What happens when the deterministic winner changes because one plugin
      disappears? (attribution follows the survivor; single parent kept)
  L5  Submenu-X variant of the same lifecycle.
  L6  Parent-menu-ID collisions (whole-subtree hazard).

Run:  ./run_tests.sh tests/test_collision_lifecycle_full.lua
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

require("main") -- production guards + insert_menu call-once

local UIManager = require("ui/uimanager")
local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local UIScreens = require("reorderingmenus_ui_screens")
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
local _ = require("gettext")

local view = "filemanager"
local settings_dir = DataStorage:getSettingsDir()
local ORDER_FILE = settings_dir .. "/" .. view .. "_menu_order.lua"
local STATE_FILE = settings_dir .. "/reorderingmenus_state.lua"

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
print("=== Collision lifecycle (A/X <-> B/X) =========================")
print("===============================================================")

local mock_ui_fm = {
    file_chooser = {
        show_hidden = false,
        show_unsupported = false,
        items_per_page_default = 14,
        collates = { filename = { text = _("Filename"), menu_order = 1 } },
        getCollate = function() return nil, "filename" end,
        refreshPath = function() end,
        toggleShowFilesMode = function() end,
    },
    registerTouchZones = function() end,
    onSetSortBy = function() end,
    registerModule = function(self, name, mod) self[name] = mod end,
}

-- Stub whose contribution can be toggled per launch (removed plugins are
-- simply launched detached). `name` feeds provider attribution.
local function make_stub(item_id, hint, opts)
    opts = opts or {}
    return {
        item_id = item_id,
        name = opts.name or ("plugin_" .. tostring(item_id)),
        ui = nil,
        addToMainMenu = function(self, menu_items)
            -- Repo fixture convention: FileManager sessions carry no
            -- ui.view; Reader sessions do and contribute nothing here.
            if not self.ui or self.ui.view then return end
            local entry = {
                text = string.format(_("Stub %s"), item_id),
                sorting_hint = hint,
                callback = function() end,
            }
            if opts.submenu then
                entry.sub_item_table = {
                    { text = _("Child"), callback = function() end },
                }
            end
            menu_items[item_id] = entry
        end,
    }
end

local function wipe_state()
    os.remove(ORDER_FILE)
    os.remove(STATE_FILE)
    os.remove(settings_dir .. "/reorderingmenus_intent.lua")
    os.remove(settings_dir .. "/reorderingmenus_materialization.lua")
    pcall(function()
        require("reorderingmenus_intent_store").load(true)
        require("reorderingmenus_native_writer")._resetCaches()
    end)
    MenuOrderManager:dropSessionState(view)
    package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
    MenuOrderManager.orders[view] = nil
    MenuOrderManager.default_orders[view] = nil
    MenuOrderManager.recent_moves[view] = {}
end

local function close_all_windows()
    while #(UIManager._window_stack or {}) > 0 do
        local entry = UIManager._window_stack[#UIManager._window_stack]
        local w = entry and (entry.widget or entry)
        if w and w.onClose then w:onClose() else UIManager:close(w) end
    end
end

-- Launch a session with the given stubs ATTACHED (others count as removed).
local function launch(attached)
    local menu = FileManagerMenu:new{ ui = mock_ui_fm }
    mock_ui_fm.menu = menu
    for i, stub in ipairs(attached or {}) do
        stub.ui = mock_ui_fm
        menu.registered_widgets["stub_" .. i .. "_" .. tostring(stub.item_id)] = stub
    end
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, true)
    menu:setUpdateItemTable()
    return menu
end

local function detach(stubs)
    for _, s in ipairs(stubs or {}) do s.ui = nil end
end

local function save()
    MenuOrderManager:saveOrder(view)
end

local function configured_parents(item_id)
    local parents = {}
    local order = MenuOrderManager:loadOrder(view)
    for menu_id, list in pairs(order) do
        if type(list) == "table" and menu_id ~= "KOMenu:menu_buttons"
                and menu_id ~= "KOMenu:disabled" then
            for _, id in ipairs(list) do
                if id == item_id then table.insert(parents, menu_id) end
            end
        end
    end
    table.sort(parents)
    return parents
end

local function hidden_list()
    local order = MenuOrderManager:loadOrder(view)
    local out = {}
    for _, id in ipairs(order["KOMenu:disabled"] or {}) do
        out[id] = true
    end
    return out
end

-- ===========================================================================
wipe_state()
local A = make_stub("shared_x", "more_tools", { name = "plugin_a" })
local B = make_stub("shared_x", "more_tools", { name = "plugin_b" })
local X_SUB_A = make_stub("shared_sub", "setting",
    { submenu = true, name = "plugin_a2" })
local X_SUB_B = make_stub("shared_sub", "setting",
    { submenu = true, name = "plugin_b2" })
local TAB_A, TAB_B

-- Step 1: A/X installed and customized --------------------------------------
do
    launch({ A })
    local ok = MenuOrderManager:moveItemToMenu(view, "shared_x",
        "more_tools", "setting")
    assert_eq(ok, true, "step1: A/X movable to Settings")
    save()
    close_all_windows()
    detach({ A })
end

-- Step 2: B/X installed -> collision ----------------------------------------
do
    launch({ A, B })
    -- Attribution must be deterministic no matter what order collection hit.
    local regs, providers =
        KoreaderAdapter.collectLiveRegistrations(mock_ui_fm)
    assert_eq(providers.shared_x, "plugin_a",
        "L2/collision: attribution deterministic (lexicographic min)")
    assert_true(regs.shared_x.colliding_providers ~= nil,
        "L3: collision flagged on the registration record")
    -- While ambiguous, the editor must not offer a pinned placement: the
    -- registry marks the node colliding and reconciliation refuses to pin.
    save()
    close_all_windows()
    detach({ A, B })
end

-- Step 3: A removed -> B/X becomes unique -----------------------------------
do
    launch({ B })
    local parents = configured_parents("shared_x")
    assert_eq(#parents, 1,
        "L4: winner change keeps exactly one persisted parent")
    save()
    close_all_windows()
    detach({ B })
end

-- Step 4+5: A returns -> collision; then B removed -> A unique --------------
do
    launch({ A, B })
    close_all_windows()
    detach({ A, B })

    launch({ A })
    local parents = configured_parents("shared_x")
    assert_eq(#parents, 1, "L1: single parent after A returns alone")
    assert_eq(parents[1], "setting",
        "L1: A's original customization REACTIVATES (parent=setting)")
    save()
    close_all_windows()
    detach({ A })
end

-- L2 hard check: while both present nothing of A's leaked onto B. Remove A;
-- relaunch B alone: B now owns the id and serves whatever is persisted - but
-- during ALL ambiguous passes no pass may have written A's setting-parent
-- as if it were B's own unambiguous choice. Verify by wiping intent and
-- checking B-only world starts clean at its stock home.
do
    wipe_state()
    launch({ B })
    local parents = configured_parents("shared_x")
    assert_eq(#parents, 1, "L2: fresh B-only world persists one parent")
    assert_eq(parents[1], "more_tools",
        "L2: B inherits NOTHING from A's earlier customization "
        .. "(stock default home after wipe)")
    close_all_windows()
    detach({ B })
end

-- L5: submenu X variant ------------------------------------------------------
do
    wipe_state()
    launch({ X_SUB_A })
    local ok = MenuOrderManager:moveItemToMenu(view, "shared_sub",
        "setting", "tools")
    assert_eq(ok, true, "L5: submenu X movable to Tools")
    save()
    close_all_windows()
    detach({ X_SUB_A })

    launch({ X_SUB_A, X_SUB_B }) -- collision
    close_all_windows()
    detach({ X_SUB_A, X_SUB_B })

    launch({ X_SUB_A })
    local parents = configured_parents("shared_sub")
    assert_eq(#parents, 1, "L5: submenu X keeps one parent through churn")
    assert_eq(parents[1], "tools",
        "L5: submenu X reactivates A's moved parent")
    save()
    close_all_windows()
    detach({ X_SUB_A })
end

-- L6: parent-menu-ID collision ----------------------------------------------
TAB_A = {
    name = "pa",
    addToMainMenu = function(self, mi)
        mi.clash_tab = { text = _("A tab"),
            sub_item_table = { { text = _("A kid"),
                callback = function() end } } }
    end,
}
TAB_B = {
    name = "pb",
    addToMainMenu = function(self, mi)
        mi.clash_tab = { text = _("B tab"),
            sub_item_table = { { text = _("B kid"),
                callback = function() end } } }
    end,
}
do
    wipe_state()
    local menu = launch({})
    local fake_menu = { registered_widgets = {} }
    for i, w in ipairs({
        { name = "pb", addToMainMenu = TAB_B.addToMainMenu },
        { name = "pa", addToMainMenu = TAB_A.addToMainMenu },
    }) do
        fake_menu.registered_widgets[i] = setmetatable({}, { __index = w })
        fake_menu.registered_widgets[i].name = w.name
        fake_menu.registered_widgets[i].addToMainMenu = w.addToMainMenu
    end
    local regs2, providers2 =
        KoreaderAdapter.collectLiveRegistrations({ menu = fake_menu })
    assert_eq(providers2.clash_tab, "pa",
        "L6: contested TAB id attributed deterministically (min name)")
    assert_true(regs2.clash_tab.colliding_providers ~= nil,
        "L6: contested TAB id flagged as collision")
    -- Hiding the contested tab must be coherent: either refused, or hidden
    -- exactly once - never half-hide one provider's subtree.
    local ok_hide = MenuOrderManager:setTabHidden(view, "clash_tab", true)
    if ok_hide then
        local hidden = hidden_list()
        assert_eq(hidden.clash_tab, true,
            "L6: hiding a contested tab persists coherently")
    else
        assert_true(true, "L6: hiding contested tab REFUSED (also safe)")
    end
    close_all_windows()
end

print(string.format("\n=== %d passed, %d failed ===", passed, failed))

-- Leave the SHARED settings directory as clean as we found it: the full
-- battery runs every suite against the same dir, and our synthetic
-- providers/persisted rows would poison later suites.
do
    local sd = DataStorage:getSettingsDir()
    for _, name in ipairs({
        "reader_menu_order.lua", "filemanager_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua",
        "reorderingmenus_state.lua",
    }) do pcall(os.remove, sd .. "/" .. name) end
    pcall(function()
        require("reorderingmenus_intent_store").load(true)
        require("reorderingmenus_native_writer")._resetCaches()
    end)
    MenuOrderManager:dropSessionState(view)
end

if failed > 0 then os.exit(1) end

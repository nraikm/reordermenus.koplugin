--[[--
Submenu structural safety (Error F).

  C1  direct rejections along a nested chain A -> B -> C -> D.
  C2  indirect ring: A into B, B into C succeed; C into A rejected by the
      interaction layer AND impossible at the data layer; corrupt cyclic
      models are repaired deterministically and stay render-safe under the
      real MenuSorter.
  C3  malformed synthetic graphs (self parent, 2-cycle, 5-cycle, duplicate
      parents, missing parents) repaired without crashing.
  D1  deletion policy: created submenus delete only while empty; children
      (visible, hidden, ghosts) block deletion without being orphaned.
  S1  provider shape change: leaf becomes submenu and back.
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

local MenuSorter = require("ui/menusorter")
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
local Materializer = require("reorderingmenus_materializer")
local Validator = require("reorderingmenus_validator")
local Registry = require("reorderingmenus_registry")
local IntentStore = require("reorderingmenus_intent_store")
local UIScreens = require("reorderingmenus_ui_screens")

local view = "filemanager"
local settings_dir = DataStorage:getSettingsDir()

local function wipe_state()
    os.remove(settings_dir .. "/" .. view .. "_menu_order.lua")
    os.remove(settings_dir .. "/reorderingmenus_intent.lua")
    os.remove(settings_dir .. "/reorderingmenus_materialization.lua")
    os.remove(settings_dir .. "/reorderingmenus_state.lua")
    IntentStore.load(true)
    MenuOrderManager:dropSessionState(view)
end

local mock_ui_fm = { menu = { registered_widgets = {} } }
local function launch(stubs)
    mock_ui_fm.menu.registered_widgets = {}
    for i, stub in ipairs(stubs or {}) do
        stub.ui = mock_ui_fm
        mock_ui_fm.menu.registered_widgets["stub_" .. i] = stub
    end
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, false)
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

local function restart_like()
    MenuOrderManager:dropSessionState(view)
    package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
end

print("===============================================================")
print("=== Submenu structural safety                                ===")
print("===============================================================")

print("\n--- C1: direct ancestor/descendant rejection ---")
do
    wipe_state()
    launch()
    -- Namespaced ids: consume the returned ids instead of predicting them.
    local r_a = select(2, MenuOrderManager:createSubmenu(view, "main", "Level A"))
    local a_id = type(r_a) == "string" and r_a or "custom_submenu_1"
    local r_b = select(2, MenuOrderManager:createSubmenu(view, "tools", "Level B"))
    local b_id = type(r_b) == "string" and r_b or "custom_submenu_2"
    assert_true(MenuOrderManager:moveItemToMenu(view, b_id, "tools", a_id), "C1: B nested in A")
    local r_c = select(2, MenuOrderManager:createSubmenu(view, "tools", "Level C"))
    local c_id = type(r_c) == "string" and r_c or "custom_submenu_3"
    assert_true(MenuOrderManager:moveItemToMenu(view, c_id, "tools", b_id), "C1: C nested in B")
    local r_d = select(2, MenuOrderManager:createSubmenu(view, "tools", "Level D"))
    local d_id = type(r_d) == "string" and r_d or "custom_submenu_4"
    assert_true(MenuOrderManager:moveItemToMenu(view, d_id, "tools", c_id), "C1: D nested in C")

    assert_eq(MenuOrderManager:moveItemToMenu(view, a_id, "main", a_id), false,
        "C1: A cannot move into itself")
    for _, target in ipairs({ b_id, c_id, d_id }) do
        local ok = MenuOrderManager:canMoveItemToMenu(view, a_id, "main", target)
        assert_eq(ok, false, "C1: A rejected from its own descendant " .. target)
    end
    assert_eq(MenuOrderManager:canMoveItemToMenu(view, b_id, a_id, c_id), false,
        "C1: B rejected from its own subtree (C)")
    assert_eq(MenuOrderManager:canMoveItemToMenu(view, c_id, b_id, d_id), false,
        "C1: C rejected from its own subtree (D)")
end

print("\n--- C2: indirect ring across separate operations ---")
do
    wipe_state()
    launch()
    -- With namespaced ids the created ids are returned, not predictable.
    local ra = select(2, MenuOrderManager:createSubmenu(view, "main", "Ring A"))
    local rb = select(2, MenuOrderManager:createSubmenu(view, "tools", "Ring B"))
    local rc = select(2, MenuOrderManager:createSubmenu(view, "setting", "Ring C"))
    assert_true(type(ra) == "string" and type(rb) == "string"
        and type(rc) == "string", "C2: three ring members created")
    local a_id, b_id, c_id = ra, rb, rc
    assert_true(MenuOrderManager:moveItemToMenu(view, a_id, "main", b_id), "C2: A into B ok")
    assert_true(MenuOrderManager:moveItemToMenu(view, b_id, "tools", c_id), "C2: B into C ok")
    local ok, err = MenuOrderManager:moveItemToMenu(view, c_id, "setting", a_id)
    assert_eq(ok, false, "C2: closing the ring (C into A) is rejected")
    assert_true(type(err) == "string" and #err > 0, "C2: rejection explains itself")

    -- Data layer: a hand-crafted cyclic graph cannot survive validation.
    local reg = Registry.buildFromData({
        ["KOMenu:menu_buttons"] = { "main" },
        ["KOMenu:disabled"] = {},
        main = { "level_a" },
        level_a = { "level_b" },
        level_b = { "level_c" },
        level_c = { "level_a" },
    }, {}, {})
    local graph = Materializer.resolve(reg, Materializer.emptyIntent())
    local _ok_repaired, repaired = Validator.validate(graph, reg)
    local function reaches(from, target)
        local visited, stack = {}, { from }
        while #stack > 0 do
            local cur = table.remove(stack)
            if not visited[cur] then
                visited[cur] = true
                for _, child in ipairs(repaired.lists[cur] or {}) do
                    if child == target then return true end
                    if repaired.lists[child] then table.insert(stack, child) end
                end
            end
        end
        return false
    end
    for _, menu_id in ipairs({ "main", "level_a", "level_b", "level_c" }) do
        assert_eq(reaches(menu_id, menu_id), false,
            "C2: validator broke every cycle involving " .. menu_id)
    end

    -- Render-safety: real MenuSorter consumes the repaired projection.
    local order = {}
    order["KOMenu:menu_buttons"] = repaired.tabs
    order["KOMenu:disabled"] = repaired.disabled
    for menu_id, list in pairs(repaired.lists) do order[menu_id] = list end
    local items = {
        ["KOMenu:menu_buttons"] = {},
        main = { text = _("Main") },
        level_a = { text = "A" },
        level_b = { text = "B" },
        level_c = { text = "C" },
    }
    local ok_sort = pcall(function() return MenuSorter:sort(items, order) end)
    assert_true(ok_sort, "C2: real MenuSorter never throws on the repaired graph")
end

print("\n--- C3: malformed synthetic graphs repaired deterministically ---")
do
    local function deep_copy(t)
        if type(t) ~= "table" then return t end
        local r = {}
        for k, v in pairs(t) do r[k] = deep_copy(v) end
        return r
    end
    local cases = {
        { name = "self parent",
          defaults = { ["KOMenu:menu_buttons"] = { "main" }, main = { "main" } } },
        { name = "two cycle",
          defaults = { ["KOMenu:menu_buttons"] = { "main" },
                       main = { "x" }, x = { "y" }, y = { "x" } } },
        { name = "five cycle",
          defaults = { ["KOMenu:menu_buttons"] = { "main" },
                       main = { "n1" }, n1 = { "n2" }, n2 = { "n3" },
                       n3 = { "n4" }, n4 = { "n5" }, n5 = { "n1" } } },
    }
    for _, case in ipairs(cases) do
        local reg = Registry.buildFromData(deep_copy(case.defaults), {}, {})
        local graph = Materializer.resolve(reg, Materializer.emptyIntent())
        local ok_validate = pcall(function()
            return select(2, Validator.validate(graph, reg))
        end)
        assert_true(ok_validate, "C3: validation survives a " .. case.name)
    end

    -- A corrupt native file that would create membership chaos (duplicate
    -- parents + an unknown level) imports to a single-parent projection.
    wipe_state()
    launch()
    local dump = require("dump")
    local util = require("util")
    local dense = MenuOrderManager:loadOrder(view)
    table.insert(dense.more_tools, "opds")
    table.insert(dense.search, "opds")
    dense.mystery_level = { "orphan_row", "opds" }
    local file = io.open(settings_dir .. "/" .. view .. "_menu_order.lua", "w")
    file:write("return " .. dump(dense, nil, true))
    file:close()
    MenuOrderManager:reloadFromDisk(view)
    local repaired_order = MenuOrderManager:loadOrder(view, true)
    local opds_parents = 0
    for menu_id, list in pairs(repaired_order) do
        if menu_id ~= "KOMenu:disabled" and type(list) == "table" then
            for _, id in ipairs(list) do
                if id == "opds" then opds_parents = opds_parents + 1 end
            end
        end
    end
    assert_eq(opds_parents, 1,
        "C3: duplicate-parent import keeps exactly one authoritative home")
    local ok_build = pcall(function() return #MenuOrderManager:getTabs(view) > 0 end)
    assert_true(ok_build, "C3: projection still builds after chaotic import")
end

print("\n--- D1: deletion policy never orphans children ---")
do
    wipe_state()
    launch()
    -- Namespaced ids: consume the returned ids instead of predicting them.
    local r_doomed_a = select(2, MenuOrderManager:createSubmenu(view, "main", "Doomed"))
    local doomed_id = type(r_doomed_a) == "string" and r_doomed_a or "custom_submenu_1"

    -- Visible child blocks deletion.
    local r_adopted_b = select(2, MenuOrderManager:createSubmenu(view, "tools", "Adopted"))
    local adopted_id = type(r_adopted_b) == "string" and r_adopted_b or "custom_submenu_2"
    MenuOrderManager:moveItemToMenu(view, adopted_id, "tools", doomed_id)
    local ok_del, del_err = MenuOrderManager:deleteCustomSubmenu(view, doomed_id)
    assert_eq(ok_del, false, "D1: visible child blocks deletion")
    assert_true(type(del_err) == "string", "D1: block explains the rule")

    -- Hidden child also blocks deletion.
    MenuOrderManager:setItemHidden(view, adopted_id, true, doomed_id)
    assert_eq(MenuOrderManager:deleteCustomSubmenu(view, doomed_id), false,
        "D1: hidden child blocks deletion too")
    MenuOrderManager:setItemHidden(view, adopted_id, false)

    -- Moving the last child out unlocks deletion; nothing was orphaned.
    assert_true(MenuOrderManager:moveItemToMenu(view, adopted_id, doomed_id, "tools"),
        "D1: child moved back out")
    assert_true(MenuOrderManager:deleteCustomSubmenu(view, doomed_id),
        "D1: emptied submenu deletes cleanly")
    local order_now = MenuOrderManager:loadOrder(view)
    assert_eq(order_now[doomed_id], nil, "D1: deleted submenu leaves no level behind")
    assert_eq(MenuOrderManager:getParentMenu(view, adopted_id), "tools",
        "D1: former child remains exactly where it was moved")
end

print("\n--- S1: provider shape change leaf <-> submenu ---")
do
    local function make_stub(item_id, hint, with_children)
        return {
            name = "shape_plugin",
            addToMainMenu = function(self, menu_items)
                if not self.ui.view then
                    local entry = {
                        text = _("Shape shifter"),
                        sorting_hint = hint,
                        callback = function() end,
                    }
                    if with_children then
                        entry.sub_item_table = {
                            { text = _("Child"), callback = function() end },
                        }
                    end
                    menu_items[item_id] = entry
                end
            end,
        }
    end
    -- Leaf customized as moved; provider turns it into a submenu.
    wipe_state()
    launch({ make_stub("shape_item", "more_tools", false) })
    MenuOrderManager:moveItemToMenu(view, "shape_item", "more_tools", "tools")
    MenuOrderManager:saveOrder(view)
    restart_like()
    launch({ make_stub("shape_item", "more_tools", true) })
    assert_eq(MenuOrderManager:getParentMenu(view, "shape_item"), "tools",
        "S1: move survives the leaf->submenu shape change")
    assert_eq(#parents_of("shape_item"), 1, "S1: single parent after shape change")

    -- And back: submenu becomes a plain leaf again.
    MenuOrderManager:saveOrder(view)
    restart_like()
    launch({ make_stub("shape_item", "more_tools", false) })
    assert_eq(MenuOrderManager:getParentMenu(view, "shape_item"), "tools",
        "S1: customization survives the submenu->leaf change")
end

wipe_state()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

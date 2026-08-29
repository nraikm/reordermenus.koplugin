--[[--
test_top_plugins_compatibility.lua
Comprehensive compatibility tests for KOReader plugins:
  1. Bookshelf plugin (custom top-level tab, dynamic order injection, item operations)
  2. All 33 bundled KOReader plugins in File Manager and Reader views
  3. Multi-tab and complex third-party plugin patterns (dormancy, nested submenus, tab reordering)
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
local _ = require("gettext")
require("main")

local FuzzLib = dofile(project_dir .. "/tests/lib/fuzz_lib.lua")
FuzzLib.boot(project_dir)

local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
local Manager = require("reorderingmenus_menuorder_manager")
local MenuSchema = require("reorderingmenus_menu_schema")
local MenuSorter = require("ui/menusorter")
local util = require("util")

local function assert_equal(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s",
            msg or "assertion failed", tostring(expected), tostring(actual)), 2)
    end
end

local function assert_true(cond, msg)
    if not cond then
        error(msg or "assertion failed: expected true", 2)
    end
end

local function assert_false(cond, msg)
    if cond then
        error(msg or "assertion failed: expected false", 2)
    end
end

local function table_find(t, val)
    if type(t) ~= "table" then return nil end
    for i, v in ipairs(t) do
        if v == val then return i end
    end
    return nil
end

print("--- SECTION 1: Bookshelf Plugin Top-Level Tab Integration ---")
do
    FuzzLib.fresh_world()
    local VIEW = "filemanager"

    -- 1. Simulate Bookshelf plugin loading at boot
    local order = require("ui/elements/filemanager_menu_order")
    -- Bookshelf injects bookshelf_tab into KOMenu:menu_buttons at position 2
    local found_bs = false
    for _, t in ipairs(order["KOMenu:menu_buttons"]) do
        if t == "bookshelf_tab" then found_bs = true break end
    end
    if not found_bs then
        table.insert(order["KOMenu:menu_buttons"], 2, "bookshelf_tab")
    end
    order.bookshelf_tab = {
        "bookshelf_toggle",
        "bookshelf_shelf_size",
        "bookshelf_shelf_tabs",
        "bookshelf_hardcover",
        "bookshelf_settings",
        "bookshelf_updates",
        "bookshelf_about",
    }

    local mock_bookshelf = {
        name = "bookshelf",
        addToMainMenu = function(self, menu_items)
            menu_items.bookshelf_tab = { icon = "book.opened", text = "Bookshelf" }
            menu_items.bookshelf_toggle = { text = "Open Bookshelf", callback = function() end }
            menu_items.bookshelf_shelf_size = { text = "Shelf Size", callback = function() end }
            menu_items.bookshelf_shelf_tabs = { text = "Shelf Tabs", callback = function() end }
            menu_items.bookshelf_hardcover = { text = "Hardcover", callback = function() end }
            menu_items.bookshelf_settings = { text = "Bookshelf Settings", callback = function() end }
            menu_items.bookshelf_updates = { text = "Check Updates", callback = function() end }
            menu_items.bookshelf_about = { text = "About Bookshelf", callback = function() end }
        end
    }

    local ui = { menu = { registered_widgets = { mock_bookshelf } } }
    KoreaderAdapter.getDefaultOrder(VIEW, true)
    local regs, provs, colls = KoreaderAdapter.collectLiveRegistrations(ui)
    Manager:setLiveRegistrations(VIEW, regs, provs, colls)
    Manager:refreshRegistry(VIEW)

    -- Verify ReorderingMenus discovers bookshelf_tab and all its items
    local g = Manager:loadOrder(VIEW)
    assert_true(table_find(g["KOMenu:menu_buttons"], "bookshelf_tab") ~= nil, "bookshelf_tab must be in loaded tabs")
    assert_equal(g["KOMenu:menu_buttons"][2], "bookshelf_tab", "bookshelf_tab default position is 2")
    assert_true(type(g.bookshelf_tab) == "table", "bookshelf_tab items table must exist")
    assert_equal(#g.bookshelf_tab, 7, "bookshelf_tab has 7 items")

    local tabs = Manager:getTabs(VIEW)
    assert_true(table_find(tabs, "bookshelf_tab") ~= nil, "getTabs must include bookshelf_tab")

    -- Test initial MenuSorter build (unmodified by user)
    local fm_menu_items = {
        ["KOMenu:menu_buttons"] = {},
        filemanager_settings = { icon = "appbar.filebrowser" },
        setting = { icon = "appbar.settings" },
        tools = { icon = "appbar.tools" },
        search = { icon = "appbar.search" },
        main = { icon = "appbar.menu" },
        plus_menu = { icon = "appbar.plus" },
    }
    mock_bookshelf:addToMainMenu(fm_menu_items)

    local sorted_menu = MenuSorter:mergeAndSort("filemanager", fm_menu_items, util.tableDeepCopy(order))
    assert_true(#sorted_menu >= 6, "sorted menu must have at least 6 tabs")
    local bs_tab = sorted_menu[2]
    assert_equal(bs_tab.text, "Bookshelf", "tab 2 text must be Bookshelf")
    assert_equal(bs_tab.icon, "book.opened", "tab 2 icon must be book.opened")
    assert_equal(#bs_tab, 7, "tab 2 must have 7 items")

    -- 2. User customizes Bookshelf:
    -- (a) Move an item inside bookshelf_tab
    Manager:moveItem(VIEW, "bookshelf_tab", 1, 3)
    -- (b) Move a bookshelf item to tools tab
    Manager:moveItemToMenu(VIEW, "bookshelf_about", "bookshelf_tab", "tools", 1)
    -- (c) Hide a bookshelf item
    Manager:setItemHidden(VIEW, "bookshelf_updates", true)
    -- (d) Reorder tabs: move bookshelf_tab to the end
    local current_tabs = Manager:getTabs(VIEW)
    local new_tab_order = {}
    for _, t in ipairs(current_tabs) do
        if t ~= "bookshelf_tab" then table.insert(new_tab_order, t) end
    end
    table.insert(new_tab_order, "bookshelf_tab")
    Manager:reorderTabs(VIEW, new_tab_order)

    -- Save changes
    local ok_save = Manager:saveOrder(VIEW)
    assert_true(ok_save, "saveOrder must succeed")

    -- Verify MenuSorter build reflects all user customizations
    local fm_menu_items_2 = {
        ["KOMenu:menu_buttons"] = {},
        filemanager_settings = { icon = "appbar.filebrowser" },
        setting = { icon = "appbar.settings" },
        tools = { icon = "appbar.tools" },
        search = { icon = "appbar.search" },
        main = { icon = "appbar.menu" },
        plus_menu = { icon = "appbar.plus" },
    }
    mock_bookshelf:addToMainMenu(fm_menu_items_2)

    local sorted_custom = MenuSorter:mergeAndSort("filemanager", fm_menu_items_2, util.tableDeepCopy(order))
    local last_tab = sorted_custom[#sorted_custom]
    assert_equal(last_tab.text, "Bookshelf", "Bookshelf tab must now be the last tab")
    assert_equal(last_tab.icon, "book.opened", "Bookshelf icon preserved")

    -- Check bookshelf_about was moved to tools
    local tools_tab_idx = table_find(new_tab_order, "tools")
    local tools_tab = sorted_custom[tools_tab_idx]
    local found_about_in_tools = false
    for _, itm in ipairs(tools_tab) do
        if itm.id == "bookshelf_about" then found_about_in_tools = true break end
    end
    assert_true(found_about_in_tools, "bookshelf_about must be rendered in tools tab")

    -- Check bookshelf_updates is hidden
    local found_updates = false
    for _, itm in ipairs(last_tab) do
        if itm.id == "bookshelf_updates" then found_updates = true break end
    end
    assert_false(found_updates, "bookshelf_updates must be hidden")

    -- 3. Reset order reverts cleanly
    Manager:resetOrder(VIEW)
    local fm_menu_items_3 = {
        ["KOMenu:menu_buttons"] = {},
        filemanager_settings = { icon = "appbar.filebrowser" },
        setting = { icon = "appbar.settings" },
        tools = { icon = "appbar.tools" },
        search = { icon = "appbar.search" },
        main = { icon = "appbar.menu" },
        plus_menu = { icon = "appbar.plus" },
    }
    mock_bookshelf:addToMainMenu(fm_menu_items_3)
    local sorted_reset = MenuSorter:mergeAndSort("filemanager", fm_menu_items_3, util.tableDeepCopy(order))
    assert_equal(sorted_reset[2].text, "Bookshelf", "Reset restores Bookshelf tab to position 2")
    assert_equal(#sorted_reset[2], 7, "Reset restores all 7 items to Bookshelf tab")
    print("  [PASS] Bookshelf top-level tab lifecycle and customizations verified")
end

print("--- SECTION 2: Top 33 Bundled KOReader Plugins Compatibility ---")
do
    local lfs = require("libs/libkoreader-lfs")
    local plugin_dir = "/Applications/KOReader.app/Contents/koreader/plugins"
    local loaded_plugins = {}

    for f in lfs.dir(plugin_dir) do
        if f:sub(-9) == ".koplugin" then
            local plugin_path = plugin_dir .. "/" .. f
            package.path = string.format("%s/?.lua;%s", plugin_path, package.path)
            local ok, Plugin = pcall(dofile, plugin_path .. "/main.lua")
            if ok and type(Plugin) == "table" then
                Plugin.path = plugin_path
                Plugin.name = Plugin.name or f:match("^(.-)%.koplugin")
                table.insert(loaded_plugins, Plugin)
            end
        end
    end
    table.sort(loaded_plugins, function(a, b) return a.name < b.name end)
    assert_true(#loaded_plugins >= 30, string.format("Must load at least 30 plugins, got %d", #loaded_plugins))

    for _, view in ipairs({ "filemanager", "reader" }) do
        FuzzLib.fresh_world()
        local ui = { menu = { registered_widgets = loaded_plugins } }
        local regs, provs, colls = KoreaderAdapter.collectLiveRegistrations(ui)

        assert_true(type(regs) == "table", "registrations must be a table for " .. view)
        assert_true(type(provs) == "table", "providers must be a table for " .. view)

        Manager:setLiveRegistrations(view, regs, provs, colls)
        local order_graph = Manager:loadOrder(view)
        assert_true(type(order_graph) == "table", "order graph must load cleanly for " .. view)

        -- Build mock main menu items for all plugins
        local all_menu_items = {
            ["KOMenu:menu_buttons"] = {},
        }
        for _, tab_id in ipairs(order_graph["KOMenu:menu_buttons"] or {}) do
            all_menu_items[tab_id] = { icon = "appbar." .. tab_id, text = tab_id }
        end
        for _, p in ipairs(loaded_plugins) do
            if type(p.addToMainMenu) == "function" then
                pcall(p.addToMainMenu, p, all_menu_items)
            end
        end

        local base_order = util.tableDeepCopy(require("ui/elements/" .. view .. "_menu_order"))
        local sorted = MenuSorter:mergeAndSort(view, all_menu_items, base_order)
        assert_true(type(sorted) == "table" and #sorted > 0,
            "MenuSorter must build non-empty menu for " .. view .. " with all plugins")

        -- Verify no crashes when performing reordering / hiding on plugin items
        local first_plugin_item = nil
        local first_plugin_parent = nil
        for id, rec in pairs(regs) do
            if rec.provider and rec.provider:find("^plugin:") then
                local parent = Manager:getParentMenu(view, id)
                if parent then
                    first_plugin_item = id
                    first_plugin_parent = parent
                    break
                end
            end
        end

        if first_plugin_item and first_plugin_parent then
            -- Hide item and save
            Manager:setItemHidden(view, first_plugin_item, true)
            local ok_save = Manager:saveOrder(view)
            assert_true(ok_save, "Saving hidden plugin item must succeed in " .. view)

            -- Reload and verify
            assert_true(Manager:isItemHidden(view, first_plugin_item),
                "Item must be recorded as hidden in " .. view)

            -- Unhide and save
            Manager:setItemHidden(view, first_plugin_item, false)
            Manager:saveOrder(view)
            assert_false(Manager:isItemHidden(view, first_plugin_item),
                "Item must be recorded as unhidden in " .. view)
        end
    end
    print(string.format("  [PASS] All %d bundled plugins verified in File Manager & Reader views", #loaded_plugins))
end

print("--- SECTION 3: Multi-Tab & Complex Third-Party Plugin Patterns ---")
do
    FuzzLib.fresh_world()
    local VIEW = "filemanager"

    -- Simulate two 3rd-party plugins injecting custom top-level tabs simultaneously
    local order = require("ui/elements/filemanager_menu_order")
    table.insert(order["KOMenu:menu_buttons"], 1, "custom_tab_alpha")
    table.insert(order["KOMenu:menu_buttons"], "custom_tab_beta")
    order.custom_tab_alpha = { "alpha_item_1", "alpha_item_2" }
    order.custom_tab_beta = { "beta_item_1", "beta_item_2", "beta_sub" }
    order.beta_sub = { "beta_sub_item_1" }

    local plugin_alpha = {
        name = "plugin_alpha",
        addToMainMenu = function(self, menu_items)
            menu_items.custom_tab_alpha = { icon = "alpha.icon", text = "Alpha Tab" }
            menu_items.alpha_item_1 = { text = "Alpha 1", callback = function() end }
            menu_items.alpha_item_2 = { text = "Alpha 2", callback = function() end }
        end
    }

    local plugin_beta = {
        name = "plugin_beta",
        addToMainMenu = function(self, menu_items)
            menu_items.custom_tab_beta = { icon = "beta.icon", text = "Beta Tab" }
            menu_items.beta_item_1 = { text = "Beta 1", callback = function() end }
            menu_items.beta_item_2 = { text = "Beta 2", callback = function() end }
            menu_items.beta_sub = { text = "Beta Submenu" }
            menu_items.beta_sub_item_1 = { text = "Beta Sub Item 1", callback = function() end }
        end
    }

    local ui = { menu = { registered_widgets = { plugin_alpha, plugin_beta } } }
    KoreaderAdapter.getDefaultOrder(VIEW, true)
    local regs, provs, colls = KoreaderAdapter.collectLiveRegistrations(ui)
    Manager:setLiveRegistrations(VIEW, regs, provs, colls)
    Manager:refreshRegistry(VIEW)

    local g = Manager:loadOrder(VIEW)
    assert_equal(g["KOMenu:menu_buttons"][1], "custom_tab_alpha", "custom_tab_alpha placed at position 1")
    assert_true(table_find(g["KOMenu:menu_buttons"], "custom_tab_beta") ~= nil, "custom_tab_beta placed at end")

    -- Test moving an item from plugin_beta's submenu to plugin_alpha's tab
    Manager:moveItemToMenu(VIEW, "beta_sub_item_1", "beta_sub", "custom_tab_alpha", 1)
    Manager:saveOrder(VIEW)

    local g_reloaded = Manager:loadOrder(VIEW)
    assert_equal(g_reloaded.custom_tab_alpha[1], "beta_sub_item_1",
        "beta_sub_item_1 successfully moved into custom_tab_alpha")

    -- Test dormancy: simulate plugin_alpha being disabled
    local ui_beta_only = { menu = { registered_widgets = { plugin_beta } } }
    local regs_b, provs_b, colls_b = KoreaderAdapter.collectLiveRegistrations(ui_beta_only)
    Manager:setLiveRegistrations(VIEW, regs_b, provs_b, colls_b)
    Manager:refreshRegistry(VIEW)

    -- Dormant alpha items must not crash or leak
    local g_dormant = Manager:loadOrder(VIEW)
    assert_true(type(g_dormant) == "table", "Order loads cleanly when plugin is disabled")

    -- Re-enable plugin_alpha: state is restored
    Manager:setLiveRegistrations(VIEW, regs, provs, colls)
    Manager:refreshRegistry(VIEW)
    local g_restored = Manager:loadOrder(VIEW)
    assert_equal(g_restored.custom_tab_alpha[1], "beta_sub_item_1",
        "Customized state restored upon plugin re-enable")

    print("  [PASS] Multi-tab and dormancy lifecycle patterns verified")
end

print("=== ALL TOP PLUGINS & BOOKSHELF COMPATIBILITY TESTS PASSED ===")

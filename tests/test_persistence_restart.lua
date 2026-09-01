--[[--
Persistence-across-restart verification.

Runs AFTER the interactive suites: performs moves, hides, and a plugin
installation, saves everything, then simulates a complete KOReader restart by
dropping every in-memory cache (manager orders, default-order cache,
recent-move records, hidden-origin state cache, cached default order module)
and building a brand-new FileManagerMenu from scratch - exactly what happens
on relaunch. Only then does it verify that every change survived.
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

local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local view = "filemanager"
local ORDER_FILE = DataStorage:getSettingsDir() .. "/" .. view .. "_menu_order.lua"

-- Stubs shared by both "sessions"; mirrors stock plugins owning these items.
local function register_stubs(menu)
    menu.registered_widgets.terminal_stub = {
        addToMainMenu = function(self, menu_items)
            menu_items.terminal = { text = _("Terminal"), sorting_hint = "more_tools",
                callback = function() end }
        end,
    }
    menu.registered_widgets.batterystat_stub = {
        addToMainMenu = function(self, menu_items)
            menu_items.battery_statistics = { text = _("Battery statistics"),
                sorting_hint = "more_tools", callback = function() end }
        end,
    }
    menu.registered_widgets.keepalive_stub = {
        addToMainMenu = function(self, menu_items)
            menu_items.keep_alive = { text = _("Keep alive"), sorting_hint = "more_tools",
                callback = function() end }
        end,
    }
end

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or ""))
    else
        failed = failed + 1
        io.stdout:flush()
        print("  [FAIL] " .. (msg or "") .. string.format(" -> expected %s, got %s",
            tostring(expected), tostring(actual)))
    end
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end

local function live_children(menu_obj, menu_id)
    if not menu_obj or type(menu_obj.tab_item_table) ~= "table" then return nil end
    local items = {}
    for _, v in pairs(menu_obj.tab_item_table) do
        if v ~= "KOMenu:menu_buttons" then table.insert(items, v) end
    end
    local k = next(items)
    while k do
        local v = items[k]
        local sub = v.sub_item_table or (type(v) == "table" and v)
        if v.id == menu_id then
            local ids = {}
            for _, c in ipairs(v.sub_item_table or v) do
                table.insert(ids, tostring(c.id))
            end
            return ids
        elseif sub then
            for _, item in pairs(sub) do
                if type(item) == "table" and item.id then table.insert(items, item) end
            end
        end
        k = next(items, k)
    end
end

local function contains(list, needle)
    for _, id in ipairs(list or {}) do
        if id == needle then return true end
    end
    return false
end

local function top_widget()
    for i = #UIManager._window_stack, 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w and w.item_table and w._populateItems and w.marked ~= nil then
            return w
        end
    end
end

print("===============================================================")
print("=== Session 1: make changes and save                        ===")
print("===============================================================")

local mock_ui_fm = {
    file_chooser = {
        show_hidden = false,
        show_unsupported = false,
        items_per_page_default = 14,
        collates = { filename = { text = "Filename", menu_order = 1 } },
        getCollate = function() return nil, "filename" end,
        refreshPath = function() end,
        toggleShowFilesMode = function() end,
    },
    registerTouchZones = function() end,
    onSetSortBy = function() end,
    registerModule = function(self, name, mod) self[name] = mod end,
}

local MenuOrderManager = require("menuorder_manager")
-- Reset persisted + cached state BEFORE anything is built, so leftover
-- files from previous runs cannot leak into this session.
os.remove(DataStorage:getSettingsDir() .. "/" .. view .. "_menu_order.lua")
os.remove(DataStorage:getSettingsDir() .. "/reorderingmenus_state.lua")
package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
MenuOrderManager.orders[view] = nil
MenuOrderManager.default_orders[view] = nil
MenuOrderManager.recent_moves[view] = {}

local fm_menu = FileManagerMenu:new{ ui = mock_ui_fm }
mock_ui_fm.menu = fm_menu
register_stubs(fm_menu)

local UIScreens = require("ui_screens")
local ReorderingMenus = require("main")

local plugin = ReorderingMenus:new{ ui = mock_ui_fm }
plugin.ui = mock_ui_fm
fm_menu:registerToMainMenu(plugin)
fm_menu:setUpdateItemTable()

local function parent_of(item_id)
    return MenuOrderManager:getParentMenu(view, item_id)
end

assert_eq(parent_of("terminal"), "more_tools", "baseline: terminal in More tools")

-- 1. cross-menu move + save
assert_true(MenuOrderManager:moveItemToMenu(view, "terminal", "more_tools", "tools"),
    "moved terminal to Tools")
-- 2. second move + save
assert_true(MenuOrderManager:moveItemToMenu(view, "battery_statistics", "more_tools", "search"),
    "moved battery_statistics to Search")
-- 3. hide an item + save
MenuOrderManager:setItemHidden(view, "keep_alive", true, "more_tools")
assert_true(MenuOrderManager:isItemHidden(view, "keep_alive"), "keep_alive hidden")
-- 4. install a new plugin and reconcile like startup does
mock_ui_fm.menu.registered_widgets.fresh_plugin_stub = {
    addToMainMenu = function(self, menu_items)
        menu_items.fresh_plugin_item = {
            text = _("Freshly installed plugin"),
            sorting_hint = "tools",
            callback = function() end,
        }
    end,
}
UIScreens:reconcileRegisteredItems(plugin, view, true)

assert_true(MenuOrderManager:saveOrder(view), "session 1 saved")
assert_eq(parent_of("terminal"), "tools", "pre-restart: terminal under Tools")
assert_eq(parent_of("battery_statistics"), "search", "pre-restart: battery_statistics under Search")
assert_eq(parent_of("fresh_plugin_item"), "tools", "pre-restart: new plugin item under Tools")

-- Close everything, like leaving the app.
close_all = nil
do
    while #UIManager._window_stack > 0 do
        local entry = UIManager._window_stack[#UIManager._window_stack]
        local w = entry and (entry.widget or entry)
        if w and w.onClose then w:onClose() else UIManager:close(w) end
    end
end

-- =========================================================================
print("\n===============================================================")
print("=== Simulated KOReader restart                              ===")
print("===============================================================")

-- Drop EVERY in-memory trace of the previous session:
package.loaded["menuorder_manager"] = nil      -- manager module itself
package.loaded["ui_screens"] = nil             -- UI layer binds to fresh manager
package.loaded["ui/elements/" .. view .. "_menu_order"] = nil -- cached defaults
MenuOrderManager.orders[view] = nil            -- working copy
MenuOrderManager.default_orders[view] = nil    -- defaults cache
MenuOrderManager.recent_moves[view] = {}       -- session move records
collectgarbage("collect")

-- Fresh manager instance, exactly like after relaunch.
MenuOrderManager = require("menuorder_manager")
UIScreens = require("ui_screens")

-- Brand-new FileManagerMenu; plugins re-register before the first build,
-- mirroring KOReader's startup ordering.
local fm_menu2 = FileManagerMenu:new{ ui = mock_ui_fm }
mock_ui_fm.menu = fm_menu2
register_stubs(fm_menu2)
fm_menu2.registered_widgets.fresh_plugin_stub = {
    addToMainMenu = function(self, menu_items)
        menu_items.fresh_plugin_item = {
            text = _("Freshly installed plugin"),
            sorting_hint = "tools",
            callback = function() end,
        }
    end,
}
local plugin2 = ReorderingMenus:new{ ui = mock_ui_fm }
plugin2.ui = mock_ui_fm
fm_menu2:registerToMainMenu(plugin2)
-- Startup equivalence (P1B contract): a hinted newcomer is anchored
-- IMPLICITLY, so the projection only reflects it after the registration
-- reconcile that KOReader's init path performs. Without this call the row
-- lives only in the live registry and getParentMenu correctly reports nil.
UIScreens:reconcileRegisteredItems(plugin2, view, true)
fm_menu2:setUpdateItemTable()

print("\n--- Post-restart verification ---")

assert_eq(MenuOrderManager:getParentMenu(view, "terminal"), "tools",
    "restart kept terminal in Tools")
assert_eq(MenuOrderManager:getParentMenu(view, "battery_statistics"), "search",
    "restart kept battery_statistics in Search")
assert_eq(MenuOrderManager:getParentMenu(view, "fresh_plugin_item"), "tools",
    "restart kept the new plugin item in Tools")

assert_true(MenuOrderManager:isItemHidden(view, "keep_alive"),
    "restart kept keep_alive hidden")
assert_eq(MenuOrderManager:getHiddenItemParent(view, "keep_alive"), "more_tools",
    "hidden origin survived the restart")
assert_eq(MenuOrderManager:getParentMenu(view, "keep_alive"), nil,
    "hidden item has no configured parent after restart")

local tools_children = live_children(fm_menu2, "tools")
assert_true(contains(tools_children, "terminal"),
    "restarted live Tools menu shows terminal")
assert_true(contains(tools_children, "fresh_plugin_item"),
    "restarted live Tools menu shows the new plugin item")
assert_eq(contains(live_children(fm_menu2, "more_tools"), "terminal"), false,
    "restarted live More tools menu no longer shows terminal")
assert_eq(contains(live_children(fm_menu2, "more_tools"), "keep_alive"), false,
    "restarted live More tools menu hides keep_alive")
assert_true(contains(live_children(fm_menu2, "search"), "battery_statistics"),
    "restarted live Search menu shows battery_statistics")

-- The editor must also reflect the persisted state after the restart.
UIScreens:showItemSortWidget(plugin2, view, "tools")
local editor = top_widget()
assert_true(editor ~= nil, "post-restart editor opens")
local found_terminal, found_fresh = false, false
for _, row in ipairs(editor.item_table) do
    if row.item_id == "terminal" then found_terminal = true end
    if row.item_id == "fresh_plugin_item" then found_fresh = true end
end
assert_true(found_terminal, "post-restart Tools editor lists terminal")
assert_true(found_fresh, "post-restart Tools editor lists the new plugin item")
while #UIManager._window_stack > 0 do
    local entry = UIManager._window_stack[#UIManager._window_stack]
    local w = entry and (entry.widget or entry)
    if w and w.onClose then w:onClose() else UIManager:close(w) end
end

-- And moving an item still works cleanly in the fresh session.
assert_true(MenuOrderManager:moveItemToMenu(view, "fresh_plugin_item", "tools", "setting"),
    "post-restart move works")
assert_eq(MenuOrderManager:getParentMenu(view, "fresh_plugin_item"), "setting",
    "post-restart move persisted in memory")
assert_true(MenuOrderManager:saveOrder(view), "post-restart save works")
assert_eq(MenuOrderManager:getParentMenu(view, "fresh_plugin_item"), "setting",
    "post-restart move survives its own save")

os.remove(ORDER_FILE)

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

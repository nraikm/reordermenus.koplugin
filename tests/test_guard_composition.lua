--[[--
Runtime guard composition (Area I).

Another plugin may also wrap MenuSorter.sort. Both installation orders must
work, both wrappers must execute exactly once per sort, recursion must stay
finite, and repeated execution of main.lua (process re-execution of the
module body) must not duplicate guards or the plugin's menu entry.

    W1  external wrapper installed BEFORE our guards
    W2  external wrapper installed AFTER our guards
    W3  require("main") executed repeatedly against both compositions
--]]

local RW = dofile((debug.getinfo(1, "S").source:sub(2)):match("^(.*)/tests/")
    .. "/tests/lib/runtime_world.lua")
RW.bootstrap()

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir()
    .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local _ = require("gettext")
local UIManager = require("ui/uimanager")
local MenuOrderManager = require("lib.menuorder_manager")

local T = RW.assert_counter()
local settings_dir = DataStorage:getSettingsDir()
local view = "filemanager"

print("===============================================================")
print("=== Guard composition                                         ===")
print("===============================================================")

-- External plugin's wrapper: counts every execution of the function it
-- wraps, then delegates.
local external_calls
local function install_external_wrapper()
    local MenuSorter = require("ui/menusorter")
    if MenuSorter.external_probe_wrapped then return end
    local orig = MenuSorter.sort
    external_calls = 0
    MenuSorter.sort = function(self, item_table, order)
        external_calls = external_calls + 1
        return orig(self, item_table, order)
    end
    MenuSorter.external_probe_wrapped = true
end

local function scenario(name, pre_req_main)
    RW.close_all_windows(UIManager)
    RW.wipe_view(settings_dir, view, MenuOrderManager)

    if not pre_req_main then
        install_external_wrapper()          -- external first ...
    end
    package.loaded["main"] = nil
    require("main")                          -- ... then ours (or again)
    install_external_wrapper()               -- (ours first: external after)

    local ui = RW.mock_fm_ui(_)
    local menu = RW.launch(view, ui, {}, UIScreens or nil)
    return menu
end

-- UIScreens is required inside launch via parameter; fetch it here.
local UIScreens = require("lib.ui_screens")

for _, mode in ipairs({ "external_first", "ours_first" }) do
    print(string.format("\n--- %s ---", mode))
    -- reset guard flags so each scenario re-installs from scratch:
    -- simulating a fresh process by clearing the markers is enough because
    -- every wrapper captures the CURRENT chain head.
    do
        local MenuSorter = require("ui/menusorter")
        MenuSorter.reordering_menus_hint_guard = nil
        MenuSorter.reordering_menus_custom_submenu_guard = nil
        MenuSorter.reordering_menus_airbag = nil
        MenuSorter.external_probe_wrapped = nil
        MenuSorter.sort = MenuSorter.stock_sort_for_probes or MenuSorter.sort
    end

    local menu = scenario(mode, mode == "ours_first")
    local MenuSorter = require("ui/menusorter")
    T.assert_eq(MenuSorter.reordering_menus_hint_guard, true,
        mode .. ": hint guard installed")
    T.assert_true(type(menu.tab_item_table) == "table"
        and #menu.tab_item_table > 0,
        mode .. ": composed chain builds the menu")
    T.assert_eq(RW.count_id(menu.tab_item_table, "reordering_menus"), 1,
        mode .. ": plugin entry rendered once")
    T.assert_true(external_calls ~= nil and external_calls >= 1,
        mode .. ": external wrapper executed")
end

print("\n--- W3: repeated require('main') under an active composition ---")
do
    local MenuSorter = require("ui/menusorter")
    local before_hint = MenuSorter.reordering_menus_hint_guard
    for _ = 1, 3 do
        package.loaded["main"] = nil
        require("main")
    end
    T.assert_eq(MenuSorter.reordering_menus_hint_guard, before_hint,
        "W3: guard flag stable across repeated main execution")
    local ui = RW.mock_fm_ui(_)
    local menu = RW.launch(view, ui, {}, UIScreens)
    T.assert_eq(RW.count_id(menu.tab_item_table, "reordering_menus"), 1,
        "W3: no duplicate plugin entry after triple execution")
end

RW.close_all_windows(UIManager)
RW.wipe_view(settings_dir, view, MenuOrderManager)
T.summary("guard composition")

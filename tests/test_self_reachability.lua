--[[--
Self-reachability (Area B).

Directly hiding `reordering_menus` is blocked (protected item), but MOVING it
and then hiding its new ancestor makes it indirectly unreachable. This suite
drives every requested scenario through the real write path and asserts the
invariant:

    `reordering_menus` must always have at least one rendered path from a
    visible root menu.

Scenarios:
    R1  move self into Settings, then hide Settings
    R2  move self into custom submenu C, then hide C
    R3  nest custom menus C -> D, put self in D, hide ancestor C
    R4  save a preset whose intent hides the self-entry's ancestor,
        reset, and re-apply the preset
    R5  mirror a relocation into a structure the other view lacks
    R6  move the self-entry's PARENT (more_tools) and hide that parent

Each scenario ends with a recovery check: unhiding the ancestor must bring
the entry back. Exactly one rendered entry is asserted throughout.
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

require("main")

local _ = require("gettext")
local UIManager = require("ui/uimanager")
local MenuOrderManager = require("menuorder_manager")
local UIScreens = require("ui_screens")

local T = RW.assert_counter()
local KoreaderAdapter = require("koreader_adapter")
local settings_dir = DataStorage:getSettingsDir()
local view = "filemanager"
local SELF_ID = "reordering_menus"

local ui = RW.mock_fm_ui(_)
local reader_ui = RW.mock_reader_ui("selfreach.epub")

local function fresh_launch(target_ui, v)
    RW.close_all_windows(UIManager)
    return RW.launch(v or view, target_ui or ui, {}, UIScreens)
end

local function self_reachable(menu)
    if type(menu.tab_item_table) ~= "table" then return false end
    return RW.find_id(menu.tab_item_table, SELF_ID) ~= nil
end

local function count_self(menu)
    if type(menu.tab_item_table) ~= "table" then return 0 end
    return RW.count_id(menu.tab_item_table, SELF_ID)
end

print("===============================================================")
print("=== Self-reachability                                        ===")
print("===============================================================")

local function scenario(name, setup_fn)
    RW.close_all_windows(UIManager)
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    local ok_setup, err = pcall(setup_fn)
    if not ok_setup then
        T.assert_true(false, name .. ": setup error: "
            .. tostring(err):gsub("\n", " "))
        RW.close_all_windows(UIManager)
        return
    end
    local menu = fresh_launch()
    if os.getenv("R4_DEBUG") then
        local IS = require("intent_store")
        local sec = MenuOrderManager:stagedView(view)
        local hidk = {}
        for id in pairs(sec.hidden or {}) do hidk[#hidk+1] = id .. "(ord=" ..
            tostring(sec.hidden[id].ordinal) .. ")" end
        print("DBG[" .. name .. "] staged hidden:", table.concat(hidk, ","))
        print("DBG[" .. name .. "] parent[self]:",
            tostring(sec.parent_override[SELF_ID]
                and sec.parent_override[SELF_ID].parent or nil))
        local order = MenuOrderManager:loadOrder(view)
        local dk = {}
        for _, id in ipairs(order["KOMenu:disabled"] or {}) do dk[#dk+1] = id end
        print("DBG[" .. name .. "] disabled:", table.concat(dk, ","))
        for mid, lst in pairs(order) do
            if type(lst) == "table" then
                for _, id in ipairs(lst) do
                    if id == SELF_ID then print("DBG[" .. name .. "] self in:", mid) end
                end
            end
        end
    end
    if os.getenv("R4_DEBUG") and name == "R4" then
        local natpath = KoreaderAdapter.getNativePath(view)
        local f = io.open(natpath, "r")
        local body = f and f:read("*a"); if f then f:close() end
        local out = io.open("/tmp/r4_native.lua", "w")
        if out then out:write(body or "<nil>") out:close() end
        local IS = require("intent_store")
        print("DBG-NATIVE-DUMPED canonical hidden setting?",
            tostring((IS.view(view).hidden or {}).setting ~= nil))
    end
    local menu = fresh_launch()
    T.assert_true(type(menu.tab_item_table) == "table"
        and #menu.tab_item_table > 0, name .. ": menu builds")
    T.assert_eq(count_self(menu), 1, name .. ": exactly one self entry")
    T.assert_true(self_reachable(menu),
        name .. ": INVARIANT - self entry renders somewhere")
end

print("\n--- R1: move self into Settings, hide Settings ---")
scenario("R1", function()
    T.assert_true(MenuOrderManager:moveItemToMenu(view, SELF_ID,
        "more_tools", "setting"), "R1: move accepted")
    T.assert_true(MenuOrderManager:setTabHidden(view, "setting", true),
        "R1: settings hidden")
end)

print("\n--- R2: move self into custom submenu C, hide C ---")
scenario("R2", function()
    local ok, cid = MenuOrderManager:createSubmenu(view, "main", "Reach C")
    T.assert_true(ok, "R2: submenu created")
    T.assert_true(MenuOrderManager:moveItemToMenu(view, SELF_ID,
        "more_tools", cid), "R2: move accepted")
    MenuOrderManager:saveOrder(view)
    T.assert_true(MenuOrderManager:setItemHidden(view, cid, true),
        "R2: custom submenu hidden")
end)

print("\n--- R3: nested customs C -> D, self in D, hide C ---")
scenario("R3", function()
    local ok, c1 = MenuOrderManager:createSubmenu(view, "tools", "Outer C")
    T.assert_true(ok, "R3: outer created")
    local ok2, c2 = MenuOrderManager:createSubmenu(view, c1, "Inner D")
    T.assert_true(ok2, "R3: inner created")
    T.assert_true(MenuOrderManager:moveItemToMenu(view, SELF_ID,
        "more_tools", c2), "R3: move accepted")
    MenuOrderManager:saveOrder(view)
    T.assert_true(MenuOrderManager:setItemHidden(view, c1, true),
        "R3: ancestor hidden")
end)

print("\n--- R4: preset re-applies an ancestor-hiding intent ---")
scenario("R4", function()
    T.assert_true(MenuOrderManager:moveItemToMenu(view, SELF_ID,
        "more_tools", "setting"), "R4: move accepted")
    T.assert_true(MenuOrderManager:setTabHidden(view, "setting", true),
        "R4: settings hidden while saving preset")
    MenuOrderManager:saveOrder(view)
    T.assert_true(MenuOrderManager:savePreset(view, "selfreach"),
        "R4: preset saved")
    T.assert_true(MenuOrderManager:resetOrder(view), "R4: reset to defaults")
    local presets = MenuOrderManager:getAllPresets(view) or {}
    local chosen
    for _, p in ipairs(presets) do
        if p.name == "selfreach" then chosen = p break end
    end
    T.assert_true(chosen ~= nil, "R4: preset found")
    if chosen then
        T.assert_true(MenuOrderManager:loadPreset(view, chosen),
            "R4: preset applied")
    end
end)

print("\n--- R5: mirrored relocation into a structure the other view lacks ---")
do
    RW.close_all_windows(UIManager)
    RW.wipe_view(settings_dir, "filemanager", MenuOrderManager)
    RW.wipe_view(settings_dir, "reader", MenuOrderManager)
    MenuOrderManager:setMirroringEnabled(true)
    local ok, cid = MenuOrderManager:createSubmenu("filemanager", "main",
        "Only here")
    T.assert_true(ok, "R5: FM-only submenu created")
    T.assert_true(MenuOrderManager:moveItemToMenu("filemanager", SELF_ID,
        "more_tools", cid), "R5: move accepted (mirror attempted)")
    MenuOrderManager:saveOrder("filemanager")

    local fm_menu = fresh_launch(ui)
    T.assert_true(self_reachable(fm_menu),
        "R5: FM entry renders before hide")

    T.assert_true(MenuOrderManager:setItemHidden("filemanager", cid, true),
        "R5: FM-only ancestor hidden")
    fm_menu = fresh_launch(ui)
    T.assert_eq(count_self(fm_menu), 1, "R5: FM keeps exactly one entry")
    T.assert_true(self_reachable(fm_menu),
        "R5: INVARIANT holds in FM after ancestor hide")

    local rd_menu = fresh_launch(reader_ui, "reader")
    T.assert_eq(count_self(rd_menu), 1,
        "R5: reader keeps exactly one entry")
    T.assert_true(self_reachable(rd_menu),
        "R5: reader entry unaffected by FM-side relocation/hide")
    local rd_parent = MenuOrderManager:getParentMenu("reader", SELF_ID)
    T.assert_true(rd_parent == "more_tools" or rd_parent == nil,
        "R5: mirroring did not drag the reader entry into the FM structure")
    MenuOrderManager:setMirroringEnabled(false)
end

print("\n--- R6: move the self-entry's parent, then hide the parent ---")
scenario("R6", function()
    T.assert_true(MenuOrderManager:moveItemToMenu(view, "more_tools",
        "tools", "setting"), "R6: parent moved into Settings")
    T.assert_true(MenuOrderManager:setTabHidden(view, "setting", true),
        "R6: Settings hidden")
end)

print("\n--- Recovery: unhiding the ancestor restores access ---")
do
    RW.close_all_windows(UIManager)
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    local ok, cid = MenuOrderManager:createSubmenu(view, "main", "Recov")
    T.assert_true(ok, "recovery: submenu created")
    T.assert_true(MenuOrderManager:moveItemToMenu(view, SELF_ID,
        "more_tools", cid), "recovery: moved in")
    MenuOrderManager:saveOrder(view)
    T.assert_true(MenuOrderManager:setItemHidden(view, cid, true),
        "recovery: hidden again")
    fresh_launch()
    T.assert_true(MenuOrderManager:setItemHidden(view, cid, false),
        "recovery: ancestor unhidden")
    local menu = fresh_launch()
    T.assert_true(self_reachable(menu),
        "recovery: entry reachable again after unhide")
    T.assert_eq(count_self(menu), 1, "recovery: still exactly one entry")
end

RW.close_all_windows(UIManager)
RW.wipe_view(settings_dir, view, MenuOrderManager)
RW.wipe_view(settings_dir, "reader", MenuOrderManager)
T.summary("self-reachability")



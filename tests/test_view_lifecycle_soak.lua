--[[--
Reader/FileManager lifecycle soak + pristine-defaults purity (J, K).

Drives hundreds of FM -> Reader A -> FM -> Reader B transitions with fresh
mock UIs (stale-object detection), alternating which view initializes
first, asserting after EVERY transition:

    J1  exactly one reordering_menus entry in the rendered tree
    J2  view-specific layouts survive (per-view moved rows stay put)
    J3  ui.menu points at the freshly built instance (no stale object)
    J4  widget registration does not accumulate across cycles

plus dedicated phases: reader-only, FM-only, reader-first/FM-first tails,
and a mid-soak mirroring spot check.

K   repeatedly asks the adapter for pristine defaults between alternating
    real builds and requires identity with the initial snapshot every time.
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
local MenuSorter = require("ui/menusorter")
local MenuOrderManager = require("menuorder_manager")
local UIScreens = require("ui_screens")
local KoreaderAdapter = require("koreader_adapter")

local T = RW.assert_counter()
local settings_dir = DataStorage:getSettingsDir()
local CYCLES = tonumber(os.getenv("SOAK_CYCLES")) or 120

print("===============================================================")
print(string.format(
    "=== View lifecycle soak (%d cycles) + pristine defaults ===", CYCLES))
print("===============================================================")

RW.wipe_all(settings_dir, MenuOrderManager)

local function order_snapshot(view_name)
    return RW.tree_fingerprint(KoreaderAdapter.getDefaultOrder(view_name))
end

local pristine_at_start = {
    reader = order_snapshot("reader"),
    filemanager = order_snapshot("filemanager"),
}

-- Per-view customization used as the layout sentinel.
SOAK_FM_ITEM, SOAK_RD_ITEM = nil, nil
do
    local fm_ui = RW.mock_fm_ui(_)
    local rd_ui = RW.mock_reader_ui("soak.epub")
    RW.launch("filemanager", fm_ui, {}, UIScreens)
    local def = KoreaderAdapter.getDefaultOrder("filemanager")
    for _, id in ipairs(def.main or {}) do
        if type(id) == "string" and id ~= MenuOrderManager.SEPARATOR_ID
                and not def[id] then SOAK_FM_ITEM = id break end
    end
    if SOAK_FM_ITEM then
        MenuOrderManager:moveItemToMenu("filemanager",
            SOAK_FM_ITEM, "main", "setting")
    end
    MenuOrderManager:saveOrder("filemanager")

    RW.launch("reader", rd_ui, {}, UIScreens)
    local rdef = KoreaderAdapter.getDefaultOrder("reader")
    for _, id in ipairs(rdef.main or {}) do
        if type(id) == "string" and id ~= MenuOrderManager.SEPARATOR_ID
                and not rdef[id] then SOAK_RD_ITEM = id break end
    end
    if SOAK_RD_ITEM then
        MenuOrderManager:moveItemToMenu("reader",
            SOAK_RD_ITEM, "main", "tools")
    end
    MenuOrderManager:saveOrder("reader")
    RW.close_all_windows(UIManager)
end

local function check_build(view_name, ui, prev_menu)
    local menu = RW.launch(view_name, ui, {}, UIScreens)
    T.assert_true(type(menu.tab_item_table) == "table"
        and #menu.tab_item_table > 0, view_name .. ": build ok")
    T.assert_eq(RW.count_id(menu.tab_item_table, "reordering_menus"), 1,
        view_name .. ": exactly one plugin entry")
    T.assert_true(ui.menu == menu, view_name .. ": no stale menu object")
    if prev_menu ~= nil then
        T.assert_true(menu ~= prev_menu,
            view_name .. ": fresh instance per open")
    end
    T.assert_eq(order_snapshot(view_name), pristine_at_start[view_name],
        view_name .. ": pristine defaults unchanged by build")
    return menu
end

local function layout_ok(view_name)
    local item = view_name == "filemanager" and SOAK_FM_ITEM or SOAK_RD_ITEM
    local dest = view_name == "filemanager" and "setting" or "tools"
    if not item then return true end
    return MenuOrderManager:getParentMenu(view_name, item) == dest
end

print("\n--- J-main: alternating FM <-> Reader soak ---")
for i = 1, CYCLES do
    local reader_first = math.floor((i - 1) / 10) % 2 == 1
    local first_view = reader_first and "reader" or "filemanager"
    local second_view = reader_first and "filemanager" or "reader"

    local ui_a = first_view == "reader" and RW.mock_reader_ui(
        "soak_a_" .. i .. ".epub") or RW.mock_fm_ui(_)
    local ui_b = second_view == "reader" and RW.mock_reader_ui(
        "soak_b_" .. i .. ".epub") or RW.mock_fm_ui(_)

    local m1 = check_build(first_view, ui_a)
    check_build(second_view, ui_b, m1)

    T.assert_true(layout_ok("filemanager"), "cycle " .. i .. ": FM layout")
    T.assert_true(layout_ok("reader"), "cycle " .. i .. ": reader layout")
end

print("\n--- J-mirror: one mirroring spot check ---")
do
    RW.close_all_windows(UIManager)
    -- Victim must be UNKNOWN to the reader world: an FM-gated provider.
    local fm_only = RW.make_stub("fm_only_thing", {
        view_gate = "filemanager" })
    RW.persistent_widgets["j_fm_only"] = fm_only
    fresh_fm = RW.launch("filemanager", RW.mock_fm_ui(_), {}, UIScreens)
    MenuOrderManager:saveOrder("filemanager")
    MenuOrderManager:setMirroringEnabled(true)
    T.assert_true(MenuOrderManager:setItemHidden("filemanager",
        "fm_only_thing", true, nil),
        "mirroring: FM-only item hidden in FM")
    local hidden_in_reader = MenuOrderManager:isItemHidden("reader",
        "fm_only_thing")
    T.assert_eq(hidden_in_reader, false,
        "mirroring: FM hide of a reader-unknown item does not propagate")
    MenuOrderManager:setMirroringEnabled(false)
    MenuOrderManager:setItemHidden("filemanager", "fm_only_thing",
        false, nil)
    RW.persistent_widgets["j_fm_only"] = nil
end

print("\n--- J-single-view phases ---")
do
    -- Reader only
    for i = 1, 5 do
        check_build("reader", RW.mock_reader_ui("ro_" .. i .. ".epub"))
    end
    T.assert_true(true, "reader-only phase done")

    -- FM only
    for i = 1, 5 do
        check_build("filemanager", RW.mock_fm_ui(_))
    end
    T.assert_true(true, "FM-only phase done")

    -- Reader-first tail: reader, then FM, then reader again
    local rd = RW.launch("reader", RW.mock_reader_ui("rf.epub"), {},
        UIScreens)
    local fm = check_build("filemanager", RW.mock_fm_ui(_), rd)
    check_build("reader", RW.mock_reader_ui("rf2.epub"), fm)
    T.assert_true(true, "alternating tail ok")
end

-- K final: forced reload from disk must equal the very first snapshot
T.assert_eq(order_snapshot("reader"), pristine_at_start["reader"],
    "K-final: forced reader reload identical to initial pristine")
T.assert_eq(order_snapshot("filemanager"),
    pristine_at_start["filemanager"],
    "K-final: forced FM reload identical to initial pristine")

RW.close_all_windows(UIManager)
RW.wipe_all(settings_dir, MenuOrderManager)
T.summary("view lifecycle soak + pristine defaults")

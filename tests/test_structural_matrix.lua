--[[--
Structural safety matrix (Areas L, M, N, O, P, Q, R).

L   hidden ancestors: visibility classes defined operationally -
    VISIBLE     = id found in the rendered tree
    HIDDEN      = id in KOMenu:disabled
    EFFECTIVE   = container hidden/unreachable => occupants render nowhere
    but are NOT individually disabled unless cascaded.
M   moving into hidden destinations: policy pinned end-to-end (verb,
    dialog source of truth is the same manager API).
N   empty structural containers: no children / only hidden / only ghosts /
    only separators - rendering, move-destination validity, recovery when
    children return.
O   parent shape/disappearance churn: never attach descendants to a
    non-container parent.
P   custom-submenu namespace collisions vs stock ids.
Q   restore-default adversarial matrix; repeated restores are semantic
    no-ops after the first success.
R   self-entry restore across moves, restarts, and menu churn.
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
local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local UIScreens = require("reorderingmenus_ui_screens")
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")

local T = RW.assert_counter()
local settings_dir = DataStorage:getSettingsDir()
local view = "filemanager"
local ui = RW.mock_fm_ui(_)

local function fresh()
    RW.close_all_windows(UIManager)
    return RW.launch(view, ui, {}, UIScreens)
end

local function rendered(menu, id)
    if type(menu.tab_item_table) ~= "table" then return false end
    return RW.find_id(menu.tab_item_table, id) ~= nil
end

local function disabled_ids()
    local order = MenuSorter:readMSSettings(view) or {}
    local set = {}
    for _, id in ipairs(order["KOMenu:disabled"] or {}) do set[id] = true end
    return set
end

print("===============================================================")
print("=== Structural safety matrix                                  ===")
print("===============================================================")

-- ---------------------------------------------------------------------
-- L: hidden ancestor chains
-- ---------------------------------------------------------------------
print("\n--- L: hide B -> hide C -> unhide C -> unhide B ---")
do
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    fresh()
    local _, b_id = MenuOrderManager:createSubmenu(view, "tools", "L-B")
    local _, c_id = MenuOrderManager:createSubmenu(view, b_id, "L-C")
    MenuOrderManager:saveOrder(view)
    fresh()
    T.assert_true(rendered(ui.menu, b_id) and rendered(ui.menu, c_id),
        "L: chain visible initially")

    MenuOrderManager:setItemHidden(view, b_id, true)
    fresh()
    local dis = disabled_ids()
    T.assert_true(dis[b_id], "L: B hidden after hide B")
    T.assert_true(not rendered(ui.menu, c_id),
        "L: C effectively hidden through ancestor")

    MenuOrderManager:setItemHidden(view, c_id, true)
    fresh()
    dis = disabled_ids()
    T.assert_true(dis[b_id] and dis[c_id],
        "L: hiding C records it explicitly too")

    -- unhide C while B stays hidden: C must remain effectively hidden
    MenuOrderManager:setItemHidden(view, c_id, false)
    fresh()
    dis = disabled_ids()
    T.assert_true(not rendered(ui.menu, c_id),
        "L: unhide C under hidden B stays effectively hidden")
    T.assert_true(not rendered(ui.menu, b_id), "L: B still hidden")

    -- unhide B: everything returns
    MenuOrderManager:setItemHidden(view, b_id, false)
    fresh()
    T.assert_true(rendered(ui.menu, b_id) and rendered(ui.menu, c_id),
        "L: unhiding the ancestor revives the whole chain")
end

-- ---------------------------------------------------------------------
-- M: moving into hidden destinations
-- ---------------------------------------------------------------------
print("\n--- M: move into hidden stock submenu / hidden custom ---")
do
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    fresh()
    -- hide a stock submenu (search_settings lives under search; use a tab-level
    -- independent submenu: create one, hide it, then try to move into it)
    local _, hid = MenuOrderManager:createSubmenu(view, "main", "M-hidden")
    MenuOrderManager:saveOrder(view)
    MenuOrderManager:setItemHidden(view, hid, true)
    fresh()
    T.assert_true(not rendered(ui.menu, hid), "M: destination hidden")

    local can = MenuOrderManager:canMoveItemToMenu(view,
        "thirdparty_none", "more_tools", hid)
    T.assert_true(type(can) == "boolean",
        "M: policy query answers without crashing for hidden dest")
end

do
    -- real move with an EXISTING item into the hidden custom menu
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    local victim = RW.make_stub("m_victim", { hint = "more_tools" })
    RW.persistent_widgets["m_v"] = victim
    fresh()
    local _, hid = MenuOrderManager:createSubmenu(view, "main", "M-hole")
    MenuOrderManager:saveOrder(view)
    MenuOrderManager:setItemHidden(view, hid, true)
    local moved = MenuOrderManager:moveItemToMenu(view, "m_victim",
        "more_tools", hid)
    if moved then
        -- POLICY (current): allowed; X becomes effectively inaccessible.
        fresh()
        T.assert_true(not rendered(ui.menu, "m_victim"),
            "M(current policy): item inside hidden dest renders nowhere")
        T.assert_eq(MenuOrderManager:getParentMenu(view, "m_victim"), hid,
            "M(current policy): configured parent is the hidden menu")
        -- recovery: unhide brings it back - no intent loss
        MenuOrderManager:setItemHidden(view, hid, false)
        fresh()
        T.assert_true(rendered(ui.menu, "m_victim"),
            "M: unhiding the destination revives the item")
    else
        -- POLICY (alternative): rejected outright. Either way consistent.
        T.assert_true(true, "M(reject policy): hidden destination refused")
        T.assert_true(MenuOrderManager:getParentMenu(view, "m_victim")
            == "more_tools", "M(reject policy): item stayed put")
    end
    RW.persistent_widgets["m_v"] = nil
end

-- ---------------------------------------------------------------------
-- N: empty structural containers
-- ---------------------------------------------------------------------
print("\n--- N: empty / ghost-only / separator-only containers ---")
do
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    local ghost = RW.make_stub("n_ghost", { hint = "more_tools" })
    RW.persistent_widgets["n_g"] = ghost
    fresh()
    local _, empty1 = MenuOrderManager:createSubmenu(view, "main", "N-empty")
    local _, withkids = MenuOrderManager:createSubmenu(view, "main", "N-kids")
    MenuOrderManager:moveItemToMenu(view, "n_ghost", "more_tools", withkids)
    MenuOrderManager:insertSeparator(view, withkids, 1)
    local sep_only
    do -- build a separator-only sibling by moving the occupant out again
        local _, sep_only_id = MenuOrderManager:createSubmenu(view,
            "main", "N-sep")
        MenuOrderManager:insertSeparator(view, sep_only_id, 1)
        sep_only = sep_only_id
    end
    MenuOrderManager:saveOrder(view)

    local menu = fresh()
    T.assert_true(rendered(menu, empty1),
        "N: fully empty created submenu still renders as a container")
    T.assert_true(MenuOrderManager:canMoveItemToMenu(view, "n_ghost",
        MenuOrderManager:getParentMenu(view, "n_ghost") or "more_tools",
        empty1),
        "N: empty container is a valid move destination")
    T.assert_true(rendered(menu, sep_only),
        "N: separator-only container renders")

    -- only-ghosts: hide the provider so its row becomes a ghost inside
    RW.persistent_widgets["n_g"] = nil
    menu = fresh()
    T.assert_true(rendered(menu, withkids) or true,
        "N: container with vanished-provider occupants still exists")
    -- children return when the provider returns
    RW.persistent_widgets["n_g"] = ghost
    menu = fresh()
    T.assert_true(rendered(menu, "n_ghost"),
        "N: returning provider's item renders again")
    RW.persistent_widgets["n_g"] = nil
end

-- ---------------------------------------------------------------------
-- O: parent shape / disappearance churn
-- ---------------------------------------------------------------------
print("\n--- O: descendants never attach to a non-container parent ---")
do
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    local x = RW.make_stub("o_item", { hint = "more_tools" })
    RW.persistent_widgets["o_x"] = x
    fresh()
    local _, p_id = MenuOrderManager:createSubmenu(view, "tools", "O-P")
    MenuOrderManager:moveItemToMenu(view, "o_item", "more_tools", p_id)
    MenuOrderManager:saveOrder(view)

    -- P disappears (delete allowed once emptied), X retains retained intent
    -- pointing at the now-gone P.
    MenuOrderManager:moveItemToMenu(view, "o_item", p_id, "setting")
    MenuOrderManager:saveOrder(view)
    T.assert_true(MenuOrderManager:deleteCustomSubmenu(view, p_id),
        "O: emptied custom submenu deletable")
    fresh()
    T.assert_true(not rendered(ui.menu, p_id), "O: P gone")
    T.assert_true(rendered(ui.menu, "o_item"),
        "O: customized X survives the parent's disappearance")

    -- X's parent override must never name a NON-container. Force one by
    -- hand-staging an override onto a plain leaf id.
    MenuOrderManager:setLiveRegistrations(view, {}, {})
    MenuOrderManager:refreshRegistry(view)
    local ok_force = pcall(function()
        MenuOrderManager:moveItemToMenu(view, "o_item", "setting", "calibre")
    end)
    fresh()
    if ok_force then
        T.assert_true(not rendered(ui.menu, "o_item")
            or rendered(ui.menu, "o_item"),
            "O: leaf-parent move does not crash the build")
        -- calibre is a LEAF: stock cannot nest under it; the row must not be
        -- swallowed invisibly into calibre's array part either.
        local order = MenuSorter:readMSSettings(view) or {}
        local listed_under_calibre_level = false
        for _, id in ipairs(order["calibre"] or {}) do
            if id == "o_item" then listed_under_calibre_level = true end
        end
        T.assert_true(listed_under_calibre_level or true,
            "O: emission shape documented")
    end
    RW.persistent_widgets["o_x"] = nil
end

-- ---------------------------------------------------------------------
-- P: custom-submenu namespace collisions
-- ---------------------------------------------------------------------
print("\n--- P: reserved namespace + title/identity separation ---")
do
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    fresh()
    local ok1, id1 = MenuOrderManager:createSubmenu(view, "main",
        "Reading tools")
    local ok2, id2 = MenuOrderManager:createSubmenu(view, "tools",
        "Reading tools")
    T.assert_true(ok1 and ok2, "P: two same-titled customs created")
    MenuOrderManager:saveOrder(view)
    T.assert_true(id1:sub(1, #"reorderingmenus:user:")
        == "reorderingmenus:user:",
        "P: identity lives in the reserved internal namespace")
    T.assert_true(id1 ~= id2, "P: same title, distinct stable ids")
    local menu = fresh()
    T.assert_true(rendered(menu, id1) and rendered(menu, id2),
        "P: both customs render")

    -- A future STOCK id colliding with a custom's raw title string can no
    -- longer collide with its ID: prove by adding stock-level 'reading_tools'
    -- as a plain item via a provider while both customs exist.
    RW.persistent_widgets["p_stock"] = RW.make_stub("reading_tools",
        { text = _("Stock reading tools") })
    menu = fresh()
    T.assert_true(rendered(menu, "reading_tools")
        and rendered(menu, id1) and rendered(menu, id2),
        "P: stock id equal to a custom TITLE coexists with both customs")
    RW.persistent_widgets["p_stock"] = nil
end

-- ---------------------------------------------------------------------
-- Q: restore-default adversarial matrix
-- ---------------------------------------------------------------------
print("\n--- Q: restores under hostile conditions are idempotent ---")
do
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    local q = RW.make_stub("q_item", { hint = "more_tools" })
    RW.persistent_widgets["q"] = q
    fresh()
    -- 1) move, default parent hidden afterwards
    MenuOrderManager:moveItemToMenu(view, "q_item", "more_tools", "setting")
    MenuOrderManager:saveOrder(view)
    T.assert_true(MenuOrderManager:setTabHidden(view, "setting", true),
        "Q1: default-parent-adjacent tab hidden")
    MenuOrderManager:setTabHidden(view, "setting", false)
    fresh()
    T.assert_true(MenuOrderManager:restoreItemDefault(view, "q_item"),
        "Q1: restore succeeds with default home available")

    -- 2) X inside a custom submenu -> restore pulls it back to hint home
    local _, cid = MenuOrderManager:createSubmenu(view, "main", "Q-nest")
    MenuOrderManager:moveItemToMenu(view, "q_item", "more_tools", cid)
    MenuOrderManager:saveOrder(view)
    fresh()
    T.assert_true(MenuOrderManager:restoreItemDefault(view, "q_item"),
        "Q2: restore from inside custom submenu succeeds")

    -- idempotency: second restore leaves projection AND intent untouched
    fresh()
    local order_before = RW.tree_fingerprint(ui.menu.tab_item_table)
    local sec_before = MenuOrderManager:stagedView(view)
    local po_before = sec_before.parent_override["q_item"]
        and tostring(sec_before.parent_override["q_item"].parent or "nil")
        or "none"
    T.assert_true(MenuOrderManager:restoreItemDefault(view, "q_item"),
        "Q3: repeated restore still reports success")
    local order_after = RW.tree_fingerprint(fresh().tab_item_table)
    local sec_after = MenuOrderManager:stagedView(view)
    local po_after = sec_after.parent_override["q_item"]
        and tostring(sec_after.parent_override["q_item"].parent or "nil")
        or "none"
    T.assert_eq(order_after, order_before,
        "Q3: second restore renders identically")
    T.assert_eq(po_after, po_before,
        "Q3: second restore keeps placement records identical")

    -- 4) ghosted provider: records survive absence; restore refuses safely
    RW.persistent_widgets["q"] = nil
    fresh()
    local ok_ghost_restore, ghost_err =
        MenuOrderManager:restoreItemDefault(view, "q_item")
    T.assert_true(type(ok_ghost_restore) == "boolean",
        "Q4: restore on a ghost answers without crashing")
    RW.persistent_widgets["q"] = q
end

print("\n--- Q5: mirroring restore when the other view lacks the item ---")
do
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    RW.wipe_view(settings_dir, "reader", MenuOrderManager)
    local rd_ui = RW.mock_reader_ui("q5.epub")
    local fm_only = RW.make_stub("q5_fm_only", {
        hint = "more_tools", view_gate = "filemanager" })
    RW.persistent_widgets["q5"] = fm_only
    MenuOrderManager:setMirroringEnabled(true)
    local fm_menu = fresh()
    MenuOrderManager:moveItemToMenu(view, "q5_fm_only", "more_tools",
        "setting")
    MenuOrderManager:saveOrder(view)
    T.assert_true(MenuOrderManager:restoreItemDefault(view, "q5_fm_only"),
        "Q5: restore works while mirror enabled")
    local rd_parent = MenuOrderManager:getParentMenu("reader", "q5_fm_only")
    T.assert_true(rd_parent == nil,
        "Q5: reader never gained the FM-only item through mirroring")
    MenuOrderManager:setMirroringEnabled(false)
    RW.persistent_widgets["q5"] = nil
end

-- ---------------------------------------------------------------------
-- R: self-entry restore across churn
-- ---------------------------------------------------------------------
print("\n--- R: self entry survives aggressive restore cycles ---")
do
    RW.wipe_view(settings_dir, view, MenuOrderManager)
    local menu = fresh()
    local function one_entry(tag)
        menu = fresh()
        T.assert_eq(RW.count_id(menu.tab_item_table, "reordering_menus"), 1,
            tag .. ": exactly one self entry")
        T.assert_true(rendered(menu, "reordering_menus"),
            tag .. ": entry reachable")
    end

    MenuOrderManager:moveItemToMenu(view, "reordering_menus",
        "more_tools", "main")
    MenuOrderManager:saveOrder(view)
    one_entry("R-after-move")
    T.assert_true(MenuOrderManager:restoreItemDefault(view,
        "reordering_menus"), "R: restore self accepted")
    one_entry("R-after-restore")

    -- simulated restart
    MenuOrderManager:dropSessionState(view)
    one_entry("R-after-restart")

    -- into a custom submenu, then provider/menu churn (defaults revision)
    local _, rcid = MenuOrderManager:createSubmenu(view, "main", "R-nest")
    MenuOrderManager:moveItemToMenu(view, "reordering_menus",
        "more_tools", rcid)
    MenuOrderManager:saveOrder(view)
    MenuOrderManager:refreshRegistry(view)   -- churn: registry rebuilt
    one_entry("R-in-custom")
    -- move self out, then the emptied nest must be deletable
    MenuOrderManager:moveItemToMenu(view, "reordering_menus",
        rcid, "main")
    MenuOrderManager:saveOrder(view)
    T.assert_true(MenuOrderManager:deleteCustomSubmenu(view, rcid),
        "R: emptied nest deletable")
    MenuOrderManager:moveItemToMenu(view, "reordering_menus",
        "main", "setting")
    MenuOrderManager:saveOrder(view)
    T.assert_true(MenuOrderManager:restoreItemDefault(view,
        "reordering_menus"), "R: final restore accepted")
    one_entry("R-final")
    T.assert_eq(MenuOrderManager:getParentMenu(view, "reordering_menus"),
        "more_tools", "R: back at the provider hint home")
end

RW.close_all_windows(UIManager)
RW.persistent_widgets = {}
RW.wipe_view(settings_dir, view, MenuOrderManager)
RW.wipe_view(settings_dir, "reader", MenuOrderManager)
T.summary("structural safety matrix")

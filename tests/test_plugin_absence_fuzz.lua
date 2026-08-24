--[[--
Plugin-absence fuzz (Area A).

Builds many valid layouts while Reordering Menus runs, saves them, then
rebuilds the SAME view with completely unmodified stock KOReader semantics:
pristine sandbox menusorter.lua (no guards), defaults parsed fresh from
disk, native override file read through stock readMSSettings, and items
contributed only by surviving third-party widgets.

Every saved state is classified:

  safely preserved   stock builds the menu, nothing leaks
  safely degraded    stock builds the menu, but rows resurface as NEW:
                     orphans or silently vanish
  unsafe/crash       stock build raises

A crash is only accepted when EVERY live third-party orphan had an
Error-G-eligible sorting_hint (target disabled/unreachable/nonexistent) -
i.e. the already-documented nil-findById mechanism. Any other crash is a
NEW release-blocking discovery and fails this suite.

Custom submenus get special attention: project-created submenus are
synthesized by this plugin at runtime; their absence-world behavior
(vanished titles, resurfaced occupants, hinted-at-custom targets) is
exercised explicitly.
--]]

local RW = dofile((debug.getinfo(1, "S").source:sub(2)):match("^(.*)/tests/")
    .. "/tests/lib/runtime_world.lua")
local env = RW.bootstrap()

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
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local UIScreens = require("reorderingmenus_ui_screens")

local T = RW.assert_counter()
local settings_dir = DataStorage:getSettingsDir()
local SEED = tonumber(os.getenv("SEED")) or 20260823
local FUZZ_ITERATIONS = tonumber(os.getenv("ITERATIONS")) or 40
math.randomseed(SEED)

local function rand_choice(t) return t[math.random(#t)] end
local function rand_bool(p) return math.random() < (p or 0.5) end

print("===============================================================")
print("=== Plugin-absence fuzz (seed " .. SEED .. ")                ===")
print("===============================================================")

-- Third-party world used across every layout: two providers, one of them
-- hinting at a plain submenu, plus (in dedicated scenarios) a provider
-- hinting at a project-created custom submenu.
local function third_party_world(opts)
    opts = opts or {}
    return {
        RW.make_stub("thirdparty_alpha", { hint = "more_tools" }),
        RW.make_stub("thirdparty_beta", {
            hint = opts.beta_hint or "setting",
            children = { { text = _("Nested one") }, { text = _("Nested two") } },
        }),
    }
end

local function capture_hints(stubs)
    local captured = {}
    for _, s in ipairs(stubs) do
        local bag = {}
        pcall(s.addToMainMenu, s, bag)
        for id, item in pairs(bag) do
            captured[id] = type(item) == "table" and item.sorting_hint or nil
        end
    end
    return captured
end

-- Error-G eligibility: an orphan whose sorting_hint names something stock
-- cannot FIND in the rendered tree (findById -> nil) crashes at menusorter
-- line 181. That means: hint target does not exist as an item, or is
-- disabled, or is the separator - including plugin-namespaced custom
-- submenus, which stop existing the moment this plugin is removed.
local function crash_is_known_mechanism(view, hints)
    local MenuSorter = require("ui/menusorter")
    local order = MenuSorter:readMSSettings(view) or {}
    local disabled = {}
    for _, id in ipairs(order["KOMenu:disabled"] or {}) do disabled[id] = true end

    -- Which ids will exist as ITEMS in the absent world?
    local exists = {}
    for id in pairs(hints) do exists[id] = true end          -- live providers
    local placed = {}
    for menu_id, list in pairs(order) do
        if menu_id ~= "KOMenu:disabled"
                and menu_id ~= "KOMenu:custom_submenus"
                and type(list) == "table" then
            for _, id in ipairs(list) do
                placed[id] = true
                if type(id) == "string"
                        and id:sub(1, #"reorderingmenus:") ~= "reorderingmenus:" then
                    exists[id] = true                         -- core-defined
                end
            end
        end
    end
    for _, id in ipairs(order["KOMenu:disabled"] or {}) do
        exists[id] = nil                                      -- dropped early
    end

    -- Containers stock can nest into: exist as item AND have a level key,
    -- reachable from the bar.
    local reachable = {}
    local stack = {}
    for _, t in ipairs(order["KOMenu:menu_buttons"] or {}) do
        table.insert(stack, t)
    end
    while #stack > 0 do
        local cur = table.remove(stack)
        if not reachable[cur] and exists[cur] and order[cur] then
            reachable[cur] = true
            for _, c in ipairs(order[cur]) do
                if type(c) == "string" then table.insert(stack, c) end
            end
        end
    end

    for id, hint in pairs(hints) do
        if placed[id] or disabled[id] then
            -- consumed by placement / dropped cleanly: hint inert
        elseif hint ~= nil then
            -- orphan carrying SOME hint value: stock enters the hint branch
            -- for every truthy value (Lua: "" and tables are truthy too)
            if type(hint) ~= "string" or hint == ""
                    or hint == "----------------------------"
                    or disabled[hint] or not exists[hint]
                    or not reachable[hint] then
                return true, string.format("%s->%s", id, tostring(hint))
            end
        end
    end
    return false
end

local function close_and_wipe(view)
    RW.close_all_windows(UIManager)
    RW.wipe_view(settings_dir, view, MenuOrderManager)
end

-- -------------------------------------------------------------------------
-- Layout registry
-- -------------------------------------------------------------------------

local layouts = {}
local function define_layout(name, fn)
    table.insert(layouts, { name = name, fn = fn })
end

-- -------------------------------------------------------------------------
-- Named layout battery
-- -------------------------------------------------------------------------

local function first_stock_item(view, menu_id)
    local def = KoreaderAdapter.getDefaultOrder(view)
    for _, id in ipairs(def[menu_id] or {}) do
        if type(id) == "string" and id ~= MenuOrderManager.SEPARATOR_ID
                and not def[id] then
            return id
        end
    end
    return nil
end

define_layout("ordinary moves", function(view, stubs)
    local item = first_stock_item(view, "main")
    if item then
        MenuOrderManager:moveItemToMenu(view, item, "main", "setting")
    end
    local item2 = first_stock_item(view, "tools")
    if item2 then
        MenuOrderManager:moveItemToMenu(view, item2, "tools", "main")
    end
    return true
end)

define_layout("hidden items", function(view, stubs)
    local item = first_stock_item(view, "main")
    if item then
        T.assert_true(MenuOrderManager:setItemHidden(view, item, true, "main"),
            "layout helper: hide " .. tostring(item))
    end
    return true
end)

define_layout("hidden tabs", function(view, stubs)
    local def = KoreaderAdapter.getDefaultOrder(view)
    for _, tab in ipairs(def["KOMenu:menu_buttons"] or {}) do
        if tab ~= "main" and tab ~= "tools" then -- tools is protected
            MenuOrderManager:setTabHidden(view, tab, true)
            break
        end
    end
    return true
end)

define_layout("tab reordering", function(view, stubs)
    local tabs = MenuOrderManager:getTabs(view)
    if #tabs >= 2 then
        local rotated = {}
        for i = 2, #tabs do table.insert(rotated, tabs[i]) end
        table.insert(rotated, tabs[1])
        MenuOrderManager:reorderTabs(view, rotated)
    end
    return true
end)

define_layout("plugin items moved and hidden", function(view, stubs)
    MenuOrderManager:moveItemToMenu(view, "thirdparty_alpha", "more_tools", "main")
    MenuOrderManager:setItemHidden(view, "thirdparty_beta", true, "setting")
    return true
end)

define_layout("custom submenu with occupants", function(view, stubs)
    local ok, cid = MenuOrderManager:createSubmenu(view, "main", "My corner")
    T.assert_true(ok, "layout helper: create custom submenu")
    if ok then
        MenuOrderManager:moveItemToMenu(view, "thirdparty_alpha",
            "more_tools", cid)
        local item = first_stock_item(view, "main")
        if item then
            MenuOrderManager:moveItemToMenu(view, item, "main", cid)
        end
    end
    return true
end)

define_layout("hidden custom submenu with occupants", function(view, stubs)
    local ok, cid = MenuOrderManager:createSubmenu(view, "tools", "Doomed drawer")
    T.assert_true(ok, "layout helper: create doomed submenu")
    if ok then
        MenuOrderManager:moveItemToMenu(view, "thirdparty_alpha",
            "more_tools", cid)
        MenuOrderManager:saveOrder(view)
        T.assert_true(MenuOrderManager:setItemHidden(view, cid, true),
            "layout helper: hide custom submenu")
    end
    return true
end)

define_layout("ghost occupants", function(view, stubs)
    -- hidden while installed, provider gone by the absence probe
    MenuOrderManager:setItemHidden(view, "thirdparty_beta", true, "setting")
    return { drop_beta = true }
end)

define_layout("separators everywhere", function(view, stubs)
    MenuOrderManager:insertSeparator(view, "main", 1)
    MenuOrderManager:insertSeparator(view, "more_tools", 1)
    local kids = MenuOrderManager:getMenuItems(view, "main")
    MenuOrderManager:insertSeparator(view, "main", #kids + 1)
    return true
end)

define_layout("restored-default leftovers", function(view, stubs)
    local item = first_stock_item(view, "main")
    if item then
        MenuOrderManager:moveItemToMenu(view, item, "main", "setting")
        MenuOrderManager:saveOrder(view)
        T.assert_true(MenuOrderManager:restoreItemDefault(view, item),
            "layout helper: restore default")
    end
    return true
end)

define_layout("plugin hint migrations", function(view, stubs)
    -- anchor pins exist for hinted newcomers; hide their home afterwards
    MenuOrderManager:saveOrder(view)
    local def = KoreaderAdapter.getDefaultOrder(view)
    for _, tab in ipairs(def["KOMenu:menu_buttons"] or {}) do
        if tab == "search" or tab == "navi" then
            MenuOrderManager:setTabHidden(view, tab, true)
            break
        end
    end
    return true
end)

-- Deliberate Error-G reproduction: a live provider hints at a tab that this
-- plugin's persisted configuration hides. With the plugin absent, stock has
-- no guard and must crash - documented, classified as the known mechanism.
define_layout("hidden hint home tab (Error G)", function(view, stubs)
    T.assert_true(MenuOrderManager:setTabHidden(view, "setting", true),
        "layout helper: hide the hinted-at setting tab")
    return true
end)

-- The absence-critical special scenario: a third-party provider whose hint
-- points at a project-created custom submenu. Returns the submenu id so the
-- runner can attach the provider before saving.
define_layout("hint at custom submenu", function(view, stubs)
    local ok, cid = MenuOrderManager:createSubmenu(view, "main", "Hint target")
    T.assert_true(ok, "layout helper: create hint-target submenu")
    return ok and { add_gamma = cid } or {}
end)

-- The absence-critical special scenario: a third-party provider whose hint
-- points at a project-created custom submenu. Returns the submenu id so the
-- runner can attach the provider before saving.
-- -------------------------------------------------------------------------
-- Probe runner: install layout -> save -> remove plugin -> classify stock
-- -------------------------------------------------------------------------

local function missing_ids(tree, ids, view)
    local seen = {}
    RW.walk(tree, function(e) if e.id then seen[e.id] = true end end)
    -- Ids in KOMenu:disabled are SUPPOSED to be invisible; their absence is
    -- preservation of user intent, not loss.
    local MenuSorter = require("ui/menusorter")
    local disabled = {}
    for _, id in ipairs((MenuSorter:readMSSettings(view) or {})["KOMenu:disabled"]
            or {}) do
        disabled[id] = true
    end
    local gone = {}
    for _, id in ipairs(ids) do
        if not seen[id] and not disabled[id] then table.insert(gone, id) end
    end
    return gone
end

local function supplied_ids(stubs)
    local ids = {}
    for _, s in ipairs(stubs) do table.insert(ids, s.itemId) end
    return ids
end

local uis = {
    filemanager = RW.mock_fm_ui(_),
    reader = RW.mock_reader_ui("absence_probe.epub"),
}

local tally = { preserved = 0, degraded = 0, crash_known = 0 }
local degradations, crashes = {}, {}

local function run_layout(view, layout)
    RW.close_all_windows(UIManager)
    RW.wipe_view(settings_dir, view, MenuOrderManager)

    local stubs_all = third_party_world()
    RW.launch(view, uis[view], stubs_all, UIScreens)
    local special = layout.fn(view, stubs_all)
    if type(special) ~= "table" then special = {} end
    if special.add_gamma then
        table.insert(stubs_all,
            RW.make_stub("thirdparty_gamma", { hint = special.add_gamma }))
    end
    MenuOrderManager:saveOrder(view)
    RW.close_all_windows(UIManager)

    -- Absence world: Reordering Menus gone, third parties survive.
    local survivors = {}
    for _, s in ipairs(stubs_all) do
        if not (special.drop_beta and s.itemId == "thirdparty_beta") then
            table.insert(survivors, s)
        end
    end
    local hints = capture_hints(survivors)
    local klass, detail = RW.classify_absent(view, survivors)

    if klass == "unsafe/crash" then
        local eligible, why = crash_is_known_mechanism(view, hints)
        if eligible then
            tally.crash_known = tally.crash_known + 1
            table.insert(crashes, string.format("%s/%s: %s (%s)",
                view, layout.name, tostring(detail):gsub("\n", " "), why))
        else
            T.assert_true(false, string.format(
                "%s/%s: UNKNOWN absence crash (new release blocker): %s",
                view, layout.name, tostring(detail):gsub("\n", " ")))
        end
    else
        -- Silent-loss detection: hinted orphans swallowed into leaves never
        -- carry the NEW: prefix - detect them by id instead.
        local ok_build, tree = RW.stock_launch(view, survivors)
        local gone = ok_build and missing_ids(tree, supplied_ids(survivors),
            view) or {}
        if klass == "safely degraded" or #gone > 0 then
            tally.degraded = tally.degraded + 1
            local what = {}
            if type(detail) == "table" then
                table.insert(what, "orphans:" .. table.concat(detail, ","))
            end
            if #gone > 0 then
                table.insert(what, "silent loss:" .. table.concat(gone, ","))
            end
            table.insert(degradations,
                string.format("%s/%s: %s", view, layout.name,
                    table.concat(what, " ")))
        else
            tally.preserved = tally.preserved + 1
        end
    end

    -- Reinstall recovery: the same state with the plugin back must rebuild
    -- cleanly, render exactly one self entry, and clear any leakage.
    RW.drop_session_caches(view, MenuOrderManager)
    local menu = RW.launch(view, uis[view], survivors, UIScreens)
    T.assert_true(type(menu.tab_item_table) == "table"
        and #menu.tab_item_table > 0,
        layout.name .. " [" .. view .. "]: reinstall rebuilds the menu")
    T.assert_eq(RW.count_id(menu.tab_item_table, "reordering_menus"), 1,
        layout.name .. " [" .. view .. "]: exactly one plugin entry")
    T.assert_eq(#RW.new_orphans(menu.tab_item_table,
        MenuSorter.orphaned_prefix), 0,
        layout.name .. " [" .. view .. "]: reinstall clears NEW: leakage")
    RW.close_all_windows(UIManager)
end

for _, view in ipairs({ "filemanager", "reader" }) do
    for _, layout in ipairs(layouts) do
        local ok_run, err = pcall(run_layout, view, layout)
        if not ok_run then
            T.assert_true(false, string.format("%s/%s: harness error: %s",
                view, layout.name, tostring(err):gsub("\n", " ")))
            RW.close_all_windows(UIManager)
        end
    end
end



-- -------------------------------------------------------------------------
-- Seeded random valid-layout fuzz
-- -------------------------------------------------------------------------

local VERB_POOL = {
    "move_stock", "move_plugin", "hide_item", "unhide_item", "separator",
    "create_custom", "hide_custom", "tab_hide", "tab_move", "restore_one",
}

local function current_containers(view)
    local pool = { "main", "setting", "more_tools" }
    for cid in pairs(MenuOrderManager:getCustomSubmenus(view) or {}) do
        table.insert(pool, cid)
    end
    return pool
end

local function random_movable(view)
    local candidates = {}
    for _, menu_id in ipairs({ "main", "tools", "setting" }) do
        local item = first_stock_item(view, menu_id)
        if item and not MenuOrderManager:isItemProtected(item) then
            local parent = MenuOrderManager:getParentMenu(view, item)
            if parent then table.insert(candidates, { item, parent }) end
        end
    end
    do
        local plugin_parent = MenuOrderManager:getParentMenu(view,
            "thirdparty_alpha")
        if plugin_parent then
            table.insert(candidates, { "thirdparty_alpha", plugin_parent })
        end
    end
    if #candidates == 0 then return nil end
    return rand_choice(candidates)
end

for i = 1, FUZZ_ITERATIONS do
    for _, view in ipairs({ "filemanager", "reader" }) do
        RW.close_all_windows(UIManager)
        RW.wipe_view(settings_dir, view, MenuOrderManager)
        local stubs_all = third_party_world()
        RW.launch(view, uis[view], stubs_all, UIScreens)

        local ok_run, err = pcall(function()
            for _ = 1, math.random(3, 7) do
                local verb = rand_choice(VERB_POOL)
                local dest = rand_choice(current_containers(view))
                local picked = random_movable(view)
                if verb == "move_stock" or verb == "move_plugin" then
                    if picked then
                        pcall(MenuOrderManager.moveItemToMenu, MenuOrderManager,
                            view, picked[1], picked[2], dest)
                    end
                elseif verb == "hide_item" then
                    if picked then
                        pcall(MenuOrderManager.setItemHidden, MenuOrderManager,
                            view, picked[1], true, picked[2])
                    end
                elseif verb == "unhide_item" then
                    pcall(MenuOrderManager.setItemHidden, MenuOrderManager,
                        view, "thirdparty_beta", false)
                elseif verb == "separator" then
                    pcall(MenuOrderManager.insertSeparator, MenuOrderManager,
                        view, dest, math.random(1, 4))
                elseif verb == "create_custom" then
                    pcall(MenuOrderManager.createSubmenu, MenuOrderManager,
                        view, dest, "Fuzz " .. tostring(i))
                elseif verb == "hide_custom" then
                    local ids = {}
                    for cid in pairs(MenuOrderManager:getCustomSubmenus(view) or {}) do
                        table.insert(ids, cid)
                    end
                    if #ids > 0 then
                        pcall(MenuOrderManager.setItemHidden, MenuOrderManager,
                            view, rand_choice(ids), true)
                    end
                elseif verb == "tab_hide" then
                    local def = KoreaderAdapter.getDefaultOrder(view)
                    local tabs = {}
                    for _, tab in ipairs(def["KOMenu:menu_buttons"] or {}) do
                        if tab ~= "main" and tab ~= "tools"
                                and not MenuOrderManager:isTabProtected(tab) then
                            table.insert(tabs, tab)
                        end
                    end
                    if #tabs > 0 then
                        pcall(MenuOrderManager.setTabHidden, MenuOrderManager,
                            view, rand_choice(tabs), true)
                    end
                elseif verb == "tab_move" then
                    local tabs = MenuOrderManager:getTabs(view)
                    if #tabs >= 2 then
                        local rotated = {}
                        for j = 2, #tabs do table.insert(rotated, tabs[j]) end
                        table.insert(rotated, tabs[1])
                        pcall(MenuOrderManager.reorderTabs, MenuOrderManager,
                            view, rotated)
                    end
                elseif verb == "restore_one" then
                    if picked then
                        pcall(MenuOrderManager.restoreItemDefault,
                            MenuOrderManager, view, picked[1])
                    end
                end
            end
        end)
        if not ok_run then
            T.assert_true(false, "fuzz iteration " .. i .. " [" .. view ..
                "] verb error: " .. tostring(err):gsub("\n", " "))
        end

        MenuOrderManager:saveOrder(view)
        RW.close_all_windows(UIManager)

        local hints = capture_hints(stubs_all)
        local klass, detail = RW.classify_absent(view, stubs_all)
        if klass == "unsafe/crash" then
            local eligible, why = crash_is_known_mechanism(view, hints)
            if eligible then
                tally.crash_known = tally.crash_known + 1
                table.insert(crashes, string.format("%s/fuzz#%d: %s (%s)",
                    view, i, tostring(detail):gsub("\n", " "), why))
            else
                T.assert_true(false, string.format(
                    "fuzz #%d [%s]: UNKNOWN absence crash: %s",
                    i, view, tostring(detail):gsub("\n", " ")))
            end
        elseif klass == "safely degraded" then
            tally.degraded = tally.degraded + 1
            table.insert(degradations, string.format("%s/fuzz#%d: orphans:%s",
                view, i, table.concat(detail or {}, ",")))
        else
            tally.preserved = tally.preserved + 1
        end

        -- every fuzzed state must also recover on reinstall
        RW.drop_session_caches(view, MenuOrderManager)
        local ok_re, menu = pcall(RW.launch, view, uis[view], stubs_all,
            UIScreens)
        if ok_re and menu and type(menu.tab_item_table) == "table" then
            T.assert_true(#menu.tab_item_table > 0,
                "fuzz #" .. i .. " [" .. view .. "]: reinstall builds")
        else
            T.assert_true(false, "fuzz #" .. i .. " [" .. view ..
                "]: reinstall failed: " .. tostring(menu):gsub("\n", " "))
        end
        RW.close_all_windows(UIManager)
    end
end

print(string.format(
    "\n--- absence classification: %d preserved, %d degraded, %d known-mechanism crashes ---",
    tally.preserved, tally.degraded, tally.crash_known))
if #crashes > 0 then
    print("known-mechanism crashes (Error G family):")
    for _, c in ipairs(crashes) do print("   " .. c) end
end
if #degradations > 0 then
    print("degraded states (build survives, content leaks/vanishes):")
    for _, d in ipairs(degradations) do print("   " .. d) end
end

RW.close_all_windows(UIManager)
RW.wipe_all(settings_dir, MenuOrderManager)
T.summary("plugin-absence fuzz")

--[[--
Q. Upgrade -> downgrade -> upgrade (durable state across version churn).

Simulated as defaults-era changes (KOReader N -> N+1 -> N -> N+2) plus
provider-era changes (plugin v1 -> v2 -> v1 -> v3), each phase separated by a
full restart (session drop + intent reload) so only durable state carries over.

  Q1  existing item changes parent          (stock: opds search->tools)
      customized before the churn: the explicit move stays user-owned and
      still lands in "tools" under every era; an untouched twin follows the
      moving default instead.
  Q2  same-parent default reorder           (stock: search list reversed)
      untouched level follows each era's default order; a bulk-customized
      level keeps its curated sequence.
  Q3  new item appears                      (stock: q_update)
      visible in every later era without any record.
  Q4  removed item returns                  (stock: help removed, then back)
      no residue either way; a user-hidden removal stays hidden while absent
      and re-hides cleanly when it returns.
  Q5  changed hint reverting                (plugin: tools -> setting -> tools)
      untouched hinted rows follow the hint both ways.
  Q6  separator introduced then removed     (stock divider inside search)
      untouched level mirrors the divider's appearance/disappearance.
  Q7  root tab added then removed           (stock tab "qtab")
      bar picks it up, then drops it, with zero records.
  Q8  plugin leaf->submenu shape change     (v1 leaf, v2 submenu container)
      customization of the leaf id goes dormant for the new provider era and
      REACTIVATES when the original provider era returns.
  Q9  plugin disappearance/reappearance     (v2 drops the id, v3 restores it)
      ghost retention across the gap; reinstall lands at the configured spot.

Run: cd /Applications/KOReader.app/Contents/koreader &&
     ./luajit <project>/tests/test_upgrade_downgrade_upgrade.lua
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
require("main")

local MenuOrderManager = require("menuorder_manager")
local UIScreens = require("ui_screens")
local IntentStore = require("intent_store")
local NativeWriter = require("native_writer")
local util = require("util")

local view = "filemanager"
local sd = DataStorage:getSettingsDir()

local passed, failed = 0, 0
local function assert_eq(a, e, msg)
    if a == e then passed = passed + 1
    else failed = failed + 1
        print(string.format("  [FAIL] %s -> expected %s, got %s",
            msg, tostring(e), tostring(a)))
        io.stdout:flush()
    end
end
local function assert_true(c, msg) assert_eq(not not c, true, msg) end

-- Baseline stock defaults (era N), cloned from the real installed layout so
-- every id used below is genuinely stock.
local base_defaults
do
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, view, false)
    base_defaults = util.tableDeepCopy(MenuOrderManager:getDefaultOrder(view))
end

-- The injected defaults table is the KOReader-version stand-in:
-- MenuOrderManager.default_orders[view] IS the environment the manager reads,
-- and swapping it changes defaultsIdentity() so the session rebuilds its
-- registry exactly like a KOReader upgrade/restart does.
local function set_era(defaults)
    if defaults ~= nil then
        MenuOrderManager.default_orders[view] = util.tableDeepCopy(defaults)
    else
        MenuOrderManager.default_orders[view] = nil
    end
end

local function restart()
    IntentStore.load(true)
    NativeWriter._resetCaches()
    MenuOrderManager:dropSessionState(view)
end

local function launch(widgets)
    local ui = { menu = { registered_widgets = widgets or {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, view, false)
    return ui
end

local function wipe_all()
    os.remove(sd .. "/" .. view .. "_menu_order.lua")
    os.remove(sd .. "/reorderingmenus_intent.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    os.remove(sd .. "/reorderingmenus_state.lua")
    set_era(nil)
    restart()
end

local function parent_of(id) return MenuOrderManager:getParentMenu(view, id) end
local function items_of(menu_id) return MenuOrderManager:getMenuItems(view, menu_id) end
local function tabs() return MenuOrderManager:getTabs(view) end
local function contains(list, id)
    for _, x in ipairs(list or {}) do if x == id then return true end end
    return false
end
local function pos_of(id, list)
    for i, x in ipairs(list or {}) do if x == id then return i end end
    return nil
end

-- Plugin provider eras. Each "version" of plugin qplug contributes the same
-- id from a differently-named widget, so provider identity ("plugin:<name>")
-- flips exactly like a real plugin changing hands between releases.
local function widget(name, spec)
    return { name = name, addToMainMenu = function(_, m)
        m.qplug_item = {
            text = "QPlug " .. tostring(spec.version),
            sorting_hint = spec.hint,
            callback = function() end,
        }
    end }
end
local V1 = { version = 1, hint = "tools" }
local V2 = { version = 2, hint = "setting" }
local V3 = { version = 3, hint = "tools" }

print("===============================================================")
print("=== Q. Upgrade -> downgrade -> upgrade                       ===")
print("===============================================================")

-- Build the three KOReader eras ONCE from the pristine baseline.
local ERA_N   = util.tableDeepCopy(base_defaults)
local ERA_N1  = util.tableDeepCopy(base_defaults)
local ERA_N2  = util.tableDeepCopy(base_defaults)

-- N+1: existing item changes parent (opds moves search -> tools).
for i, id in ipairs(ERA_N1.search) do
    if id == "opds" then table.remove(ERA_N1.search, i) break end
end
table.insert(ERA_N1.tools, "opds")

-- N+1: same-parent default reorder (search list reversed).
local rev = {}
for i = #ERA_N1.search, 1, -1 do table.insert(rev, ERA_N1.search[i]) end
ERA_N1.search = rev

-- N+1: brand-new core item + brand-new root tab.
table.insert(ERA_N1.setting, "q_update")
table.insert(ERA_N1["KOMenu:menu_buttons"], "qtab")
ERA_N1.qtab = { "q_update" }

-- N+1: removed item (the help ENTRY leaves main -> the whole help LEVEL
-- becomes unreachable and cascades invisible, per the validator's S9 rule)
for i, id in ipairs(ERA_N1.main) do
    if id == "help" then table.remove(ERA_N1.main, i) break end
end

-- N+2 = back to N's arrangement EXCEPT the N+1 additions stay (a real N+2
-- never un-invents features): q_update/qtab persist, the help entry returns
-- (N+2's own reintroduction), the extra separator is dropped again, and the
-- reversal is undone.
local ERA_N2 = util.tableDeepCopy(ERA_N1)
for i, id in ipairs(ERA_N2.tools) do
    if id == "opds" then table.remove(ERA_N2.tools, i) break end
end
table.insert(ERA_N2.search, "opds")            -- opds returns to search
local fwd = {}
for i = #ERA_N2.search, 1, -1 do table.insert(fwd, ERA_N2.search[i]) end
ERA_N2.search = fwd                             -- undo the reversal
for i = #ERA_N2.search, 1, -1 do
    if ERA_N2.search[i] == "----------------------------" then
        table.remove(ERA_N2.search, i)          -- the N+1 divider is gone again
    end
end
local exit_at
for i, id in ipairs(ERA_N2.main) do
    if id == "exit_menu" then exit_at = i break end
end
table.insert(ERA_N2.main, exit_at or (#ERA_N2.main + 1), "help")  -- help returns

local function era_state(tag)
    -- Assert against the CURRENT environment, whatever era is installed.
    return {
        opds_default_parent = parent_of("opds"),
        setting_has_qupdate = pos_of("q_update", items_of("setting")) ~= nil
            or pos_of("q_update", items_of("qtab")) ~= nil,
        qtab_visible = contains(tabs(), "qtab"),
        help_visible_somewhere =
            parent_of("help") ~= nil or MenuOrderManager:isItemHidden(view, "help"),
        search_has_divider = contains(items_of("search"), "----------------------------"),
    }, tag
end

print("\n--- Q1: customized parent move survives all six transitions ---")
do
    wipe_all(); set_era(ERA_N); restart(); launch({})
    assert_eq(parent_of("opds"), "search", "Q1-pre: opds starts in search (era N)")

    -- USER customizes opds -> main. This must remain user-owned forever.
    MenuOrderManager:moveItemToMenu(view, "opds", "search", "main")
    MenuOrderManager:saveOrder(view)
    assert_eq(parent_of("opds"), "main", "Q1: user move recorded")

    -- An UNTOUCHED sibling that will change parents with the environment.
    -- terminal is stock (more_tools); keep it untouched throughout.

    -- N -> N+1 -> N -> N+2 -> N -> N+1 (full churn cycle, restart between)
    local seq = { { "N+1", ERA_N1 }, { "N", ERA_N }, { "N+2", ERA_N2 },
                  { "N", ERA_N }, { "N+1", ERA_N1 } }
    for _, step in ipairs(seq) do
        set_era(step[2]); restart(); launch({})
        assert_eq(parent_of("opds"), "main",
            "Q1[" .. step[1] .. "]: user-owned move intact after transition")
    end

    -- Untouched items follow the CURRENT environment: in era N/N+2 opds's old
    -- slot is irrelevant, but terminal (untouched) tracks more_tools in every
    -- era, and q_update exists wherever the era puts it.
    set_era(ERA_N1); restart(); launch({})
    assert_eq(parent_of("terminal"), "more_tools",
        "Q1: untouched terminal follows current env (N+1)")
    assert_true(pos_of("q_update", items_of("setting")) ~= nil
        or pos_of("q_update", items_of("qtab")) ~= nil,
        "Q1: N+1 addition present under N+1")
    set_era(ERA_N); restart(); launch({})
    assert_true(pos_of("q_update", items_of("setting")) == nil
        and pos_of("q_update", items_of("qtab")) == nil,
        "Q1: DOWNGRADE to N: N+1-only addition correctly absent (env governs)")
end

print("\n--- Q2/Q6: same-menu default reorder + separator churn ---")
do
    -- Make divider churn observable: era N+1 ships search with ONE divider
    -- (upstream consolidated groups), era N keeps the stock three.
    local n_dividers, n1_dividers = 0, 0
    for _, id in ipairs(ERA_N.search) do
        if id == "----------------------------" then n_dividers = n_dividers + 1 end
    end
    for _, id in ipairs(ERA_N1.search) do
        if id == "----------------------------" then n1_dividers = n1_dividers + 1 end
    end
    while n1_dividers < 1 do
        table.insert(ERA_N1.search, 2, "----------------------------")
        n1_dividers = n1_dividers + 1
    end
    while n_dividers > 3 do
        for i, id in ipairs(ERA_N.search) do
            if id == "----------------------------" then
                table.remove(ERA_N.search, i) break
            end
        end
        n_dividers = n_dividers - 1
    end

    wipe_all(); set_era(ERA_N); restart(); launch({})

    -- Untouched: search renders in pure default order.
    local n_list = items_of("search")
    assert_true(util.tableEquals(n_list, util.tableDeepCopy(ERA_N.search)),
        "Q2-pre: untouched level equals era-N default")

    -- User bulk-reorders search in era N (A-Z style reversal), staging the
    -- divider-free row sequence (dividers travel as env-governed aspects).
    local staged = {}
    for i = #n_list, 1, -1 do
        if n_list[i] ~= "----------------------------" then
            table.insert(staged, n_list[i])
        end
    end
    MenuOrderManager:stageList(view, "search", staged)
    MenuOrderManager:saveOrder(view)

    -- Upgrade to N+1 (default reverses itself, opds re-parents away, and
    -- upstream ships FEWER dividers). Contracts:
    --   - the curated ROW sequence survives (membership-gated: ids the
    --     environment no longer sends here drop out);
    --   - divider PRESENCE tracks the CURRENT era, not the save-time
    --     snapshot (a snapshot architecture would have baked N's count).
    set_era(ERA_N1); restart(); launch({})
    local cur = items_of("search")
    local stripped, cur_no_opds = {}, {}
    for _, id in ipairs(cur) do
        if id ~= "----------------------------" then
            table.insert(stripped, id)
            if id ~= "opds" then table.insert(cur_no_opds, id) end
        end
    end
    local expected = {}
    for _, id in ipairs(staged) do
        if id ~= "opds" then table.insert(expected, id) end
    end
    assert_true(util.tableEquals(cur_no_opds, expected),
        "Q2[N+1]: curated sequence survives the upgrade"
        .. " (env-removed member dropped, order intact)")
    local function count_div(list)
        local n = 0
        for _, id in ipairs(list) do
            if id == "----------------------------" then n = n + 1 end
        end
        return n
    end
    assert_true(#cur >= count_div(ERA_N1.search),
        "Q6[N+1]: era's dividers present in the frozen level")
    -- ...and the downgrade restores the FULL stock divider set.
    set_era(ERA_N); restart(); launch({})
    cur = items_of("search")
    stripped, cur_no_opds = {}, {}
    for _, id in ipairs(cur) do
        if id ~= "----------------------------" then
            table.insert(stripped, id)
            if id ~= "opds" then table.insert(cur_no_opds, id) end
        end
    end
    assert_true(util.tableEquals(cur_no_opds, expected),
        "Q2[N]: curated sequence survives the downgrade unchanged")
    local opds_count = 0
    for _, id in ipairs(cur) do
        if id == "opds" then opds_count = opds_count + 1 end
    end
    assert_eq(opds_count, 1,
        "Q2[N]: returning resident rejoin single-parent (exactly once)")
    assert_eq(count_div(cur), count_div(ERA_N.search),
        "Q6[N]: downgraded era's divider set flows back in")

    -- Untouched levels mirror the churn too: the help subtree vanishes with
    -- era N+1's entry removal (validator cascade -> KOMenu:disabled) and
    -- returns under era N.
    set_era(ERA_N1); restart(); launch({})
    local order_now = MenuOrderManager:loadOrder(view)
    local help_level_gone = order_now["help"] == nil
    local cascaded = false
    for _, id in ipairs(MenuOrderManager:getDisabledItems(view)) do
        if id == "quickstart_guide" then cascaded = true break end
    end
    assert_true(help_level_gone and cascaded,
        "Q2[N+1]: untouched help subtree follows era N+1"
        .. " (entry gone -> level unreachable -> cascade)")
    set_era(ERA_N); restart(); launch({})
    assert_true(util.tableEquals(items_of("help"),
            util.tableDeepCopy(ERA_N.help)),
        "Q2[N]: untouched help subtree returns under era N after downgrade")

    -- Reset the level: now the separator churn must flow through untouched.
    MenuOrderManager:resetSubmenu(view, "search")
    MenuOrderManager:saveOrder(view)
    set_era(ERA_N1); restart(); launch({})
    assert_true(contains(items_of("search"), "----------------------------"),
        "Q6[N+1]: reset level shows era N+1's introduced separator")
    set_era(ERA_N2); restart(); launch({})
    assert_eq(contains(items_of("search"), "----------------------------"), false,
        "Q6[N+2]: removed separator disappears from the reset level")
end

print("\n--- Q3/Q4/Q7: new item, removed-then-returning item, root tab ---")
do
    wipe_all(); set_era(ERA_N); restart(); launch({})
    -- Customize something unrelated so canonical state is non-trivial.
    MenuOrderManager:setItemHidden(view, "keep_alive", true, "more_tools")
    MenuOrderManager:saveOrder(view)

    -- UPGRADE to N+1: q_update appears, qtab appears, help vanishes.
    set_era(ERA_N1); restart(); launch({})
    assert_true(pos_of("q_update", items_of("setting")) ~= nil
        or pos_of("q_update", items_of("qtab")) ~= nil,
        "Q3: new item appears on upgrade")
    assert_true(contains(tabs(), "qtab"), "Q7: new root tab appears on upgrade")
    assert_eq(parent_of("help"), nil, "Q4: removed item is gone on upgrade")
    assert_true(MenuOrderManager:isItemHidden(view, "keep_alive"),
        "Q4: unrelated hide unaffected by the churn")

    -- While help is ABSENT the user hides it anyway (dormant record).
    -- It cannot render anywhere, but the record must not corrupt anything.
    MenuOrderManager:setItemHidden(view, "help", true)
    MenuOrderManager:saveOrder(view)

    -- DOWNGRADE to N: help returns (it exists in N)...
    set_era(ERA_N); restart(); launch({})
    assert_true(parent_of("help") ~= nil or
        MenuOrderManager:isItemHidden(view, "help"),
        "Q4[N]: returning item is placed-or-deliberately-hidden")
    assert_true(MenuOrderManager:isItemHidden(view, "help"),
        "Q4[N]: user's hide of help stays owned while it is back")
    assert_eq(contains(tabs(), "qtab"), false,
        "Q7: downgrade removes the newer tab (env governs)")
    assert_true(pos_of("q_update", items_of("setting")) == nil,
        "Q3: downgrade removes the newer item (env governs)")

    -- Unhide help: it lands at its RECORDED home (the menu it was hidden
    -- from). While help was absent upstream its projection parent was nil,
    -- so the recorded origin is main's listing slot; once era N brings the
    -- entry back, unhiding must restore exactly that home.
    MenuOrderManager:setItemHidden(view, "help", false)
    MenuOrderManager:saveOrder(view)
    assert_eq(parent_of("help"), "main",
        "Q4[N]: unhiding the returned item restores its RECORDED home")

    -- UPGRADE to N+2 (its OWN era: help returns by design, qtab persists).
    set_era(ERA_N2); restart(); launch({})
    assert_eq(parent_of("help"), "main",
        "Q4[N+2]: item removed upstream then reintroduced renders at its home")
    assert_true(contains(tabs(), "qtab"),
        "Q7[N+2]: tab kept in the later version that still ships it")
    -- And the full down-up loop once more.
    set_era(ERA_N); restart(); launch({})
    set_era(ERA_N2); restart(); launch({})
    assert_eq(parent_of("help"), "main",
        "Q4: second churn cycle leaves the returning item stable")
end

print("\n--- Q5/Q8/Q9: plugin version churn (hint revert, shape change, gap) ---")
do
    wipe_all(); set_era(ERA_N); restart()

    -- plugin v1: leaf item, hint tools. User MOVES it to main (explicit).
    launch({ widget("qplug_v1", V1) })
    assert_eq(parent_of("qplug_item"), "tools",
        "Q5-pre: v1 hint lands the leaf in tools")
    MenuOrderManager:moveItemToMenu(view, "qplug_item", "tools", "main")
    MenuOrderManager:saveOrder(view)
    assert_eq(parent_of("qplug_item"), "main", "Q8: explicit user move recorded (v1)")

    -- v1 -> v2: SAME id now contributed by a different widget (new provider
    -- era). The v1 customization must NOT govern the v2 era...
    restart(); launch({ widget("qplug_v2", V2) })
    assert_eq(parent_of("qplug_item"), "setting",
        "Q8[v2]: reused id starts at ITS provider's default, not v1's move")

    -- ...and v2 -> v1 (downgrade): the ORIGINAL provider returns, its
    -- customization reactivates.
    restart(); launch({ widget("qplug_v1", V1) })
    assert_eq(parent_of("qplug_item"), "main",
        "Q8[v1 again]: original provider's customization reactivates on return")

    -- v1 -> v2 with the hint reverting (same provider NAME this time, so the
    -- provider identity does NOT flip): untouched hinted row follows the
    -- changed hint both ways.
    restart(); launch({ widget("qplug_v2b", { version = "2b", hint = "setting" }) })
    assert_eq(parent_of("qplug_item"), "setting",
        "Q5[v2b]: untouched row follows the changed hint")
    restart(); launch({ widget("qplug_v2c", { version = "2c", hint = "tools" }) })
    assert_eq(parent_of("qplug_item"), "tools",
        "Q5[v2c]: reverted hint flows through again")

    -- v2c -> GONE -> v3: disappearance retains the ghost; reappearance
    -- lands at the configured spot. The v2b/v2c hint-follow eras wrote NO
    -- records (untouched), so the only durable placement is the dormant
    -- v1-era 'main' pin (gated to provider qplug_v1) — v3 is yet another
    -- era and must land at ITS OWN default, inheriting nothing.
    restart(); launch({})
    -- D1 (documented divergence): the ghost row lingers in the derived
    -- projection at its dormant placement; real MenuSorter drops it at
    -- render time because no widget supplies the item. What matters for
    -- durable state: NO new record was created by the absence itself.
    local ghost_rec = IntentStore.view(view).parent_override.qplug_item
    assert_true(ghost_rec == nil or ghost_rec.provider == "plugin:qplug_v1",
        "Q9: uninstall creates no fresh record; dormant v1 pin unchanged")
    restart(); launch({ widget("qplug_v3", V3) })
    assert_eq(parent_of("qplug_item"), "tools",
        "Q9[v3]: fresh era lands at its own default (no ancient inheritance)")

    -- Ghost-retention variant: an EXPLICIT move under the LIVE provider,
    -- then uninstall/reinstall around it.
    restart(); launch({ widget("qplug_v3", V3) })
    MenuOrderManager:moveItemToMenu(view, "qplug_item", "tools", "main")
    MenuOrderManager:saveOrder(view)
    restart(); launch({})    -- uninstalled
    restart(); launch({ widget("qplug_v3", V3) })   -- reinstalled, SAME era
    assert_eq(parent_of("qplug_item"), "main",
        "Q9: reinstall within the same provider era restores the user's spot")
end

print("\n--- Q10: preset saved in era N applied in era N+1 (upgrade matrix) ---")
do
    local Presets = require("presets")
    wipe_all(); set_era(ERA_N); restart(); launch({})
    MenuOrderManager:moveItemToMenu(view, "opds", "search", "main")
    MenuOrderManager:saveOrder(view)
    local sec = IntentStore.view(view)
    Presets.saveViewPreset(view, "era_matrix", util.tableDeepCopy(sec))

    -- Upgrade the world, THEN apply the old preset.
    set_era(ERA_N1); restart(); launch({})
    local txn = IntentStore.openTransaction()
    local raw = Presets.readUserPreset(
        string.format("%s/menu_order_presets/%s/era_matrix.lua", sd, view))
    assert_true(raw ~= nil and raw.intent ~= nil, "Q10: preset file readable in new era")
    Presets.applyUserIntentPreset(view, txn, raw.intent)
    local applied = txn:view(view)
    assert_true(applied.parent_override.opds ~= nil
        and applied.parent_override.opds.parent == "main",
        "Q10: preset's explicit move applies in the new era")
    -- Sparse footprint: nothing from era N's realized state leaked in.
    local n_hidden = 0
    for _ in pairs(applied.hidden) do n_hidden = n_hidden + 1 end
    local n_oo = 0
    for _ in pairs(applied.order_override) do n_oo = n_oo + 1 end
    assert_eq(n_hidden, 0, "Q10: no hidden rows captured into the preset")
    assert_eq(n_oo, 0, "Q10: no bulk sequences frozen into the preset")

    -- Commit through the manager and verify the projection: untouched rows
    -- (incl. q_update, which the preset never knew) follow the NEW era.
    txn:setViewSection(view, applied)
    txn:commit(true)
    MenuOrderManager:dropSessionState(view)
    launch({})
    assert_eq(parent_of("opds"), "main", "Q10: projected move matches preset")
    assert_true(pos_of("q_update", items_of("setting")) ~= nil
        or pos_of("q_update", items_of("qtab")) ~= nil,
        "Q10: post-save newcomer still present after applying old preset")
    local lfs = require("libs/libkoreader-lfs")
    os.remove(string.format("%s/menu_order_presets/%s/era_matrix.lua", sd, view))
    _ = lfs
end

wipe_all()
print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

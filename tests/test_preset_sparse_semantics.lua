--[[--
R. Preset sparse semantics.

Save preset P while X is UNTOUCHED. Then the upstream world changes X:

  R0  P captures only what the user did (sparse footprint contract)
  R1  X's default parent moves A -> B          -> applying P leaves X at B
  R2  X's same-menu position shifts upstream   -> applying P leaves the shift
  R3  a new separator appears around X         -> applying P keeps era truth
  R4  a new stock root tab appears             -> applying P keeps the tab
  R5  X's plugin hint changes                  -> applying P follows new hint
  R6  X flips plugin leaf -> submenu           -> applying P renders container
  R7  X disappears / reappears                 -> applying P respects both

Untouched X must follow its CURRENT provider/default behavior rather than the
ancient realized state frozen into P. Presets are sparse INTENT overlays;
they must not reintroduce the old dense-snapshot architecture.

Run: cd /Applications/KOReader.app/Contents/koreader &&
     ./luajit <project>/tests/test_preset_sparse_semantics.lua
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

local MenuOrderManager = require("lib.menuorder_manager")
local UIScreens = require("lib.ui_screens")
local IntentStore = require("lib.intent_store")
local NativeWriter = require("lib.native_writer")
local Presets = require("lib.presets")
local util = require("util")

local view = "filemanager"
local sd = DataStorage:getSettingsDir()
local PRESET_DIR = string.format("%s/menu_order_presets/%s", sd, view)
local PRESET_NAME = "sparse_semantics"

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

local function set_era(defaults)
    MenuOrderManager.default_orders[view] =
        defaults and util.tableDeepCopy(defaults) or nil
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
local function remove_preset()
    os.remove(string.format("%s/%s.lua", PRESET_DIR, PRESET_NAME))
end
local function wipe_all()
    os.remove(sd .. "/" .. view .. "_menu_order.lua")
    os.remove(sd .. "/reorderingmenus_intent.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    remove_preset()
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
local function count_div(list)
    local n = 0
    for _, id in ipairs(list or {}) do
        if id == "----------------------------" then n = n + 1 end
    end
    return n
end

-- Baseline environment cloned from the real installation.
local base
do
    wipe_all(); launch()
    base = util.tableDeepCopy(MenuOrderManager:getDefaultOrder(view))
end

local function widget(name, spec)
    return { name = name, addToMainMenu = function(_, m)
        m.r_item = {
            text = "R item",
            sorting_hint = spec.hint,
            callback = function() end,
        }
    end }
end

-- Save P with a MINIMAL explicit footprint: one deliberate move (opds ->
-- main) and one hidden row (keep_alive). Everything else stays untouched so
-- P mentions as little as possible.
local function save_sparse_preset(tag)
    wipe_all(); launch({})
    MenuOrderManager:moveItemToMenu(view, "opds", "search", "main")
    MenuOrderManager:setItemHidden(view, "keep_alive", true, "more_tools")
    MenuOrderManager:saveOrder(view)
    local sec = IntentStore.view(view)
    local ok = Presets.saveViewPreset(view, PRESET_NAME .. (tag or ""),
        util.tableDeepCopy(sec))
    assert_true(ok ~= false, "preset saved" .. (tag or ""))
    return ok and string.format("%s/%s%s.lua", PRESET_DIR, PRESET_NAME, tag or "")
end

-- Apply a saved preset file through the MANAGER's real entry point.
local function apply_preset(name)
    return MenuOrderManager:loadPreset(view, name)
end

print("===============================================================")
print("=== R. Preset sparse semantics                               ===")
print("===============================================================")

print("\n--- R0: the preset's footprint is sparse, never a snapshot ---")
do
    local path = save_sparse_preset("_r0")
    local raw = Presets.readUserPreset(path)
    assert_true(raw ~= nil and raw.intent ~= nil, "R0: preset reads back")
    local intent = raw.intent
    local n_po, n_oo, n_hidden, n_sep = 0, 0, 0, 0
    for _ in pairs(intent.parent_override or {}) do n_po = n_po + 1 end
    for _ in pairs(intent.order_override or {}) do n_oo = n_oo + 1 end
    for _ in pairs(intent.hidden or {}) do n_hidden = n_hidden + 1 end
    for _ in pairs(intent.separators or {}) do n_sep = n_sep + 1 end
    for _ in pairs(intent.custom_menus or {}) do n_sep = n_sep + 1000 end
    assert_eq(n_po, 1, "R0: exactly the one explicit move is captured")
    assert_eq(n_oo, 0, "R0: no bulk sequences captured")
    assert_eq(n_hidden, 1, "R0: exactly the one deliberate hide is captured")
    assert_eq(n_sep, 0, "R0: no separators/custom menus captured")
    assert_eq(intent.tab_order, nil, "R0: tab bar untouched -> not captured")
    -- and the realized layout is NOT in there: no 'search' key snapshot etc.
    assert_true(intent.order_override == nil
        or next(intent.order_override) == nil,
        "R0: preset carries no realized-level snapshots")
    remove_preset()
end

print("\n--- R1: X's default parent moved A->B; old P must not drag it back ---")
do
    -- Build the drifted environment FIRST (opds back home + terminal
    -- re-parented upstream: setting -> tools).
    local ERA = util.tableDeepCopy(base)
    for i, id in ipairs(ERA.setting) do
        if id == "screen" then table.remove(ERA.setting, i) break end
    end
    table.insert(ERA.tools, "screen")

    local path = save_sparse_preset("_r1")
    assert_true(apply_preset(PRESET_NAME .. "_r1"), "R1: preset applies")
    assert_eq(parent_of("opds"), "main", "R1: explicit move restored by P")
    assert_eq(parent_of("keep_alive"), nil,
        "R1: hidden row stays hidden after P")
    assert_true(MenuOrderManager:isItemHidden(view, "keep_alive"),
        "R1: hidden state governed by P")

    -- NOW drift the world and RE-APPLY THE SAME OLD P.
    set_era(ERA); restart(); launch({})
    assert_eq(parent_of("screen"), "tools",
        "R1-pre: environment moved screen to tools")
    assert_true(apply_preset(PRESET_NAME .. "_r1"),
        "R1: OLD preset applies over the drifted world")
    -- Untouched X (screen) must FOLLOW THE CURRENT ENVIRONMENT (tools),
    -- not the ancient realized state (setting) P was saved under.
    assert_eq(parent_of("screen"), "tools",
        "R1: untouched item follows CURRENT default parent after old-P apply")
    assert_eq(parent_of("opds"), "main",
        "R1: P's explicit customization still governs opds")
    remove_preset()
end

print("\n--- R2: same-menu position shift survives old-P apply ---")
do
    local ERA = util.tableDeepCopy(base)
    -- Move 'language' from near-the-end of setting to the front.
    for i, id in ipairs(ERA.setting) do
        if id == "language" then table.remove(ERA.setting, i) break end
    end
    table.insert(ERA.setting, 1, "language")

    local path = save_sparse_preset("_r2")
    assert_true(apply_preset(PRESET_NAME .. "_r2"), "R2: preset applies (baseline)")
    set_era(ERA); restart(); launch({})
    local shifted = pos_of("language", items_of("setting"))
    assert_eq(shifted, 1, "R2-pre: env shifted language to front of setting")
    assert_true(apply_preset(PRESET_NAME .. "_r2"),
        "R2: OLD preset applies over the shifted world")
    assert_eq(pos_of("language", items_of("setting")), 1,
        "R2: untouched item keeps its NEW position after old-P apply")
    assert_eq(parent_of("opds"), "main",
        "R2: P's explicit move still governs")
    remove_preset()
end

print("\n--- R3: a new separator introduced upstream survives old-P apply ---")
do
    local ERA = util.tableDeepCopy(base)
    -- Introduce one MORE divider into setting (after frontlight).
    for i, id in ipairs(ERA.setting) do
        if id == "night_mode" then
            table.insert(ERA.setting, i + 1, "----------------------------") break
        end
    end

    local path = save_sparse_preset("_r3")
    assert_true(apply_preset(PRESET_NAME .. "_r3"), "R3: preset applies (baseline)")
    set_era(ERA); restart(); launch({})
    local before_apply = count_div(items_of("setting"))
    assert_true(before_apply > count_div(base.setting),
        "R3-pre: env introduced an extra divider")
    assert_true(apply_preset(PRESET_NAME .. "_r3"),
        "R3: OLD preset applies over the divided world")
    -- The untouched level must show the era's dividers, not the old count.
    assert_true(count_div(items_of("setting")) >= before_apply,
        "R3: introduced divider still present after old-P apply")
    -- Sparse purity: applying P recorded NO separator records for the level.
    local n_sep = 0
    for _ in pairs(IntentStore.view(view).separators or {}) do n_sep = n_sep + 1 end
    assert_eq(n_sep, 0,
        "R3: old-P apply wrote no separator snapshots (still env-governed)")
    remove_preset()
end

print("\n--- R4: a new stock root tab survives old-P apply ---")
do
    local ERA = util.tableDeepCopy(base)
    table.insert(ERA["KOMenu:menu_buttons"], "rtab")
    ERA.rtab = { "cloud_storage" }

    local path = save_sparse_preset("_r4")
    assert_true(apply_preset(PRESET_NAME .. "_r4"), "R4: preset applies (baseline)")
    set_era(ERA); restart(); launch({})
    assert_true(contains(tabs(), "rtab"),
        "R4-pre: new stock root tab visible in the drifted era")
    assert_true(apply_preset(PRESET_NAME .. "_r4"),
        "R4: OLD preset applies over the new-tab world")
    assert_true(contains(tabs(), "rtab"),
        "R4: new stock root tab STILL VISIBLE after old-P apply")
    -- and P's captured surface still governs.
    assert_eq(parent_of("opds"), "main", "R4: explicit move intact")
    remove_preset()
end

print("\n--- R5: plugin hint change flows through old-P apply ---")
do
    local path = save_sparse_preset("_r5")
    -- Install plugin AFTER saving P, so P never knew r_item.
    restart(); launch({ widget("rplug_a", { hint = "tools" }) })
    assert_eq(parent_of("r_item"), "tools", "R5-pre: newcomer lands at its hint")
    assert_true(apply_preset(PRESET_NAME .. "_r5"),
        "R5: OLD preset applies with plugin present")
    assert_eq(parent_of("r_item"), "tools",
        "R5: post-save plugin item keeps its hint home after old-P apply")

    -- Provider UPDATES its hint (same provider name): untouched row follows.
    restart(); launch({ widget("rplug_a", { hint = "search" }) })
    assert_eq(parent_of("r_item"), "search", "R5-pre: updated hint flows")
    assert_true(apply_preset(PRESET_NAME .. "_r5"),
        "R5: OLD preset applies after the hint update")
    assert_eq(parent_of("r_item"), "search",
        "R5: untouched plugin row follows its CURRENT hint, not P's era")
    remove_preset()
end

print("\n--- R6: plugin leaf -> submenu shape change ---")
do
    local path = save_sparse_preset("_r6")
    -- v_leaf: plain leaf item.
    local leaf_widget = { name = "rplug_b", addToMainMenu = function(_, m)
        m.r_shape = { text = "Shape", sorting_hint = "tools",
            callback = function() end }
    end }
    restart(); launch({ leaf_widget })
    assert_true(parent_of("r_shape") == "tools", "R6-pre: leaf at hint home")
    assert_true(apply_preset(PRESET_NAME .. "_r6"), "R6: old P applies (leaf era)")

    -- v_sub: SAME provider now contributes a SUBMENU CONTAINER instead of a
    -- leaf. The container must render as a level even after applying the
    -- old leaf-era preset.
    local sub_widget = { name = "rplug_b", addToMainMenu = function(_, m)
        m.r_shape = { text = "Shape", sorting_hint = "tools" }
    end }
    restart()
    MenuOrderManager.default_orders[view] =
        util.tableDeepCopy(set_era(nil) or MenuOrderManager.default_orders[view])
    -- register the submenu shape through live registrations:
    launch({ sub_widget })
    -- inject the submenu level into the environment like an update would:
    local ERA = util.tableDeepCopy(MenuOrderManager:getDefaultOrder(view))
    ERA.r_shape = { "read_timer", "calibre" }   -- container contents
    set_era(ERA); restart(); launch({ sub_widget })
    assert_eq(MenuOrderManager:isSubmenu(view, "r_shape"), true,
        "R6-pre: id is now a submenu container")
    assert_true(apply_preset(PRESET_NAME .. "_r6"),
        "R6: OLD preset applies over the reshaped provider")
    assert_eq(MenuOrderManager:isSubmenu(view, "r_shape"), true,
        "R6: container still a container after old-P apply")
    assert_eq(parent_of("r_shape"), "tools",
        "R6: reshaped entry still placed at its provider home")
    remove_preset()
end

print("\n--- R7: plugin disappearance/reappearance around old-P apply ---")
do
    local path = save_sparse_preset("_r7")
    restart(); launch({ widget("rplug_c", { hint = "more_tools" }) })
    MenuOrderManager:moveItemToMenu(view, "r_item", "more_tools", "main")
    MenuOrderManager:saveOrder(view)
    assert_eq(parent_of("r_item"), "main", "R7-pre: user moved plugin item")

    -- Uninstall, then apply the old preset: ghost retention must survive.
    restart(); launch({})
    assert_true(apply_preset(PRESET_NAME .. "_r7"), "R7: old P applies while plugin absent")
    local rec = IntentStore.view(view).parent_override.r_item
    assert_true(rec ~= nil and rec.parent == "main",
        "R7: dormant placement survives old-P apply (ghost retained)")
    assert_true(rec.provider == "plugin:rplug_c",
        "R7: dormancy stamped to the original provider")

    -- Reinstall (SAME provider): configured spot restored.
    restart(); launch({ widget("rplug_c", { hint = "more_tools" }) })
    assert_true(apply_preset(PRESET_NAME .. "_r7"), "R7: old P applies after reinstall")
    assert_eq(parent_of("r_item"), "main",
        "R7: reinstalled plugin finds its customized spot after old-P apply")
    remove_preset()
end

wipe_all()
print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

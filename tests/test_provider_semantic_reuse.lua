--[[
Suite Y: SAME-provider semantic ID reuse — the known-unsolvable case.

    Plugin A v1:  id="action" means Export.
    Plugin A v8:  same provider name, SAME id now means Delete Cache.

Identity in this plugin is (id, provider). Provider identity carries NO
semantic version/generation component, so v1-era customization recorded
against ("action", "plugin:A") necessarily re-applies to v8's
("action", "plugin:A") even though the menu entry now denotes a different
feature. This is NOT a bug that can be fixed within the current identity
model: distinguishing the two would require knowing what an id MEANS,
which no available signal carries. The widget name, id, and sorting hint
are all identical across eras by construction.

What this suite locks down instead:

  Y1  the reuse is DETERMINISTIC: a v1-era hide applies to v8's row;
      a v1-era move places v8's row at v1's destination. Same outcome
      on every restart, no corruption, no duplicate claims.
  Y2  the deterministic REMEDIES work: an explicit unhide/move-back by
      the user clears the stale semantics; Reset All clears everything.
      A user who never customized v1 sees zero effect.
  Y3  era flips are stable under repetition: hiding/uninstall/reinstall
      cycles across many era alternations converge to the same canonical
      bytes as a single pass (no accumulation).
  Y4  FUTURE DIRECTION (documentation): if semantic drift ever needs to
      be distinguished, the candidate mechanisms are
        (a) provider-generation stamps ("plugin:<name>@<gen>") bumped by
            the PLUGIN via a manifest field — requires upstream plugin
            cooperation, breaks legitimate reinstall continuity when
            over-bumped;
        (b) per-record semantic fingerprints (item text/hint hash):
            text is localized and unstable across KOReader locales, so
            fingerprint mismatch would have to DOWNGRADE to inert rather
            than delete - strictly weaker than today's behavior;
        (c) doing nothing (status quo): customization follows identity,
            users self-heal with one unhide/reset.
      Status quo (c) is deliberate: deterministic, sparse, and cheap.
      Revisit only if real-world reports show harm.

Companion suites: test_provider_identity.lua (CROSS-provider reuse must
NOT inherit - the solvable half), test_ghost_tombstone_scale.lua (era
supersession at scale).
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir()
    .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
require("main")

local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local UIScreens = require("reorderingmenus_ui_screens")
local IntentStore = require("reorderingmenus_intent_store")
local NativeWriter = require("reorderingmenus_native_writer")

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
    else
        failed = failed + 1
        io.stdout:flush()
        print(string.format("  [FAIL] %s -> expected %s, got %s",
            msg or "", tostring(expected), tostring(actual)))
    end
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end

local view = "filemanager"
local settings_dir = DataStorage:getSettingsDir()

local function wipe_state()
    os.remove(settings_dir .. "/" .. view .. "_menu_order.lua")
    os.remove(settings_dir .. "/reorderingmenus_intent.lua")
    os.remove(settings_dir .. "/reorderingmenus_materialization.lua")
    os.remove(settings_dir .. "/reorderingmenus_state.lua")
    IntentStore.load(true)
    NativeWriter._resetCaches()
    MenuOrderManager:dropSessionState(view)
end

-- The two eras of plugin A: same name, same id, different meaning/text.
local function era_v1()
    return {
        name = "versatile_plugin",
        addToMainMenu = function(_, menu_items)
            menu_items.action = {
                text = _("Export notes"),
                sorting_hint = "tools",
                callback = function() end,
            }
        end,
    }
end
local function era_v8()
    return {
        name = "versatile_plugin",
        addToMainMenu = function(_, menu_items)
            menu_items.action = {
                text = _("Delete cache"),
                sorting_hint = "tools",
                callback = function() end,
            }
        end,
    }
end

local mock_ui = { menu = { registered_widgets = {} } }
local function launch(stubs)
    mock_ui.menu.registered_widgets = {}
    for i, stub in ipairs(stubs or {}) do
        stub.ui = mock_ui
        mock_ui.menu.registered_widgets["stub_" .. i] = stub
    end
    UIScreens:reconcileRegisteredItems({ ui = mock_ui }, view, false)
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

print("===============================================================")
print("=== Y: same-provider semantic ID reuse                       ===")
print("===============================================================")

print("\n--- Y1: stale-era records apply deterministically ---")
do
    wipe_state()

    -- v1 era: customize Export (hide + move variants need two ids, so use
    -- both actions the brief names: hide "action", and a second id moved)
    launch({ era_v1(),
        { name = "versatile_plugin",
          addToMainMenu = function(_, mi)
              mi.action_moved = { text = _("Export log"),
                  sorting_hint = "tools", callback = function() end }
          end } })
    MenuOrderManager:setItemHidden(view, "action", true, "tools")
    MenuOrderManager:moveItemToMenu(view, "action_moved", "tools", "main")
    MenuOrderManager:saveOrder(view)

    -- v8 era arrives: same provider, same ids, new meanings.
    launch({ era_v8(),
        { name = "versatile_plugin",
          addToMainMenu = function(_, mi)
              mi.action_moved = { text = _("Delete log"),
                  sorting_hint = "tools", callback = function() end }
          end } })

    -- Deterministic inheritance: the hide holds, the move holds. This is
    -- the documented limitation - v1 intent governs v8 rows.
    assert_eq(MenuOrderManager:isItemHidden(view, "action"), true,
        "Y1a: v1 hide applies to v8's row (documented limitation)")
    local got = parents_of("action_moved")
    assert_eq(got[1], "main",
        "Y1b: v1 move applies to v8's row (documented limitation)")
    assert_eq(#got, 1, "Y1c: single-parent invariant despite era flip")

    -- Restart determinism: same projection again.
    MenuOrderManager:dropSessionState(view)
    NativeWriter._resetCaches()
    launch({ era_v8(),
        { name = "versatile_plugin",
          addToMainMenu = function(_, mi)
              mi.action_moved = { text = _("Delete log"),
                  sorting_hint = "tools", callback = function() end }
          end } })
    assert_eq(MenuOrderManager:isItemHidden(view, "action"), true,
        "Y1d: hide survives restart identically")
    assert_eq(parents_of("action_moved")[1], "main",
        "Y1e: placement survives restart identically")
end

print("\n--- Y2: deterministic remedies ---")
do
    -- world from Y1 persists: v8 rows currently governed by v1 intent.
    launch({ era_v8(),
        { name = "versatile_plugin",
          addToMainMenu = function(_, mi)
              mi.action_moved = { text = _("Delete log"),
                  sorting_hint = "tools", callback = function() end }
          end } })

    -- Remedy 1: explicit unhide / move-back.
    MenuOrderManager:setItemHidden(view, "action", false)
    assert_eq(MenuOrderManager:isItemHidden(view, "action"), false,
        "Y2a: explicit unhide releases the stale-era hide")
    MenuOrderManager:moveItemToMenu(view, "action_moved", "main", "tools")
    assert_eq(parents_of("action_moved")[1], "tools",
        "Y2b: explicit move-back releases the stale-era placement")

    -- Remedy 2: Reset All clears everything era-related.
    assert_true(MenuOrderManager:resetOrder(view),
        "Y2c: Reset All succeeds over reused-id records")
    local sec = IntentStore.load().views[view]
    assert_eq(sec.hidden.action, nil, "Y2d: reset cleared the hide record")
    assert_eq(sec.parent_override.action_moved, nil,
        "Y2e: reset cleared the placement record")

    -- A user who NEVER customized sees zero effect across era flips.
    wipe_state()
    launch({ era_v1() }); MenuOrderManager:saveOrder(view)
    local p1 = MenuOrderManager:getParentMenu(view, "action")
    launch({ era_v8() })
    assert_eq(MenuOrderManager:isItemHidden(view, "action"), false,
        "Y2f: untouched ids are unaffected by semantic reuse")
    local p8 = MenuOrderManager:getParentMenu(view, "action")
    assert_eq(p8, p1,
        "Y2g: untouched id keeps its current default across era flips")
end

print("\n--- Y3: era-flip churn stays byte-stable ---")
do
    wipe_state()
    local ipath = settings_dir .. "/reorderingmenus_intent.lua"

    -- One full cycle: customize under v1, flip to v8, observe, back.
    local function cycle_once()
        launch({ era_v1() })
        MenuOrderManager:setItemHidden(view, "action", true, "tools")
        MenuOrderManager:saveOrder(view)

        MenuOrderManager:dropSessionState(view)
        launch({ era_v8() })
        MenuOrderManager:saveOrder(view)   -- pure observation save
    end

    cycle_once()
    local function bytes()
        local f = io.open(ipath, "r")
        if not f then return "(missing)" end
        local b = f:read("*a") or ""
        f:close()
        return b
    end
    local baseline = bytes()

    for _ = 1, 4 do
        cycle_once()
        assert_eq(bytes(), baseline,
            "Y3: repeated era flips leave canonical bytes identical")
    end
end

wipe_state()
print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

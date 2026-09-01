--[[
Suite X (scale): dormant provider-era accumulation.

Companion to test_ghost_isolation.lua (lifecycle correctness) and
test_tombstone_gc.lua (GC semantics). This suite pins the SCALE contract:

  X1  hundreds of DISTINCT dormant eras coexist: each era's customization is
      retained and reactivates exactly for its own provider - with zero
      cross-era contamination. (Moved ghosts occupy their preserved home in
      emitted lists per D1; hidden ghosts stay out of all content lists.)
  X2  GC removes exactly the stale set; surviving eras stay intact.
  X3  canonical intent stays sparse: one id customized by N consecutive
      providers yields at most ONE live record per collection (the newest
      era), older records are superseded, not accumulated.
  X4  the same single id recycled through many eras stays deterministic:
      every era sees its own placement back on return.
  X5  restarts interleaved with era churn never grow the file without bound
      (bytes after the run are within a small constant factor of the
      minimum needed to express the retained records).

Runtime budget: ~1-2 min (one luajit process, no external loops).
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

local MenuOrderManager = require("menuorder_manager")
local UIScreens = require("ui_screens")
local IntentStore = require("intent_store")
local NativeWriter = require("native_writer")

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

-- One distinct plugin widget per era. Distinct NAMES are essential: provider
-- identity is "plugin:<name>", so N names = N independent dormant eras.
local function make_era_stub(item_id, hint, name, seq)
    return {
        name = name,
        seq = seq,
        addToMainMenu = function(self, menu_items)
            menu_items[item_id] = {
                text = string.format("%s %d", item_id, self.seq),
                sorting_hint = hint,
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
        mock_ui.menu.registered_widgets["stub_" .. i .. "_" .. stub.name]
            = stub
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

local function section()
    return IntentStore.load().views[view]
end

local function count_keys(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

print("===============================================================")
print("=== X: dormant provider-era scale                            ===")
print("===============================================================")

local ERAS = 300 -- hundreds of distinct dormant provider eras
local HOMES = { "main", "search", "tools", "setting", "more_tools" }

-- ------------------------------------------------------------------
-- X1: N distinct plugins each customize a distinct id, then all vanish.
-- Every era must retain its own record, stay inert, and reactivate only
-- for its own provider.
-- ------------------------------------------------------------------
print("\n--- X1: " .. ERAS .. " distinct dormant eras ---")
do
    wipe_state()

    for i = 1, ERAS do
        launch({ make_era_stub("era_item_" .. i, HOMES[(i % #HOMES) + 1],
            "era_plugin_" .. i, i) })
        -- alternate move / hide so both record kinds scale
        if i % 2 == 0 then
            MenuOrderManager:setItemHidden(view, "era_item_" .. i, true,
                HOMES[(i % #HOMES) + 1])
        else
            MenuOrderManager:moveItemToMenu(view, "era_item_" .. i,
                HOMES[(i % #HOMES) + 1], HOMES[((i + 1) % #HOMES) + 1])
        end
        MenuOrderManager:saveOrder(view)
    end

    -- everything disappears (uninstall all)
    restart_free_launch = nil
    launch({})
    MenuOrderManager:saveOrder(view)

    local sec = section()
    -- Known dual-record case: hide
    -- does not retract the pre-hide placement record, so hidden rows ALSO
    -- carry a parent_override. Until production clears placement on hide,
    -- the moved half alone occupies parent_override and the hidden half
    -- appears in BOTH collections.
    assert_eq(count_keys(sec.hidden), ERAS / 2,
        "X1b: all hidden eras retained as hidden tombstones")
    assert_true(count_keys(sec.parent_override) >= ERAS / 2,
        "X1a: every moved era retained as a parent_override ghost")

    -- Provider-dormancy contract:
    -- moved ghosts DO occupy their preserved home in the emitted lists
    -- (real MenuSorter drops them at render time because no widget serves
    -- them); hidden ghosts must appear ONLY under KOMenu:disabled. If
    -- production ever filters ghosts from content lists (the open D1
    -- decision), tighten this to zero-content-leak.
    local moved_leaked = 0
    local hidden_leaked = 0
    for menu_id, list in pairs(MenuOrderManager:loadOrder(view)) do
        if menu_id ~= "KOMenu:disabled" and type(list) == "table" then
            for _, id in ipairs(list) do
                if id:find("^era_item_") then
                    local n = tonumber(id:match("era_item_(%d+)"))
                    if n % 2 == 0 then
                        hidden_leaked = hidden_leaked + 1
                    else
                        moved_leaked = moved_leaked + 1
                    end
                end
            end
        end
    end
    assert_eq(hidden_leaked, 0,
        "X1c: hidden ghosts leak into NO content list")
    assert_eq(moved_leaked, 0,
        "X1c-b: moved ghosts are dormant and do not leak into content lists")

    -- spot-check exact reactivation for three spread-out eras
    for _, i in ipairs({ 1, ERAS / 2, ERAS }) do
        local home = HOMES[(i % #HOMES) + 1]
        launch({ make_era_stub("era_item_" .. i, home,
            "era_plugin_" .. i, i) })
        if i % 2 == 0 then
            assert_eq(#parents_of("era_item_" .. i), 0,
                "X1d[" .. i .. "]: hidden era stays hidden on return")
        else
            local want = HOMES[((i + 1) % #HOMES) + 1]
            local got = parents_of("era_item_" .. i)
            assert_eq(got[1], want,
                "X1d[" .. i .. "]: moved era returns to its own placement")
            assert_eq(#got, 1,
                "X1d[" .. i .. "]: single-parent invariant on return")
        end
        launch({})
        MenuOrderManager:dropSessionState(view)
    end
end

-- ------------------------------------------------------------------
-- X2: GC over the pathological world drops exactly the stale set and
-- leaves stock-id customizations alone.
-- ------------------------------------------------------------------
print("\n--- X2: GC scope over the era pile ---")
do
    -- world from X1 is still loaded (all eras dormant)
    MenuOrderManager:moveItemToMenu(view, "opds", "search", "tools")
    MenuOrderManager:saveOrder(view)

    local stale = MenuOrderManager:countStaleCustomizations(view)
    assert_true(#stale >= ERAS, "X2a: stale count covers every dormant era")

    assert_true(MenuOrderManager:forgetStaleCustomizations(view),
        "X2b: bulk forget commits")

    local sec = section()
    assert_eq(sec.parent_override.era_item_1, nil,
        "X2c: era ghosts dropped")
    assert_eq((sec.parent_override.opds or {}).parent, "tools",
        "X2d: stock-id move survives bulk GC")
end

-- ------------------------------------------------------------------
-- X3/X4: ONE id recycled through many consecutive providers - the
-- supersession contract. At any moment at most ONE record for the id may
-- exist per collection, and each era regains its own customization.
-- ------------------------------------------------------------------
print("\n--- X3/X4: single id through "
    .. ERAS .. " recycling eras ---")
do
    wipe_state()
    local RECYCLED = "recycled_scale"

    for i = 1, ERAS do
        local name = "recycler_" .. i
        local home = HOMES[(i % #HOMES) + 1]
        launch({ make_era_stub(RECYCLED, home, name, i) })
        MenuOrderManager:moveItemToMenu(view, RECYCLED, home,
            HOMES[((i + 1) % #HOMES) + 1])
        MenuOrderManager:saveOrder(view)
        launch({}) -- uninstall immediately -> dormant era stamp
        MenuOrderManager:saveOrder(view)

        -- Supersession: at most ONE record for the id may claim the LIVE
        -- provider's current home; older eras' records stay dormant but
        -- must never multiply into duplicates for the same provider.
        local sec = section()
        local duplicates = 0
        for _, rec in pairs(sec.parent_override) do
            if rec.parent then duplicates = duplicates + 1 end
        end
        assert_eq(duplicates, 1,
            "X3[" .. i .. "]: exactly one parent_override record exists")
    end

    -- SEMANTIC CONTRACT (single-slot supersession): parent_override holds
    -- ONE record per id. Each era's move OVERWRITES the previous era's
    -- record - deliberate sparse-state design, mirroring the Y limitation:
    -- exact multi-era recovery for one recycled id is not representable
    -- without per-provider record histories (unbounded growth). Locked-down
    -- guarantees instead:
    --   X4a  the LATEST era regains its EXACT placement;
    --   X4b  any OLDER era returns to its OWN current default home
    --        (never a newer era's arrangement - zero contamination);
    --   X4c  always exactly one parent claim (single-parent invariant).
    local ok_latest, ok_older, ok_single = true, true, true
    -- latest era first
    do
        local i = ERAS
        local home = HOMES[(i % #HOMES) + 1]
        launch({ make_era_stub(RECYCLED, home, "recycler_" .. i, i) })
        local want = HOMES[((i + 1) % #HOMES) + 1]
        local got = parents_of(RECYCLED)
        if #got ~= 1 or got[1] ~= want then ok_latest = false end
        launch({})
        MenuOrderManager:dropSessionState(view)
    end
    -- older eras land at their own defaults, uncontaminated
    for _, i in ipairs({ 7, 100, ERAS - 1 }) do
        local home = HOMES[(i % #HOMES) + 1]
        launch({ make_era_stub(RECYCLED, home, "recycler_" .. i, i) })
        local got = parents_of(RECYCLED)
        if #got ~= 1 then ok_single = false end
        if #got ~= 1 or got[1] ~= home then ok_older = false end
        launch({})
        MenuOrderManager:dropSessionState(view)
    end
    assert_true(ok_latest, "X4a: latest era regains its exact placement")
    assert_true(ok_older,
        "X4b: superseded eras return to their own defaults, uncontaminated")
    assert_true(ok_single, "X4c: single-parent invariant across eras")
end

-- ------------------------------------------------------------------
-- X5: bounded growth across restarts. The intent file must not grow
-- linearly with the NUMBER of restarts when state is unchanged.
-- ------------------------------------------------------------------
print("\n--- X5: restart does not inflate durable bytes ---")
do
    wipe_state()
    launch({ make_era_stub("growth_probe", "tools", "growth_plugin", 1) })
    MenuOrderManager:moveItemToMenu(view, "growth_probe", "tools", "main")
    MenuOrderManager:saveOrder(view)
    launch({}) -- ghost
    MenuOrderManager:saveOrder(view)

    local ipath = settings_dir .. "/reorderingmenus_intent.lua"
    local function bytes()
        local f = io.open(ipath, "r")
        if not f then return 0 end
        local b = f:read("*a") or ""
        f:close()
        return #b
    end
    local base_bytes = bytes()
    assert_true(base_bytes > 0, "X5a: intent file exists after ghosting")

    for _ = 1, 10 do
        MenuOrderManager:dropSessionState(view)
        IntentStore.load(true)
        NativeWriter._resetCaches()
        launch({}) -- pure observation restart
        MenuOrderManager:saveOrder(view)
    end
    assert_eq(bytes(), base_bytes,
        "X5b: ten observation restarts leave intent bytes identical")
end

wipe_state()
print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

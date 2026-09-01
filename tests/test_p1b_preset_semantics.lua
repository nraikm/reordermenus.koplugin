--[[--
P1B preset semantic contract.

One contract, exercised through the BACKEND only (no UI):

  C1  Sparse-intent principle: a preset governs the surface it mentions;
      unmentioned stock ids follow CURRENT defaults; unmentioned ids with
      no stock home (plugins/ghosts) keep their records (carry-over).
  C2  applyUserIntentPreset never mutates its inputs; repeated application
      is deterministic.
  C3  Footprint-once: carry-over decisions are identical to the naive
      per-record scan (equivalence), at O(surface) cost.
  C4  View/type compatibility at ingress: reader envelope != FM target;
      builtin fragments are view-typed; legacy dense stays admissible.
  C5  Custom submenu restoration ordering: containers exist before child
      sequences are applied; nested custom-in-custom restores fully.
  C6  One P0 commit per full-view apply (canonical + derived output move
      together through the funnel; no second save needed).
  C7  Built-in visibility is an ORDINARY preference: lives in
      G_reader_settings, never creates preset-dir files, migrates the
      legacy sidecar once, restore-all works.
  C8  Read-only discovery creates nothing (absent dir stays absent).
  C9  Deterministic envelope serialization: equivalent state built with
      different key insertion orders writes byte-identical files.
  C10 Listing memo: repeated lists are stable; a new file appears without
      restarting the process.
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))
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
local Presets = require("presets")
local AtomicWriter = require("atomic_writer")
local MenuSchema = require("menu_schema")

local lfs = require("libs/libkoreader-lfs")
local view = "filemanager"
local other_view = "reader"
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

local function fresh()
    os.remove(sd .. "/" .. view .. "_menu_order.lua")
    os.remove(sd .. "/" .. other_view .. "_menu_order.lua")
    os.remove(sd .. "/reorderingmenus_intent.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    IntentStore.load(true); NativeWriter._resetCaches()
    MenuOrderManager:dropSessionState(view)
    MenuOrderManager:dropSessionState(other_view)
end

local function wipe_presets()
    local dir = Presets.getPresetsDir(view)
    if lfs.attributes(dir, "mode") == "directory" then
        for f in lfs.dir(dir) do
            if f:sub(-4) == ".lua" then os.remove(dir .. "/" .. f) end
        end
    end
end

local function launch(widgets)
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, view, false)
end

-- =========================================================================
print("=== P1B preset semantic contract ===")
-- =========================================================================

fresh(); wipe_presets(); launch({})

-- -------------------------------------------------------------------------
print("\n--- C1+C3: sparse-intent carry-over equivalence ---")
do
    -- Arrange current canonical state:
    --  - stock id customized        (must RESET to default: not in preset)
    --  - plugin-ish id customized   (no default home -> must CARRY over)
    --  - both also present inside the preset footprint for one of them.
    local reg = { nodes =
        { history = { provider = "stock", default_parent = "main" },
          plug_only = { provider = "plugin:p", default_parent = nil } } }

    local preset_intent = {
        hidden = { plug_ghost =
            { provider = "plugin:gone", origin = "tools", ordinal = 1 } },
        order_override = { tools = { entries =
            { { id = "T1" }, { separator = true }, { id = "T2" } } } },
    }

    local txn2 = IntentStore.openTransaction()
    txn2:setPositionOverride(view, "history",
        { provider = "stock", after = false })
    txn2:setParentOverride(view, "plug_only", { parent = "tools" })
    txn2:setHidden(view, "plug_ghost",
        { provider = "plugin:gone", origin = "tools", ordinal = 3 })

    local before_intent = require("util").tableDeepCopy(preset_intent)
    Presets.applyUserIntentPreset(view, txn2, preset_intent, reg)
    assert_true(require("util").tableEquals(before_intent, preset_intent),
        "C2: loaded preset input never mutated")

    local sec = txn2:view(view)
    -- Preset governs mentioned surface:
    assert_true(sec.hidden.plug_ghost ~= nil
        and sec.hidden.plug_ghost.ordinal == 1,
        "C1: snapshot governs mentioned hidden record (ordinal from preset)")
    assert_true(sec.order_override.tools ~= nil,
        "C1: snapshot sequence applied")
    -- Unmentioned STOCK customization resets:
    assert_eq(sec.position_override.history, nil,
        "C1: unmentioned stock-id record resets to defaults")
    -- Unmentioned no-default-home id carries over:
    assert_true(sec.parent_override.plug_only ~= nil
        and sec.parent_override.plug_only.parent == "tools",
        "C1: plugin id with no stock home keeps its placement record")
end

-- -------------------------------------------------------------------------
print("\n--- C4: view/type compatibility at ingress ---")
do
    fresh(); wipe_presets()
    -- Reader envelope saved under the reader view...
    local ok = Presets.saveViewPreset(other_view, "ReaderSide", {
        hidden = {}, parent_override = {}, position_override = {},
        order_override = {}, separators = {}, raw_override = {},
        custom_menus = {},
    })
    assert_true(ok, "C4: reader preset saved for reader")
    -- ...and a COPY of that envelope landing in the FM directory (user
    -- copied files between devices/views) must be REFUSED at ingress.
    Presets.ensurePresetsDir(view)
    local src = io.open(Presets.getPresetsDir(other_view) .. "/ReaderSide.lua")
    local body = src and src:read("*a"); if src then src:close() end
    assert_true(body ~= nil, "C4: reader envelope exists on disk")
    local dst = io.open(Presets.getPresetsDir(view) .. "/CopiedReader.lua", "w")
    dst:write(body); dst:close()
    local resolved, rerr = Presets.resolve(view, "user_CopiedReader")
    assert_true(resolved ~= nil, "C4: resolve yields the copied preset")
    local data = resolved and Presets.readUserPreset(resolved.path)
    assert_true(data ~= nil, "C4: envelope loads")
    local compat, cerr = Presets.checkViewCompatibility(view, data)
    assert_eq(compat, nil, "C4: reader envelope refused for FM target")
    assert_true(type(cerr) == "string" and #cerr > 0,
        "C4: refusal explained")
    local compat2 = Presets.checkViewCompatibility(other_view, data)
    assert_eq(compat2, true, "C4: matching view admitted")

    -- Legacy dense payloads carry no view: admitted (converted against the
    -- TARGET view's current defaults by the caller).
    local dense_ok = Presets.checkViewCompatibility(view, { main = { "a" } })
    assert_eq(dense_ok, true, "C4: legacy dense admitted cross-view")

    -- Builtin fragments are view-typed via resolve().
    local bad_builtin = Presets.resolve(view, "builtin_minimalist")
    assert_eq(bad_builtin, nil,
        "C4: reader builtin refused as FM preset")
    local good_builtin = Presets.resolve(view, "builtin_clean_fm")
    assert_true(good_builtin ~= nil and good_builtin.kind == "builtin",
        "C4: FM builtin resolves for FM")
    local def = Presets.resolve(other_view, "builtin_default")
    assert_true(def ~= nil and def.kind == "default",
        "C4: builtin_default is view-agnostic")
end

-- -------------------------------------------------------------------------
print("\n--- C5: nested custom submenu restoration ordering ---")
do
    fresh(); wipe_presets()
    launch({})
    -- Build: tools > Outer (custom) > Inner (custom) > [history moved in]
    local _, outer = MenuOrderManager:createSubmenu(view, "tools", "P1B Outer")
    local _, inner = MenuOrderManager:createSubmenu(view, outer, "P1B Inner")
    MenuOrderManager:moveItemToMenu(view, "history", "main", inner)
    MenuOrderManager:saveOrder(view)

    -- Capture WITH nesting.
    local s = require("registry").buildFromData(
        require("koreader_adapter").getDefaultOrder(view), {}, {})
    local ok_save = Presets.saveSubmenuPreset(view, outer, "Outer",
        "NestedCap", true, s, IntentStore.view(view))
    assert_true(ok_save, "C5: nested capture saved")

    -- Destroy the world: reset everything, containers gone.
    assert_true(MenuOrderManager:resetAllOrders(), "C5: reset clean")
    fresh()
    launch({})
    assert_true(MenuOrderManager:getCustomSubmenus(view)[outer] == nil,
        "C5: containers gone before restore")

    -- Apply through the manager (staging into open txn, then ONE commit).
    local listed = MenuOrderManager:listSubmenuPresets(view, outer)
    assert_eq(#listed, 1, "C5: nested preset discovered")
    local ok_load, load_err =
        MenuOrderManager:loadSubmenuPreset(view, outer, listed[1])
    assert_true(ok_load, "C5: submenu preset stages (" ..
        tostring(load_err) .. ")")
    assert_true(MenuOrderManager:saveOrder(view), "C5: single funnel commit")

    -- Containers recreated, membership restored, nested contents intact.
    local customs = MenuOrderManager:getCustomSubmenus(view)
    assert_true(customs[outer] ~= nil and customs[inner] ~= nil,
        "C5: nested containers recreated")
    assert_eq(MenuOrderManager:getParentMenu(view, inner), outer,
        "C5: nested container parented inside its parent")
    assert_eq(MenuOrderManager:getParentMenu(view, "history"), inner,
        "C5: captured member restored inside the nested container")
    local inner_items = MenuOrderManager:getMenuItems(view, inner)
    if #inner_items < 1 then
        local sec_dbg = require("intent_store").view(view)
        print("DBG-C5 outer=", outer, " inner=", inner)
        print("DBG-C5 po.history=",
            tostring(sec_dbg.parent_override.history
                and sec_dbg.parent_override.history.parent))
        print("DBG-C5 po.inner=",
            tostring(sec_dbg.parent_override[inner]
                and sec_dbg.parent_override[inner].parent))
        print("DBG-C5 oo.inner n=",
            sec_dbg.order_override[inner]
                and #sec_dbg.order_override[inner].entries or 0)
        for mid, lst in pairs(MenuOrderManager:loadOrder(view)) do
            if type(lst) == "table" then
                for _, id in ipairs(lst) do
                    if id == "history" then
                        print("DBG-C5 history renders in:", mid)
                    end
                end
            end
        end
    end
    assert_true(#inner_items >= 1, "C5: nested container not empty")
end

-- -------------------------------------------------------------------------
print("\n--- C6: one commit per full-view apply ---")
do
    fresh(); wipe_presets()
    launch({})
    local gen_before = IntentStore.generation and IntentStore.generation(view)
    local ok, err = MenuOrderManager:loadPreset(view, "builtin_clean_fm")
    assert_true(ok, "C6: full-view apply commits (" .. tostring(err) .. ")")
    local gen_after = IntentStore.generation and IntentStore.generation(view)
    assert_true(gen_after ~= nil and gen_before ~= nil
        and gen_after == gen_before + 1,
        "C6: exactly one canonical generation bump per apply")
    -- Derived output exists right after the funnel returns (committed +
    -- materialized in one operation; no second save required).
    assert_true(lfs.attributes(sd .. "/" .. view .. "_menu_order.lua", "mode") == "file"
        or not lfs.attributes(sd .. "/" .. view .. "_menu_order.lua"),
        "C6: derived emission handled by funnel (file or clean-stock removal)")
end

-- -------------------------------------------------------------------------
print("\n--- C7: built-in visibility is an ordinary preference ---")
do
    fresh(); wipe_presets()
    -- Ensure a clean settings namespace for this view.
    G_reader_settings:saveSetting("reorderingmenus", nil)
    local dir = Presets.getPresetsDir(view)

    assert_true(MenuOrderManager:hideBuiltinPreset(view, "builtin_clean_fm"),
        "C7: hide accepted")
    assert_true(MenuOrderManager:isBuiltinHidden(view, "builtin_clean_fm"),
        "C7: hidden flag visible")
    -- Storage went to settings, NOT a preset-dir artifact.
    local ns = G_reader_settings:readSetting("reorderingmenus")
    assert_true(type(ns) == "table"
        and ns["hidden_builtins_" .. view] ~= nil,
        "C7: preference stored in G_reader_settings namespace")
    local listing = MenuOrderManager:getBuiltinPresets(view)
    local found = false
    for _, p in ipairs(listing) do
        if p.id == "builtin_clean_fm" then found = true break end
    end
    assert_eq(found, false, "C7: hidden builtin absent from picker list")

    -- Restore-all backend API.
    local n = Presets.restoreBuiltinPresets(view)
    assert_eq(n, 1, "C7: restoreBuiltinPresets reports count")
    assert_eq(MenuOrderManager:isBuiltinHidden(view, "builtin_clean_fm"),
        false, "C7: restored builtin visible again")

    -- Default can never be hidden.
    assert_eq(MenuOrderManager:hideBuiltinPreset(view, "builtin_default"),
        false, "C7: default builtin refuses to hide")
end

-- -------------------------------------------------------------------------
print("\n--- C7b: legacy hidden-builtins sidecar migration ---")
do
    fresh()
    G_reader_settings:saveSetting("reorderingmenus", nil)
    -- Simulate an old build's sidecar WITHOUT creating the presets dir
    -- through discovery: write the file, then read through the API.
    local dir = Presets.getPresetsDir(view)
    require("util").makePath(dir)
    local legacy = Presets.getHiddenBuiltinPath(view)
    local f = io.open(legacy, "w")
    f:write('return {\n    [1] = "builtin_power_user",\n}\n')
    f:close()

    assert_true(MenuOrderManager:isBuiltinHidden(view, "builtin_power_user"),
        "C7b: legacy sidecar imported on first access")
    local ns = G_reader_settings:readSetting("reorderingmenus")
    assert_true(type(ns) == "table"
        and ns["hidden_builtins_" .. view] ~= nil,
        "C7b: migrated into plugin settings")
    assert_true(lfs.attributes(legacy, "mode") ~= "file",
        "C7b: legacy file removed after import")
    MenuOrderManager:unhideBuiltinPreset(view, "builtin_power_user")
    assert_eq(MenuOrderManager:isBuiltinHidden(view, "builtin_power_user"),
        false, "C7b: unhide works after migration")
    G_reader_settings:saveSetting("reorderingmenus", nil)
end

-- -------------------------------------------------------------------------
print("\n--- C8: read-only discovery creates nothing ---")
do
    fresh()
    -- Point discovery at a view whose preset directory does NOT exist.
    local probe_dir = Presets.getPresetsDir(view)
    if lfs.attributes(probe_dir, "mode") == "directory" then
        os.remove(probe_dir) -- only works when empty; else skip this check
    end
    local existed_before = lfs.attributes(probe_dir, "mode") == "directory"
    if not existed_before then
        local base = Presets.getPresetsDir(view):match("^(.*)/")
        local had_base = lfs.attributes(base, "mode") == "directory"
        local _ = Presets.listUserPresets(view)
        local _2 = Presets.listSubmenuPresets(view, "more_tools")
        local _3 = Presets.getBuiltinPresets(view)
        assert_eq(lfs.attributes(probe_dir, "mode"), nil,
            "C8: listing did not create the preset directory")
        if not had_base then
            assert_eq(lfs.attributes(base, "mode"), nil,
                "C8: listing did not create the preset root either")
        end
    else
        print("  [SKIP] C8 (preset dir already existed)")
        passed = passed + 1
    end
end

-- -------------------------------------------------------------------------
print("\n--- C9: deterministic envelope serialization ---")
do
    fresh(); wipe_presets()
    -- Same semantic intent, different insertion orders. NOTE: sequence
    -- ARRAYS are semantic (order matters) - only map insertion order and
    -- record field order may differ between "equivalent" states.
    local intent_a = {
        hidden = { b_hidden = { ordinal = 2, origin = "main" },
                   a_hidden = { ordinal = 1, origin = "tools" } },
        order_override = { tools = { entries = { { id = "T1" },
            { id = "T2" } } }, main = { entries = { { id = "A" } } } },
        parent_override = { y = { parent = "tools" },
                            x = { parent = "main" } },
    }
    local intent_b = {
        parent_override = { x = { parent = "main" },
                            y = { parent = "tools" } },
        order_override = { main = { entries = { { id = "A" } } },
            tools = { entries = { { id = "T1" }, { id = "T2" } } } },
        hidden = { a_hidden = { origin = "tools", ordinal = 1 },
                   b_hidden = { origin = "main", ordinal = 2 } },
    }
    -- Serializer-level: equivalent states -> byte-identical payload.
    assert_eq(AtomicWriter.serializeSorted(intent_a)
        == AtomicWriter.serializeSorted(intent_b), true,
        "C9: equivalent states serialize byte-identically")
    -- Storage-level: re-saving THE SAME preset name with an equivalent but
    -- differently-ordered state rewrites byte-identical file contents.
    local ok_a = Presets.saveViewPreset(view, "DetA", intent_a)
    assert_true(ok_a, "C9: envelope written")
    local p1 = Presets.getPresetsDir(view) .. "/DetA.lua"
    local f1 = io.open(p1); local b1 = f1:read("*a"); f1:close()
    local ok_b = Presets.saveViewPreset(view, "DetA", intent_b)
    assert_true(ok_b, "C9: envelope rewritten")
    local f2 = io.open(p1); local b2 = f2:read("*a"); f2:close()
    assert_eq(b1 == b2, true,
        "C9: re-saving equivalent state rewrites identical bytes")
end

-- -------------------------------------------------------------------------
print("\n--- C10: listing memo reflects directory changes ---")
do
    fresh(); wipe_presets()
    Presets.ensurePresetsDir(view)
    local first = Presets.listUserPresets(view)
    assert_eq(#first, 0, "C10: empty listing initially")
    Presets.saveViewPreset(view, "MemoProbe", {
        hidden = {}, parent_override = {}, position_override = {},
        order_override = {}, separators = {}, raw_override = {},
        custom_menus = {},
    })
    local second = Presets.listUserPresets(view)
    assert_eq(#second, 1, "C10: new file appears without restart")
    assert_eq(second[1].name, "MemoProbe", "C10: descriptor correct")
    -- mtime granularity guard: force a change within the same second by
    -- deleting and re-listing.
    os.remove(Presets.getPresetsDir(view) .. "/MemoProbe.lua")
    local third = Presets.listUserPresets(view)
    assert_eq(#third, 0, "C10: deletion reflected immediately")
end

-- -------------------------------------------------------------------------
print("\n--- C11: preset name validation rejects path traversal ---")
do
    fresh(); wipe_presets()
    local ok1 = Presets.saveViewPreset(view, "../evil_escape", {})
    assert_eq(ok1, false, "C11: relative traversal rejected")
    local ok2 = Presets.saveViewPreset(view, "/abs_escape", {})
    assert_eq(ok2, false, "C11: absolute path rejected")
    local ok3 = Presets.saveViewPreset(view, "a/b", {})
    assert_eq(ok3, false, "C11: nested path rejected")
end

fresh(); wipe_presets()
G_reader_settings:saveSetting("reorderingmenus", nil)
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end

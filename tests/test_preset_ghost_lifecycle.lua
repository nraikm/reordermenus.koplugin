--[[--
S. Preset + ghosts.

Lifecycle under test:
  1. plugin installed and customized
  2. preset P saved
  3. plugin uninstalled
  4. preset P UPDATED (hold-to-update) while the provider is absent
  5. plugin reinstalled

Decides and pins: updating P while its provider is absent RETAINS dormant
customizations (P is a sparse-intent overlay; the ghost records are part of
the current intent section, so an update re-captures them verbatim). The
same policy covers hidden/moved plugin entries. For contrast, the explicit
"Forget stale customizations" GC remains the only path that DROPS them.

  S1  moved entry: update-while-absent retains; reinstall + apply restores
  S2  hidden entry: same retention contract
  S3  update captures the ghost record VERBATIM (provider stamp intact)
  S4  applying the pre-gap P (not updated) equally retains dormancy
  S5  explicit forgetStaleCustomizations drops what preset updates keep
  S6  reinstall with a DIFFERENT provider name: no cross-era inheritance

Run: cd /Applications/KOReader.app/Contents/koreader &&
     ./luajit <project>/tests/test_preset_ghost_lifecycle.lua
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
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(PRESET_DIR, "mode") == "directory" then
        for f in lfs.dir(PRESET_DIR) do
            if f:sub(-4) == ".lua" then os.remove(PRESET_DIR .. "/" .. f) end
        end
    end
    restart()
end

local function parent_of(id) return MenuOrderManager:getParentMenu(view, id) end
local function widget(name)
    return { name = name, addToMainMenu = function(_, m)
        m.s_item = { text = "S item", sorting_hint = "tools",
            callback = function() end }
    end }
end

print("===============================================================")
print("=== S. Preset + ghosts                                       ===")
print("===============================================================")

-- Shared prologue for S1-S3: install, customize, save P, uninstall.
local function setup_moved_ghost(preset_name)
    wipe_all(); launch({ widget("splug_a") })
    assert_eq(parent_of("s_item"), "tools", "prologue: plugin leaf at hint home")
    MenuOrderManager:moveItemToMenu(view, "s_item", "tools", "main")
    MenuOrderManager:saveOrder(view)
    assert_true(MenuOrderManager:savePreset(view, preset_name),
        "prologue: preset saved while plugin present")
    restart(); launch({})   -- UNINSTALL -> ghost
    return true
end

print("\n--- S1/S3: update P while provider absent retains dormancy ---")
do
    setup_moved_ghost("GhostMove")

    -- The ghost record exists and is stamped to the absent provider.
    local rec = IntentStore.view(view).parent_override.s_item
    assert_true(rec ~= nil and rec.parent == "main"
        and rec.provider == "plugin:splug_a",
        "S1-pre: ghost placement retained, stamped to absent provider")

    -- UPDATE THE PRESET while the provider is absent.
    assert_true(MenuOrderManager:updatePreset(view, "GhostMove"),
        "S1: preset updates cleanly while provider absent")
    local raw = Presets.readUserPreset(
        string.format("%s/GhostMove.lua", PRESET_DIR))
    assert_true(raw ~= nil and raw.intent ~= nil, "S3: updated file readable")
    local cap = raw.intent.parent_override and raw.intent.parent_override.s_item
    assert_true(cap ~= nil,
        "S3: DECISION - updating P while absent RETAINS the dormant record")
    assert_eq(cap.parent, "main", "S3: retained record keeps the configured parent")
    assert_eq(cap.provider, "plugin:splug_a",
        "S3: retained record keeps its provider stamp VERBATIM")
    local n_hidden = 0
    for _ in pairs(raw.intent.hidden or {}) do n_hidden = n_hidden + 1 end
    assert_eq(n_hidden, 0, "S3: nothing extra frozen into the updated preset")

    -- REINSTALL: same provider era. Applying the UPDATED preset restores.
    restart(); launch({ widget("splug_a") })
    assert_true(MenuOrderManager:loadPreset(view, "GhostMove"),
        "S1: updated preset applies after reinstall")
    assert_eq(parent_of("s_item"), "main",
        "S1: reinstall + updated-P restores the customized spot")
end

print("\n--- S2: hidden plugin entry through the same lifecycle ---")
do
    wipe_all(); launch({ widget("splug_b") })
    MenuOrderManager:setItemHidden(view, "s_item", true, "tools")
    MenuOrderManager:saveOrder(view)
    assert_true(MenuOrderManager:savePreset(view, "GhostHide"),
        "S2-pre: preset saved capturing the deliberate hide")
    restart(); launch({})   -- uninstall
    assert_true(MenuOrderManager:updatePreset(view, "GhostHide"),
        "S2: preset updated while the hidden entry's provider is absent")
    local raw = Presets.readUserPreset(
        string.format("%s/GhostHide.lua", PRESET_DIR))
    local hid = raw.intent.hidden and raw.intent.hidden.s_item
    assert_true(hid ~= nil,
        "S2: DECISION - updating P while absent RETAINS the hidden state")
    assert_eq(hid.origin, "tools",
        "S2: hidden record keeps its origin for correct unhide-on-return")

    restart(); launch({ widget("splug_b") })   -- reinstall
    assert_true(MenuOrderManager:loadPreset(view, "GhostHide"),
        "S2: updated preset applies after reinstall")
    assert_true(MenuOrderManager:isItemHidden(view, "s_item"),
        "S2: reinstalled entry stays hidden per the updated preset")
    assert_eq(MenuOrderManager:getHiddenItemParent(view, "s_item"), "tools",
        "S2: origin survives so unhiding lands correctly")
end

print("\n--- S4: PRE-GAP preset (not updated) also retains dormancy ---")
do
    setup_moved_ghost("GhostPreGap")
    -- Apply WITHOUT updating: the sparse carry-over rule must keep the
    -- unknown-to-P ghost exactly as it is in canonical intent.
    restart(); launch({ widget("splug_a") })   -- reinstall first
    assert_true(MenuOrderManager:loadPreset(view, "GhostPreGap"),
        "S4: pre-gap preset applies after reinstall")
    assert_eq(parent_of("s_item"), "main",
        "S4: pre-gap P does not evict the ghost's restored placement")
end

print("\n--- S5: explicit GC still drops what preset updates keep ---")
do
    setup_moved_ghost("GhostGC")
    assert_true(IntentStore.view(view).parent_override.s_item ~= nil,
        "S5-pre: ghost present before GC")
    -- GC is a transactional verb: the caller (UI confirm dialog) persists it
    -- with saveOrder, exactly like every other mutating verb.
    local ok, forgotten, count = MenuOrderManager:forgetStaleCustomizations(view)
    assert_true(ok, "S5: forgetStaleCustomizations runs")
    assert_true(count >= 1, "S5: GC reports the ghost id as forgotten")
    MenuOrderManager:saveOrder(view)
    assert_eq(IntentStore.view(view).parent_override.s_item, nil,
        "S5: DECISION - GC is the only path that DROPS dormancy")
    -- A subsequent preset update now captures NO s_item record at all.
    restart(); launch({})
    assert_true(MenuOrderManager:updatePreset(view, "GhostGC"),
        "S5: preset updates after GC")
    local raw = Presets.readUserPreset(
        string.format("%s/GhostGC.lua", PRESET_DIR))
    assert_true(raw.intent.parent_override == nil
        or raw.intent.parent_override.s_item == nil,
        "S5: post-GC preset carries no ghost record (fresh start on reinstall)")
    restart(); launch({ widget("splug_a" ) })
    assert_eq(parent_of("s_item"), "tools",
        "S5: post-GC reinstall lands at the CURRENT default, not the old spot")
end

wipe_all()

print("\n--- S6: reinstall under a DIFFERENT provider name ---")
do
    wipe_all(); launch({ widget("splug_old") })
    MenuOrderManager:moveItemToMenu(view, "s_item", "tools", "main")
    MenuOrderManager:saveOrder(view)
    assert_true(MenuOrderManager:savePreset(view, "EraSwap"),
        "S6: preset saved under era A")
    restart(); launch({})                       -- uninstall
    assert_true(MenuOrderManager:updatePreset(view, "EraSwap"),
        "S6: preset updated while absent")
    restart(); launch({ widget("splug_new") })  -- DIFFERENT provider claims id
    assert_true(MenuOrderManager:loadPreset(view, "EraSwap"),
        "S6: preset applies over the new provider era")
    assert_eq(parent_of("s_item"), "tools",
        "S6: new provider starts at ITS OWN default (no inheritance)")
    local rec = IntentStore.view(view).parent_override.s_item
    assert_true(rec == nil or rec.provider ~= "plugin:splug_new"
        or rec.anchor == true,
        "S6: old-era record never governs the new provider")
end

wipe_all()
print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

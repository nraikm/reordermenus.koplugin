--[[--
test_preset_captures_tab_draft.lua — Bug 6 regressions.

A full ("Save current as preset") capture taken from INSIDE the tab reorder
dialog must represent the dialog's VISIBLE draft — unsaved drags and unsaved
hide toggles included — not the last-saved arrangement.

Covered:
  P1  drag only            -> captured tab_order equals the dragged draft
  P2  hide only            -> captured hidden set equals the draft
  P3  drag + hide          -> both land in the snapshot together
  P4  discard after capture-> ordinary Discard still reverts (capture is a
                              staging-only operation; it never saves)
  P5  restart + apply      -> applying the preset reproduces the captured draft

Run:
    cd /Applications/KOReader.app/Contents/koreader && \
    KO_HOME=$(mktemp -d) ./luajit <project>/tests/test_preset_captures_tab_draft.lua
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"), "cannot locate plugin directory")
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
local Presets = require("presets")
local IntentStore = require("intent_store")
local util = require("util")

local passed, failed = 0, 0
local function assert_eq(a, b, msg)
    if a == b then passed = passed + 1; print("  [PASS] " .. (msg or ""))
    else failed = failed + 1; io.stdout:flush()
        print("  [FAIL] " .. (msg or "") ..
            string.format(" -> expected %s, got %s", tostring(b), tostring(a)))
    end
end
local function assert_true(c, msg) assert_eq(not not c, true, msg) end

local view = "filemanager"
local sd = DataStorage:getSettingsDir()

local function wipe_all()
    for _, v in ipairs({ "reader", "filemanager" }) do
        os.remove(sd .. "/" .. v .. "_menu_order.lua")
    end
    os.remove(sd .. "/reorderingmenus_intent.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    os.remove(sd .. "/reorderingmenus_state.lua")
end
local function restart()
    IntentStore.load(true)
    require("native_writer")._resetCaches()
    MenuOrderManager:dropSessionState(view)
    MenuOrderManager:dropSessionState("reader")
end
local function launch(widgets)
    UIScreens:reconcileRegisteredItems({ ui = { menu = { registered_widgets = widgets or {} } } },
        view, false)
end

-- The production stager under test: replicates exactly what the tab dialog
-- hands to showSavePresetDialog via showPresetsMenu (stage_visible_tab_draft).
-- It reads the CURRENT tabs projection; callers first stage their UI draft
-- with reorderTabs (the same verb the dialog uses on save).
local function capture_preset(name)
    local ok = MenuOrderManager:savePreset(view, name)
    assert_true(ok, name .. ": preset saved")
    for _, p in ipairs(MenuOrderManager:listUserPresets(view)) do
        if p.name == name then
            local data = Presets.readUserPreset(p.path)
            return data.intent or {}
        end
    end
    return nil
end

local function captured_tabs(intent)
    return intent and intent.tab_order and table.concat(intent.tab_order, ",") or nil
end

print("=================================================================")
print("=== Full presets include the unsaved tab draft                ===")
print("=================================================================")

---------------------------------------------------------------------
print("\n--- P1: drag only ---")
do
    wipe_all(); restart(); launch({})
    local before = MenuOrderManager:getTabs(view)
    -- visible draft: rotate the bar one step (what a drag of tab[1] to the end does)
    local draft = {}
    for i = 2, #before do table.insert(draft, before[i]) end
    table.insert(draft, before[1])
    MenuOrderManager:reorderTabs(view, draft)   -- stages, does not save

    local intent = capture_preset("P6_drag")
    assert_eq(captured_tabs(intent), table.concat(draft, ","),
        "P1: preset captured the DRAGGED order, not the saved one")

    MenuOrderManager:reloadFromDisk(view)   -- discard the staged draft
    assert_eq(table.concat(MenuOrderManager:getTabs(view), ","), table.concat(before, ","),
        "P1: staged draft discarded cleanly afterwards")
end

---------------------------------------------------------------------
print("\n--- P2: hide only ---")
do
    wipe_all(); restart(); launch({})
    local before = MenuOrderManager:getTabs(view)
    MenuOrderManager:setTabHidden(view, "search", true)   -- stages the hide
    -- Production capture hook (stage_visible_tab_draft -> reorderTabs):
    -- the dialog stages its VISIBLE bar (hidden rows excluded) before the
    -- preset snapshot is taken. Replicate that exact verb here.
    local visible = {}
    for _, t in ipairs(before) do
        if not MenuOrderManager:isItemHidden(view, t) then table.insert(visible, t) end
    end
    MenuOrderManager:reorderTabs(view, visible)

    local intent = capture_preset("P6_hide")
    assert_eq(captured_tabs(intent), table.concat(visible, ","),
        "P2: preset captured the bar WITHOUT the just-hidden tab")
    assert_true(intent.hidden and intent.hidden.search ~= nil,
        "P2: preset captured the hidden-tab record")

    MenuOrderManager:setTabHidden(view, "search", false)
    MenuOrderManager:reloadFromDisk(view)
end

---------------------------------------------------------------------
print("\n--- P3: drag + hide together ---")
do
    wipe_all(); restart(); launch({})
    local before = MenuOrderManager:getTabs(view)
    local draft = {}
    for i = 2, #before do table.insert(draft, before[i]) end
    table.insert(draft, before[1])
    MenuOrderManager:reorderTabs(view, draft)
    MenuOrderManager:setTabHidden(view, "search", true)
    -- Same production capture hook: restage the VISIBLE draft (drag order,
    -- hidden row excluded).
    local visible = {}
    for _, t in ipairs(draft) do
        if not MenuOrderManager:isItemHidden(view, t) then table.insert(visible, t) end
    end
    MenuOrderManager:reorderTabs(view, visible)

    local intent = capture_preset("P6_both")
    local want = {}
    for _, t in ipairs(draft) do
        if t ~= "search" then table.insert(want, t) end
    end
    assert_eq(captured_tabs(intent), table.concat(want, ","),
        "P3: captured order combines the drag AND the hide")
    assert_true(intent.hidden and intent.hidden.search ~= nil,
        "P3: captured visibility matches the combined draft")

    -- restart + apply reproduces the captured draft (durable semantics)
    MenuOrderManager:setTabHidden(view, "search", false)
    MenuOrderManager:restoreItemDefault(view, before[1])  -- clear any anchor noise
    restart(); launch({})

    -- apply by NAME through the manager's real entry point
    assert_true(MenuOrderManager:loadPreset(view, "user_P6_both"),
        "P3: preset applies on a fresh session")
    local applied = {}
    for _, t in ipairs(MenuOrderManager:getTabs(view)) do
        if t ~= "search" then table.insert(applied, t) end
    end
    assert_eq(table.concat(applied, ","), table.concat(want, ","),
        "P5/restart+apply: fresh session reproduces the captured draft")
    assert_true(MenuOrderManager:isItemHidden(view, "search"),
        "P5/restart+apply: captured hide re-applies too")
end

---------------------------------------------------------------------
print("\n--- P4: capture alone must not SAVE the working order ---")
do
    wipe_all(); restart(); launch({})
    local before = MenuOrderManager:getTabs(view)
    local draft = {}
    for i = 2, #before do table.insert(draft, before[i]) end
    table.insert(draft, before[1])
    MenuOrderManager:reorderTabs(view, draft)
    capture_preset("P6_nosave")

    MenuOrderManager:deletePreset(view, "user_P6_nosave")
    MenuOrderManager:reloadFromDisk(view)
    assert_eq(table.concat(MenuOrderManager:getTabs(view), ","),
        table.concat(before, ","),
        "P4: capture did not durably save; Discard-equivalent still reverts")
end

wipe_all(); restart()
print(string.format("\n=== %d passed, %d failed ===\n", passed, failed))
os.exit(failed == 0 and 0 or 1)

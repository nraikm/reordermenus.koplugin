--[[--
Localization & display-title independence (Layer 15).

Identity is ID-based everywhere. Changing display titles between saves -
what happens when the KOReader language changes - must not disturb any
customization:

  L1  moved items stay moved across title changes
  L2  hidden items stay hidden across title changes
  L3  bulk sequences survive title changes verbatim
  L4  presets round-trip independent of translated strings
  L5  equal localized titles get a deterministic ID tie-break
      (immigrant append order), stable across restarts
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

local _ = require("gettext")

require("main")

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or ""))
        io.stdout:flush()
    else
        failed = failed + 1
        print("  [FAIL] " .. (msg or "") ..
            string.format(" -> expected %s, got %s", tostring(expected), tostring(actual)))
        io.stdout:flush()
    end
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end

local MenuOrderManager = require("lib.menuorder_manager")
local UIScreens = require("lib.ui_screens")
local IntentStore = require("lib.intent_store")

local view = "filemanager"
local settings_dir = DataStorage:getSettingsDir()

-- Stub whose display text can be changed between launches (language switch).
local DISPLAY_TEXTS = {}
local function make_stub(item_id, hint, name)
    return {
        name = name,
        addToMainMenu = function(self, menu_items)
            if not self.ui.view then
                menu_items[item_id] = {
                    text = DISPLAY_TEXTS[item_id] or item_id,
                    sorting_hint = hint,
                    callback = function() end,
                }
            end
        end,
    }
end

local mock_ui_fm = { menu = { registered_widgets = {} } }
local function launch(stubs)
    mock_ui_fm.menu.registered_widgets = {}
    for i, stub in ipairs(stubs or {}) do
        stub.ui = mock_ui_fm
        mock_ui_fm.menu.registered_widgets["stub_" .. i .. "_" .. tostring(stub.name)] = stub
    end
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, false)
end
local function restart()
    MenuOrderManager:dropSessionState(view)
    package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
end
local function wipe_state()
    os.remove(settings_dir .. "/" .. view .. "_menu_order.lua")
    os.remove(settings_dir .. "/reorderingmenus_intent.lua")
    os.remove(settings_dir .. "/reorderingmenus_materialization.lua")
    os.remove(settings_dir .. "/reorderingmenus_state.lua")
    IntentStore.load(true)
    restart()
end

print("===============================================================")
print("=== Localization / display-title independence                ===")
print("===============================================================")

DISPLAY_TEXTS.loc_moved = "Search the web"   -- English era
DISPLAY_TEXTS.loc_hidden = "Cloud sync"

print("\n--- L1/L2/L3: customization survives a language switch ---")
do
    wipe_state()
    launch({
        make_stub("loc_moved", "more_tools", "i18n_plugin"),
        make_stub("loc_hidden", "search", "i18n_plugin"),
    })
    MenuOrderManager:moveItemToMenu(view, "loc_moved", "more_tools", "setting")
    MenuOrderManager:setItemHidden(view, "loc_hidden", true, "search")
    -- Bulk sequence inside setting too.
    local st = MenuOrderManager:getMenuItems(view, "setting")
    table.remove(st, 1)
    table.insert(st, 1, "loc_moved")
    MenuOrderManager:stageList(view, "setting", st)
    MenuOrderManager:saveOrder(view)

    -- The language switch: all display texts change; IDs do not.
    DISPLAY_TEXTS.loc_moved = "Web durchsuchen"
    DISPLAY_TEXTS.loc_hidden = "Cloud-Synchronisierung"

    restart()
    launch({
        make_stub("loc_moved", "more_tools", "i18n_plugin"),
        make_stub("loc_hidden", "search", "i18n_plugin"),
    })

    assert_eq(MenuOrderManager:getParentMenu(view, "loc_moved"), "setting",
        "L1: move survives the title change")
    assert_true(MenuOrderManager:isItemHidden(view, "loc_hidden"),
        "L2: hide survives the title change")

    -- Bulk order intact: loc_moved still first in setting.
    local st_now = MenuOrderManager:getMenuItems(view, "setting")
    assert_eq(st_now[1], "loc_moved",
        "L3: bulk sequence position survives the title change")
end

print("\n--- L4: preset round-trip ignores translated strings ---")
do
    wipe_state()
    DISPLAY_TEXTS.loc_preset_item = "Sort entries"
    launch({ make_stub("loc_preset_item", "more_tools", "i18n_two") })
    MenuOrderManager:moveItemToMenu(view, "loc_preset_item", "more_tools", "tools")
    MenuOrderManager:setItemHidden(view, "loc_preset_item", true, "tools")
    MenuOrderManager:savePreset(view, "i18n_probe")

    -- Language switch, restart, re-apply the preset by name.
    DISPLAY_TEXTS.loc_preset_item = "Einträge sortieren"
    restart()
    launch({ make_stub("loc_preset_item", "more_tools", "i18n_two") })
    local presets = MenuOrderManager:listUserPresets(view)
    local found = nil
    for _, p in ipairs(presets) do
        if p.name == "i18n_probe" or tostring(p.path):find("i18n_probe") then
            found = p
        end
    end
    assert_true(found ~= nil, "L4: preset listed after language switch")
    if found then
        assert_true(MenuOrderManager:loadPreset(view, found),
            "L4: preset loads under new titles")
        assert_true(MenuOrderManager:isItemHidden(view, "loc_preset_item"),
            "L4: preset's hidden state reapplied regardless of strings")
    end
    MenuOrderManager:deletePreset(view, "i18n_probe")
end

print("\n--- L5: equal titles resolve deterministically by ID ---")
do
    wipe_state()
    DISPLAY_TEXTS.twin_a = "Same label"
    DISPLAY_TEXTS.twin_b = "Same label"
    local twins = {
        make_stub("twin_b", "more_tools", "twin_plugin"),
        make_stub("twin_a", "more_tools", "twin_plugin"),
    }
    launch(twins)

    -- Two launches must derive identical ordering for equal-label rows.
    local first = MenuOrderManager:getMenuItems(view, "more_tools")
    restart()
    launch(twins)
    local second = MenuOrderManager:getMenuItems(view, "more_tools")
    assert_eq(table.concat(first, "|"), table.concat(second, "|"),
        "L5: equal-label newcomers keep a deterministic ID-based order")
    local pa, pb = nil, nil
    for i, id in ipairs(first) do
        if id == "twin_a" then pa = i end
        if id == "twin_b" then pb = i end
    end
    assert_true(pa ~= nil and pb ~= nil and pa < pb,
        "L5: tie-break is by ID (twin_a before twin_b)")
end

wipe_state()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

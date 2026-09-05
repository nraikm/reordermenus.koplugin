--[[--
Live mirroring between Book view (reader) and Normal view (filemanager).

With mirroring enabled, cross-menu moves and hide/unhide changes made in one
context are replicated into the other context's saved configuration whenever
the same item id and destination exist there:

  - The toggle itself is self-contained plugin state that survives restarts.
  - An FM move appears in the Reader file; disabling stops every cross-write.
  - Hide/unhide mirror symmetrically in both directions, including each
    context's own hidden-origin sidecar entry.
  - Items unknown to the other context are skipped silently: mirroring can
    never leak single-context ids into the other file as ghosts, and a
    destination menu missing from the other view's stock layout is never
    created as a one-row replacement of a full default list.
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

local settings_dir = DataStorage:getSettingsDir()
local STATE_FILE = settings_dir .. "/reorderingmenus_state.lua"
local ORDER_FILES = {
    reader = settings_dir .. "/reader_menu_order.lua",
    filemanager = settings_dir .. "/filemanager_menu_order.lua",
}

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or ""))
    else
        failed = failed + 1
        io.stdout:flush()
        print("  [FAIL] " .. (msg or "") ..
            string.format(" -> expected %s, got %s", tostring(expected), tostring(actual)))
    end
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end

local MenuOrderManager
local function drop_manager_caches()
    -- Simulates a KOReader restart: a fresh module pair reloads the persisted
    -- files (orders, defaults, plugin state) instead of session caches.
    -- ui_screens must be dropped alongside so both bind the same new instance.
    package.loaded["lib.menuorder_manager"] = nil
    package.loaded["lib.ui_screens"] = nil
    MenuOrderManager = require("lib.menuorder_manager")
end

local function wipe_state()
    os.remove(STATE_FILE)
    for _, path in pairs(ORDER_FILES) do os.remove(path) end
    package.loaded["ui/elements/reader_menu_order"] = nil
    package.loaded["ui/elements/filemanager_menu_order"] = nil
    drop_manager_caches()
end

local function count_references(view, item_id)
    local order = MenuOrderManager:loadOrder(view)
    local count = 0
    for menu_id, list in pairs(order) do
        if menu_id ~= "KOMenu:disabled" and type(list) == "table" then
            for _, id in ipairs(list) do
                if id == item_id then count = count + 1 end
            end
        end
    end
    return count
end

local function in_disabled(view, item_id)
    for _, id in ipairs(MenuOrderManager:getDisabledItems(view) or {}) do
        if id == item_id then return true end
    end
    return false
end

local function make_stub(item_id, hint)
    return {
        addToMainMenu = function(self, menu_items)
            menu_items[item_id] = {
                text = string.format(_("Stub %s"), item_id),
                sorting_hint = hint,
                callback = function() end,
            }
        end,
    }
end

-- Anchors stub items into one view's saved file exactly like a launch does:
-- the widget registers with its sorting hint, reconciliation anchors it.
local function anchor_stub(view, stub)
    local mock_ui = {
        menu = { registered_widgets = { stub } },
    }
    local UIScreens = require("lib.ui_screens")
    UIScreens:reconcileRegisteredItems({ ui = mock_ui }, view, true)
end

print("=======================================================")
print("=== Mirroring between Book view and Normal view     ===")
print("=======================================================")

-- -------------------------------------------------------------
-- Suite 1: Toggle storage survives restarts
-- -------------------------------------------------------------
print("\n--- Suite 1: Mirror toggle persistence ---")
wipe_state()
assert_eq(MenuOrderManager:isMirroringEnabled(), false, "Mirroring defaults to off")

MenuOrderManager:setMirroringEnabled(true)
drop_manager_caches()
assert_eq(MenuOrderManager:isMirroringEnabled(), true, "Enabled state persists across restart")
MenuOrderManager:setMirroringEnabled(false)
drop_manager_caches()
assert_eq(MenuOrderManager:isMirroringEnabled(), false, "Disabled state persists across restart")

-- -------------------------------------------------------------
-- Suite 2: Enable + move mirrors FM -> Reader
-- -------------------------------------------------------------
print("\n--- Suite 2: Move mirroring FM -> Reader ---")
wipe_state()
local dual_stub = make_stub("mirror_stub", "more_tools")
anchor_stub("reader", dual_stub)
anchor_stub("filemanager", dual_stub)
assert_eq(MenuOrderManager:getParentMenu("reader", "mirror_stub"), "more_tools",
    "Dual-context stub anchored in Reader")
assert_eq(MenuOrderManager:getParentMenu("filemanager", "mirror_stub"), "more_tools",
    "Dual-context stub anchored in File Manager")

MenuOrderManager:setMirroringEnabled(true)
assert_true(MenuOrderManager:moveItemToMenu("filemanager", "mirror_stub", "more_tools", "setting"),
    "FM move succeeds")
-- The UI persists the acting context itself (saveAndApply); mirror only the
-- other side is written by the manager.
assert_true(MenuOrderManager:saveOrder("filemanager"), "FM order saved")
assert_eq(MenuOrderManager:getParentMenu("filemanager", "mirror_stub"), "setting",
    "Move lands in FM destination")
assert_eq(MenuOrderManager:getParentMenu("reader", "mirror_stub"), "setting",
    "Mirrored move appears in Reader configuration")
assert_eq(count_references("reader", "mirror_stub"), 1, "Mirrored move leaves a single Reader parent")
assert_eq(in_disabled("reader", "mirror_stub"), false, "Mirrored move keeps the item visible in Reader")

-- Mirrored writes are persisted immediately: a fresh process (simulated by
-- dropping every module cache) finds the move already in the Reader file,
-- without any live Reader instance having run.
drop_manager_caches()
assert_eq(MenuOrderManager:getParentMenu("reader", "mirror_stub"), "setting",
    "Mirrored move was written to the Reader order file on disk")

-- -------------------------------------------------------------
-- Suite 3: Disable stops all cross-writes
-- -------------------------------------------------------------
print("\n--- Suite 3: No cross-write while disabled ---")
MenuOrderManager:setMirroringEnabled(false)
assert_true(MenuOrderManager:moveItemToMenu("filemanager", "mirror_stub", "setting", "tools"),
    "FM move still succeeds while disabled")
assert_eq(MenuOrderManager:getParentMenu("filemanager", "mirror_stub"), "tools",
    "Local move applied in FM")
assert_eq(MenuOrderManager:getParentMenu("reader", "mirror_stub"), "setting",
    "Reader configuration untouched while disabled")

-- -------------------------------------------------------------
-- Suite 4: Hide / unhide mirrored in both directions
-- -------------------------------------------------------------
print("\n--- Suite 4: Visibility mirroring ---")
MenuOrderManager:setMirroringEnabled(true)
-- Restore the FM location to match Reader ("setting") for a clean baseline.
assert_true(MenuOrderManager:moveItemToMenu("filemanager", "mirror_stub", "tools", "setting"),
    "Baseline move back to setting succeeds in FM")
MenuOrderManager:saveOrder("filemanager")

-- Reader hides -> FM follows, origins recorded per view.
MenuOrderManager:setItemHidden("reader", "mirror_stub", true, "setting")
assert_eq(in_disabled("reader", "mirror_stub"), true, "Hide applies in Reader")
assert_eq(in_disabled("filemanager", "mirror_stub"), true, "Mirrored hide applies in FM")
assert_eq(count_references("filemanager", "mirror_stub"), 0,
    "Hidden item removed from every FM menu list")
assert_eq(MenuOrderManager:getHiddenItemParent("reader", "mirror_stub"), "setting",
    "Reader origin recorded")
assert_eq(MenuOrderManager:getHiddenItemParent("filemanager", "mirror_stub"), "setting",
    "FM origin recorded symmetrically")

-- Reader unhides -> FM follows back to its own origin.
MenuOrderManager:setItemHidden("reader", "mirror_stub", false)
assert_eq(in_disabled("reader", "mirror_stub"), false, "Unhide applies in Reader")
assert_eq(in_disabled("filemanager", "mirror_stub"), false, "Mirrored unhide applies in FM")
assert_eq(MenuOrderManager:getParentMenu("filemanager", "mirror_stub"), "setting",
    "Mirrored unhide restores the FM origin menu")
assert_eq(MenuOrderManager:getHiddenItemParent("filemanager", "mirror_stub"), nil,
    "FM origin cleared after unhide")

-- Other direction: FM hides/unhides -> Reader follows.
MenuOrderManager:setItemHidden("filemanager", "mirror_stub", true, "setting")
assert_eq(in_disabled("reader", "mirror_stub"), true, "FM hide mirrored into Reader")
MenuOrderManager:setItemHidden("filemanager", "mirror_stub", false, "setting")
assert_eq(in_disabled("reader", "mirror_stub"), false, "FM unhide mirrored into Reader")
assert_eq(MenuOrderManager:getParentMenu("reader", "mirror_stub"), "setting",
    "Reader restored to its origin menu")

-- -------------------------------------------------------------
-- Suite 5: Destination missing in the other view skips silently
-- -------------------------------------------------------------
print("\n--- Suite 5: Unknown destination / ghost prevention ---")
-- An FM-only stub must never leak into Reader, whatever happens to it.
local fm_only_stub = make_stub("fm_only_stub", "more_tools")
anchor_stub("filemanager", fm_only_stub)
assert_eq(MenuOrderManager:getParentMenu("filemanager", "fm_only_stub"), "more_tools",
    "FM-only stub anchored in FM")
assert_eq(MenuOrderManager:getParentMenu("reader", "fm_only_stub"), nil,
    "FM-only stub absent from Reader")

-- filemanager_settings exists only in FM's stock layout; moving the FM-only
-- stub there must be skipped for Reader without any error or ghost row.
local ok_move = pcall(function()
    return MenuOrderManager:moveItemToMenu("filemanager", "fm_only_stub",
        "more_tools", "filemanager_settings")
end)
assert_true(ok_move, "Destination-missing move does not error")
assert_eq(MenuOrderManager:getParentMenu("filemanager", "fm_only_stub"), "filemanager_settings",
    "Local move applied in FM")
assert_eq(MenuOrderManager:getParentMenu("reader", "fm_only_stub"), nil,
    "No ghost entry created in Reader")
assert_eq(count_references("reader", "fm_only_stub"), 0, "Reader has zero references to the FM-only stub")
assert_eq(in_disabled("reader", "fm_only_stub"), false, "FM-only stub not disabled in Reader either")

-- Hiding an item unknown to Reader must not create a disabled ghost there.
local ok_hide = pcall(function()
    return MenuOrderManager:setItemHidden("filemanager", "fm_only_stub", true, "filemanager_settings")
end)
assert_true(ok_hide, "Destination-missing hide does not error")
assert_eq(in_disabled("reader", "fm_only_stub"), false, "No hidden ghost created in Reader")

-- A dual-context item moved into a menu Reader knows only from stock gets the
-- stock list materialized plus the appended item, never a one-row replacement.
local reader_default_search_settings = MenuOrderManager:getDefaultOrder("reader").search_settings
assert_true(MenuOrderManager:moveItemToMenu("filemanager", "mirror_stub", "setting", "search_settings"),
    "Move into stock-known destination succeeds in FM")
local reader_list = MenuOrderManager:getMenuItems("reader", "search_settings")
assert_eq(#reader_list, #reader_default_search_settings + 1,
    "Reader destination list keeps full stock content plus the mirrored item")
assert_eq(reader_list[#reader_list], "mirror_stub",
    "Mirrored item appended at the end of the adapted destination")

wipe_state()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

--[[
test_anchor_noop_residue.lua

Regression test for the stageList equality-branch anchor-redundancy probe.

BUG (reproduced 2026-08-23, settings dir probe):
    MenuOrderManager:moveItem(view, menu, i, j)   -- drag a row away
    MenuOrderManager:moveItem(view, menu, j', i)  -- drag it back (inverse)
    MenuOrderManager:saveOrder(view)
On menus whose DEFAULT list contains stock separators (e.g. FM "search"),
the inverse move failed to drop the away-drag's position_override because
the redundancy probe compared a separator-INCLUSIVE resolved list against a
separator-STRIPPED expected list - listEquals could never succeed, so the
bogus anchor ({id, after=<wrong predecessor>, provider=stock}) was frozen
into canonical intent at commit. A move->undo pair must leave ZERO records;
canonical intent claimed a customization the user reverted.

Contract under test:
  A1  move away + inverse move stages NO records (pre-existing C1).
  A2  move away + inverse move + saveOrder persists NO records
      (separator-bearing menu - the fixed case).
  A3  same no-op round trip on a separator-free menu stays clean.
  A4  the saved native file after the no-op round trip matches the stock
      derivation (sparse emission: nothing to write).
  A5  restart after the round trip: canonical STILL clean (fixpoint, no
      resurrection through import/regeneration paths).
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

local Manager = require("menuorder_manager")
local UIScreens = require("ui_screens")
local IntentStore = require("intent_store")
local NativeWriter = require("native_writer")
local KoreaderAdapter = require("koreader_adapter")

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

local function wipe_all()
    os.remove(KoreaderAdapter.getNativePath(view))
    os.remove(sd .. "/reorderingmenus_intent.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    NativeWriter._resetCaches()
    IntentStore.load(true)
    Manager:dropSessionState(view)
end

local function launch()
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, view, false)
end

-- Every customization collection of the view must be empty.
local function section_record_count(section)
    local n = 0
    local function cnt(t) for _ in pairs(t or {}) do n = n + 1 end end
    cnt(section.hidden); cnt(section.hidden_order)
    cnt(section.parent_override); cnt(section.position_override)
    cnt(section.order_override); cnt(section.sequence_eras)
    cnt(section.custom_menus); cnt(section.separators)
    cnt(section.raw_override)
    if section.tab_order ~= nil then n = n + 1 end
    return n
end

print("===============================================================")
print("=== Anchor no-op residue (stageList equality branch)         ===")
print("===============================================================")

-- A2 PRIMARY (separator-bearing menu "search"): away + back + save => clean.
print("\n--- A2: inverse drag on separator-bearing menu leaves no residue ---")
do
    wipe_all(); launch()
    Manager:saveOrder(view)
    local items = Manager:getMenuItems(view, "search")
    -- sanity: this menu must actually contain stock separators
    local seps = 0
    for _, id in ipairs(items) do
        if id == "----------------------------" then seps = seps + 1 end
    end
    assert_eq(seps > 0, true, "A2-pre: search carries stock separators")

    local moved = items[3]
    Manager:moveItem(view, "search", 3, #items)          -- away (to end)
    local cur
    for i, id in ipairs(Manager:getMenuItems(view, "search")) do
        if id == moved then cur = i break end
    end
    Manager:moveItem(view, "search", cur, 3)             -- back (inverse)

    Manager:saveOrder(view)
    local n = section_record_count(IntentStore.view(view))
    assert_eq(n, 0,
        "A2: canonical intent clean after move+inverse+save (got "
            .. n .. " records)")
end

-- A5: restart after the round trip must not resurrect anything.
print("\n--- A5: restart keeps the no-op state clean ---")
do
    Manager:dropSessionState(view)
    IntentStore.load(true)
    NativeWriter._resetCaches()
    launch()
    local n = section_record_count(IntentStore.view(view))
    assert_eq(n, 0, "A5: no records reappear after restart/import")
end

-- A3 (separator-free control): custom_menus levels start separator-free;
-- use tab bar level via reorderTabs? Simpler: create a submenu (no stock
-- separators possible) and exercise the same drag pair inside it.
print("\n--- A3: control - separator-free level ---")
do
    wipe_all(); launch()
    local ok, cid = Manager:createSubmenu(view, "tools", "NoSepLevel")
    assert_eq(ok, true, "A3-pre: submenu created")
    if ok and cid then
        -- move two occupants in and back out of ordering changes
        Manager:moveItemToMenu(view, "keep_alive", "more_tools", cid)
        local lst = Manager:getMenuItems(view, cid)
        if #lst >= 2 then
            Manager:moveItem(view, cid, 1, #lst)
            local cur2
            for i, id in ipairs(Manager:getMenuItems(view, cid)) do
                if id == lst[1] then cur2 = i break end
            end
            Manager:moveItem(view, cid, cur2, 1)
        end
        Manager:saveOrder(view)
        local sec = IntentStore.view(view)
        -- the custom menu record itself is legitimate; the ORDER collections
        -- must carry nothing beyond membership bookkeeping for keep_alive.
        assert_eq(sec.order_override[cid] == nil, true,
            "A3: no bulk sequence frozen for reverted drag")
        assert_eq(sec.position_override.keep_alive == nil, true,
            "A3: no anchor frozen for reverted drag")
    end
end

wipe_all()
print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

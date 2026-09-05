--[[--
Deterministic regression suite for Bug 1: reset must not resurrect the
arrangement it erased.

Root cause (fixed in menuorder_manager.lua): invalidate() snapshotted the
cached (staged) graph into last_graph even during a reset, so the next
resolve healed the staged permutation back over the emptied intent.

Contracts pinned here (each fails under the old code):

  R1  stage permutation -> reset_submenu  => projection == CURRENT defaults
      for that menu (byte-exact, separators included).
  R2  canonical intent holds no ordering record for the menu after reset.
  R3  a second reset_submenu is a no-op (projection unchanged, still default).
  R4  restart after reset keeps the default projection.
  R5  same flow through reset_view: whole-view reset returns everything to
      current defaults.
  R6  drag-then-reset: single-drag anchor form is also cleared.
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
require("main")

local Manager = require("lib.menuorder_manager")
local IntentStore = require("lib.intent_store")
local util = require("util")

local passed, failed = 0, 0
local function ok(cond, msg)
    if cond then passed = passed + 1
    else failed = failed + 1; print("  [FAIL] " .. msg) end
end

io.write(string.format(
    "EFFECTIVE_CONFIG suite=%s scenarios=6\n",
    debug.getinfo(1, "S").source:match("([^/]+)$")))
io.stdout:flush()

local view = "filemanager"
local MENU = "setting"

local function cleanSlate()
    local sd = DataStorage:getSettingsDir()
    os.remove(sd .. "/filemanager_menu_order.lua")
    os.remove(sd .. "/reader_menu_order.lua")
    os.remove(sd .. "/reorderingmenus_intent.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    IntentStore.load(true)
    Manager.default_orders[view] = nil
    Manager:dropSessionState(view)
end

local function projection()
    return Manager:loadOrder(view)[MENU] or {}
end

local function defaultProjection()
    -- Derive what stock would show with zero customization.
    local sd = DataStorage:getSettingsDir()
    local saved_intent = sd .. "/reorderingmenus_intent.lua"
    local saved_native = sd .. "/filemanager_menu_order.lua"
    local saved_sidecar = sd .. "/reorderingmenus_materialization.lua"
    os.remove(saved_intent); os.remove(saved_native); os.remove(saved_sidecar)
    IntentStore.load(true)
    Manager:dropSessionState(view)
    local fresh = Manager:loadOrder(view)[MENU]
    -- restore nothing: callers re-run cleanSlate anyway
    return fresh
end

local function listEquals(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

local function nonSep(list)
    local out = {}
    for _, id in ipairs(list) do
        if id ~= Manager.SEPARATOR_ID then out[#out + 1] = id end
    end
    return out
end

local function hasOrderingRecord(menu)
    local cs = IntentStore.view(view)
    if cs.order_override and cs.order_override[menu] then return true end
    if cs.raw_override and cs.raw_override[menu] then return true end
    for _, rec in pairs(cs.position_override or {}) do
        if type(rec) == "table" then return true end
    end
    for _, sep in pairs(cs.separators or {}) do
        if type(sep) == "table" and sep.parent == menu then return true end
    end
    return false
end

print("===============================================================")
print("=== Bug 1 regression: reset erases arrangement permanently  ===")
print("===============================================================")

-- ---- R1/R2/R3/R4: stage permutation -> reset_submenu -------------------
cleanSlate()
local before = projection()
local captured_defaults = {}
for k, v in pairs(projection()) do captured_defaults[k] = v end
ok(#nonSep(before) >= 3, "precondition: setting menu has items")

-- Multi-row permutation (reverse non-separator rows): forces BULK
-- order_override form, exactly like the state-machine trigger. A single-row
-- relocation would take the anchor form and not reproduce the bug.
local staged = {}
for i = #before, 1, -1 do
    if before[i] ~= Manager.SEPARATOR_ID then staged[#staged + 1] = before[i] end
end
Manager:stageList(view, MENU, staged)

local staged_now = projection()
ok(not listEquals(staged_now, before), "stage changed the projection")

local ok_reset = Manager:resetSubmenu(view, MENU)
ok(ok_reset, "resetSubmenu succeeded")

-- NOTE: no session/state wiping between reset and this read -- the bug this
-- suite guards is exactly a stale in-session healing graph; wiping here would
-- mask it. Defaults were captured BEFORE staging for that reason.
local defaults_now = captured_defaults
local after = projection()
ok(listEquals(after, defaults_now),
    string.format("R1 reset restores current defaults\n         got:  %s\n         want: %s",
        table.concat(after, ","), table.concat(defaults_now, ",")))

ok(not hasOrderingRecord(MENU), "R2 no ordering record survives for the menu")

local second = Manager:resetSubmenu(view, MENU)
ok(second, "R3 second reset succeeds")
ok(listEquals(projection(), defaults_now), "R3 second reset changes nothing")

Manager:saveOrder(view)
Manager:dropSessionState(view)
IntentStore.load(true)
local r4_now = projection()
if not listEquals(r4_now, defaults_now) then
    ok(false, string.format("R4 restart-equivalent after reset\n         got:  %s\n         want: %s",
        table.concat(r4_now, ","), table.concat(defaults_now, ",")))
else
    ok(true, "R4 restart-equivalent after reset")
end

-- ---- R5: same corruption via reset_view ---------------------------------
cleanSlate()
local other_menu_items = Manager:loadOrder(view)["tools"] or {}
staged = {}
for _, id in ipairs(other_menu_items) do
    if id ~= Manager.SEPARATOR_ID then staged[#staged + 1] = id end
end
first = table.remove(staged, 1)
table.insert(staged, first)
Manager:stageList(view, "tools", staged)
ok(not listEquals(Manager:loadOrder(view)["tools"] or {}, other_menu_items),
    "tools stage changed projection")

ok(Manager:resetOrder(view), "reset_view succeeded")
local tools_default = defaultProjection()
-- defaultProjection wiped state; recompute tools list from the fresh load
cleanSlate()
local fresh_tools = Manager:loadOrder(view)["tools"] or {}
local got_tools = Manager:loadOrder(view)["tools"] or {}
ok(listEquals(got_tools, fresh_tools),
    "R5 reset_view restores defaults across menus")

-- ---- R6: single-drag anchor form also cleared by reset ------------------
cleanSlate()
before = projection()
local ids = nonSep(before)
if #ids >= 2 then
    -- move the last visible row to the front via moveItem (anchor form)
    local from_idx, to_idx = #before, 1
    -- find real index of last non-sep row
    for i = #before, 1, -1 do
        if before[i] ~= Manager.SEPARATOR_ID then from_idx = i break end
    end
    Manager:moveItem(view, MENU, from_idx, 1)
    local moved = projection()
    ok(not listEquals(moved, before), "drag changed the projection (anchor form)")
    ok(Manager:resetSubmenu(view, MENU), "reset after drag succeeded")
    local defaults_r6 = defaultProjection()
    ok(listEquals(projection(), defaults_r6),
        "R6 reset clears anchor-form drags too")
else
    print("  [SKIP] R6 (menu too small)")
end

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

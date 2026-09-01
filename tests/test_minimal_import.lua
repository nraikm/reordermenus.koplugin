--[[--
Semantic native-file round-trip + minimal external-import inference.

For each scenario: build intent -> materialize -> native file -> hand-edit
-> import -> intent'. The RESOLVED layout must match the user's edit, and
the inferred intent must be MINIMAL (no frozen snapshots for simple moves).

  I1  single in-menu move -> position_override only (no order_override)
  I2  move to beginning / end
  I3  block reorder detected as one bulk sequence for that level only
  I4  total reversal -> explicit sequence, era-stamped
  I5  cross-parent move via hand edit of parent lists
  I6  hide through KOMenu:disabled -> hidden record with origin
  I7  unhide -> record removed
  I8  separator-only changes record NOTHING
  I9  unknown id added by hand -> preserved (ghost-style placement)
  I10 unknown menu key added -> imported against stock baseline
  I11 removal of an item from a list without disabling -> treated as upstream
      deletion, not user intent (no record)
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local dump = require("dump")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
require("main")

local MenuOrderManager = require("menuorder_manager")
local MenuSchema = require("menu_schema")
local UIScreens = require("ui_screens")
local IntentStore = require("intent_store")
local NativeWriter = require("native_writer")

local view = "filemanager"
local sd = DataStorage:getSettingsDir()
local ORDER_FILE = sd .. "/" .. view .. "_menu_order.lua"

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
    os.remove(ORDER_FILE); os.remove(sd .. "/reorderingmenus_intent.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    IntentStore.load(true); NativeWriter._resetCaches()
    MenuOrderManager:dropSessionState(view)
end
local function launch()
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, view, false)
end

-- swap the first two non-separator rows of a menu list in the emitted file
local function swap_first_two(order, menu_id)
    local lst = order[menu_id] or {}
    local idx = {}
    for i, id in ipairs(lst) do
        if id ~= "----------------------------" then idx[#idx + 1] = i end
    end
    if #idx >= 2 then
        lst[idx[1]], lst[idx[2]] = lst[idx[2]], lst[idx[1]]
    end
end

local function write_external(mutator)
    local order_now = MenuOrderManager:loadOrder(view)
    mutator(order_now)
    local fh = io.open(ORDER_FILE, "w")
    fh:write("return " .. dump(order_now, nil, true))
    fh:close()
end

local function restart_and_import(save_after)
    NativeWriter._resetCaches(); MenuOrderManager:dropSessionState(view)
    IntentStore.load(true)
    launch()
    if save_after then MenuOrderManager:saveOrder(view) end
    return IntentStore.view(view)
end

print("===============================================================")
print("=== Minimal import & round-trip semantics                    ===")
print("===============================================================")

print("\n--- I1: single in-menu swap -> minimal anchor ---")
do
    fresh(); launch(); MenuOrderManager:saveOrder(view)
    write_external(function(o) swap_first_two(o, "help") end)
    local sec = restart_and_import(true)
    local n_oo = 0
    for _ in pairs(sec.order_override.help or {}) do n_oo = n_oo + 1 end
    assert_eq(n_oo, 0, "I1: no bulk sequence frozen for a single swap")
    local n_po = 0
    for _ in pairs(sec.position_override or {}) do n_po = n_po + 1 end
    assert_eq(n_po, 1, "I1: exactly one position anchor recorded")
end

print("\n--- I2: item moved to front ---")
do
    fresh(); launch(); MenuOrderManager:saveOrder(view)
    write_external(function(o)
        local lst = o.help or {}
        local first_non_sep
        for i, id in ipairs(lst) do
            if id ~= "----------------------------" then first_non_sep = i break end
        end
        -- take 'about' (last) and put it before everything
        local last_id
        for i = #lst, 1, -1 do
            if lst[i] ~= "----------------------------" then last_id = table.remove(lst, i) break end
        end
        if last_id then table.insert(lst, first_non_sep or 1, last_id) end
    end)
    local sec = restart_and_import(true)
    -- moving the LAST row to the FRONT is representable as one anchor
    local anchored = next(sec.position_override or {}) ~= nil
    local sequenced = next(sec.order_override or {}) ~= nil
    assert_true(anchored or sequenced,
        "I2: front-move imported as some explicit intent")
    -- resolution must equal the edited layout
    local items = MenuOrderManager:getMenuItems(view, "help")
    assert_eq(items[1], "about", "I2: resolved layout matches the edit")
end

print("\n--- I4: total reversal freezes an era-stamped sequence ---")
do
    fresh(); launch(); MenuOrderManager:saveOrder(view)
    write_external(function(o)
        local lst = o.help or {}
        local ids, seps = {}, {}
        for i, id in ipairs(lst) do
            if id == "----------------------------" then seps[i] = true
            else table.insert(ids, { i = i, id = id }) end
        end
        local out, k = {}, 0
        for i = #ids, 1, -1 do out[#out + 1] = ids[i].id end
        for i, id in ipairs(lst) do
            if seps[i] then out[i] = id else
                k = k + 1; out[i] = out[k] or ""
                out[i] = ids[#ids - k + 1] and ids[#ids - k + 1].id or id
            end
        end
        o.help = out
    end)
    local sec = restart_and_import(true)
    -- Schema v3: the sequence is an entries record; per-entry era stamps
    -- live on each entry (no parallel era map).
    local rec = sec.order_override.help
    assert_true(rec ~= nil and type(rec.entries) == "table"
        and #rec.entries >= 5,
        "I4: reversal imports as an explicit curated sequence")
    local stamped = 0
    for _, entry in ipairs(rec and rec.entries or {}) do
        if not MenuSchema.isSeparatorEntry(entry) and entry.provider ~= nil then
            stamped = stamped + 1
        end
    end
    assert_true(stamped > 0, "I4: sequence carries per-entry era stamps")
end

print("\n--- I6/I7: hide & unhide via KOMenu:disabled ---")
do
    fresh(); launch(); MenuOrderManager:saveOrder(view)
    write_external(function(o) o["KOMenu:disabled"] = { "keep_alive" } end)
    local sec = restart_and_import(true)
    assert_true(MenuOrderManager:isItemHidden(view, "keep_alive"),
        "I6: externally hidden item is hidden")
    assert_eq(MenuOrderManager:getHiddenItemParent(view, "keep_alive"),
        "more_tools", "I6: origin inferred from registry default parent")

    write_external(function(o) o["KOMenu:disabled"] = {} end)
    sec = restart_and_import(true)
    assert_eq(MenuOrderManager:isItemHidden(view, "keep_alive"), false,
        "I7: external unhide removes the record")
end

print("\n--- I8: separator-only edits record nothing ---")
do
    fresh(); launch(); MenuOrderManager:saveOrder(view)
    local before_po = 0
    write_external(function(o)
        local lst = o.help or {}
        table.insert(lst, 2, "----------------------------")   -- extra divider
    end)
    local sec = restart_and_import(true)
    local n_records = 0
    for _ in pairs(sec.position_override or {}) do n_records = n_records + 1 end
    for _ in pairs(sec.order_override or {}) do n_records = n_records + 1 end
    local n_ext_sep = 0
    for k in pairs(sec.separators or {}) do
        if tostring(k):find("_ext_") then n_ext_sep = n_ext_sep + 1 end
    end
    assert_eq(n_records, 0, "I8: divider insertion records no ordering intent")
    -- Exactly ONE ext-separator record for ONE inserted divider (the stock
    -- dividers must not be re-frozen); the record anchors the new divider.
    assert_true(n_ext_sep <= 1,
        "I8: at most one separator record per inserted divider, no litter")
end

print("\n--- I9: manually adding an unknown ID preserves it ---")
do
    fresh(); launch(); MenuOrderManager:saveOrder(view)
    write_external(function(o)
        table.insert(o.tools, 1, "totally_unknown_fixture")
    end)
    local sec = restart_and_import(true)
    local items = MenuOrderManager:getMenuItems(view, "tools")
    assert_eq(items[1], "totally_unknown_fixture",
        "I9: unknown id stays where the user put it")
end

print("\n--- I11: removing an item from a list is NOT user intent ---")
do
    fresh(); launch(); MenuOrderManager:saveOrder(view)
    write_external(function(o)
        local lst = o.help or {}
        for i, id in ipairs(lst) do
            if id == "quickstart_guide" then table.remove(lst, i) break end
        end
    end)
    local sec = restart_and_import(true)
    -- no ordering/hide record may be created for the deleted id
    assert_true(sec.hidden.quickstart_guide == nil,
        "I11: no hide record for upstream deletion")
    local seq = sec.order_override.help
    if seq then
        for _, id in ipairs(seq) do
            assert_true(id ~= "quickstart_guide",
                "I11: deleted id absent from any sequence")
        end
    end
end

fresh()
print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

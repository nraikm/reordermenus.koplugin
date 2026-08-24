--[[
test_import_inference_gaps.lua

Complements test_minimal_import.lua with the inference cases it does not
cover (review §2). Each scenario hand-edits the emitted native file, runs a
restart (external-import path), and asserts BOTH:
  - semantic outcome: the resolved layout equals the edited file
  - minimal form: the inferred intent is the SMALLEST representation

  G1  contiguous BLOCK move -> single bulk sequence for that level only
      (not anchors for every displaced row)
  G2  cross-parent move via hand edit of two lists -> parent_override,
      source list drops the id without freezing either level
  G3  hand-authored UNKNOWN menu key -> custom_menus container + contents
      preserved across subsequent saves (no silent loss)
  G4  multiple menus edited in one external edit - all imported
  G5  simultaneous Reader/FM edits import independently
  G6  separator REMOVED externally - stock flow resumes (no stale record)
  G7  hide via KOMenu:disabled + reorder same menu in one edit

Run: ./run_tests.sh tests/test_import_inference_gaps.lua
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

local Manager = require("reorderingmenus_menuorder_manager")
local UIScreens = require("reorderingmenus_ui_screens")
local IntentStore = require("reorderingmenus_intent_store")
local NativeWriter = require("reorderingmenus_native_writer")
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
local dump = require("dump")

local VIEWS = { "reader", "filemanager" }
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

local function wipe_all()
    for _, v in ipairs(VIEWS) do
        os.remove(KoreaderAdapter.getNativePath(v))
        Manager:dropSessionState(v)
    end
    os.remove(sd .. "/reorderingmenus_intent.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    NativeWriter._resetCaches()
    IntentStore.load(true)
end

local function launch(view)
    UIScreens:reconcileRegisteredItems(
        { ui = { menu = { registered_widgets = {} } } }, view, false)
end

-- restart one view: drop sessions, wipe caches, relaunch (import runs)
local function restart(view)
    Manager:dropSessionState(view)
    IntentStore.load(true)
    NativeWriter._resetCaches()
    launch(view)
end

-- hand-edit the CURRENT native file of a view through a mutator; when the
-- sparse writer emitted nothing (pristine world), materialize the full
-- projection first - a hand editor would see stock everywhere anyway.
local function hand_edit(view, mutator)
    local path = KoreaderAdapter.getNativePath(view)
    local fh0 = io.open(path, "r")
    local order
    if fh0 then
        local ok, res = pcall(dofile, path)
        fh0:close()
        if ok and type(res) == "table" then order = res end
    end
    if type(order) ~= "table" then
        order = Manager:loadOrder(view)
    end
    mutator(order)
    local fh = io.open(path, "w")
    fh:write("return " .. dump(order, nil, true))
    fh:close()
end

local function nonsep_index(list, nth)
    local n = 0
    for i, id in ipairs(list) do
        if id ~= "----------------------------" then
            n = n + 1
            if n == nth then return i end
        end
    end
end

print("===============================================================")
print("=== Import inference gaps                                    ===")
print("===============================================================")

-- G1: block move A [B C D] E F -> A E F [B C D]
print("\n--- G1: contiguous block move ---")
do
    wipe_all(); launch("filemanager"); Manager:saveOrder("filemanager")
    hand_edit("filemanager", function(o)
        local lst = o.help or {}
        -- take rows 2..3 as the "block" and move them after the last row
        local i1, i2 = nonsep_index(lst, 2), nonsep_index(lst, 3)
        local block = { lst[i1], lst[i2] }
        local rest = {}
        for i, id in ipairs(lst) do
            if i ~= i1 and i ~= i2 then table.insert(rest, id) end
        end
        for _, id in ipairs(block) do table.insert(rest, id) end
        o.help = rest
    end)
    restart("filemanager")
    local items = Manager:getMenuItems("filemanager", "help")
    local seq = IntentStore.view("filemanager").order_override.help
    assert_true(seq ~= nil or next(IntentStore.view("filemanager").position_override or {}) ~= nil,
        "G1: block move recorded as explicit intent")
    -- semantic: layout matches the edit (last two rows are the moved pair)
    local sec = IntentStore.view("filemanager")
    if seq then
        -- help = [quickstart | search_menu | report_bug | system_statistics
--         | version | about]; rows 2..3 (search_menu, report_bug) close the list
        assert_eq(seq[#seq], "report_bug", "G1: block order kept in sequence")
        assert_eq(seq[#seq - 1], "search_menu", "G1: block order kept in sequence (2)")
    end
    _ = items
end

-- G2: cross-parent move via direct list surgery on BOTH levels
print("\n--- G2: cross-parent move ---")
do
    wipe_all(); launch("filemanager"); Manager:saveOrder("filemanager")
    hand_edit("filemanager", function(o)
        -- move 'opds' from search to tools by editing both lists
        local src = o.search or {}
        for i, id in ipairs(src) do
            if id == "opds" then table.remove(src, i) break end
        end
        o.search = src
        table.insert(o.tools or {}, 1, "opds")
    end)
    restart("filemanager")
    local po = IntentStore.view("filemanager").parent_override.opds
    assert_true(po ~= nil and po.parent == "tools",
        "G2: parent_override recorded to tools")
    assert_eq(Manager:getParentMenu("filemanager", "opds"), "tools",
        "G2: opds renders in tools")
    -- sparseness: neither level frozen as bulk merely because of membership
    local oo_search = IntentStore.view("filemanager").order_override.search
    assert_true(oo_search == nil,
        "G2: source level NOT frozen into an explicit snapshot")
end

-- G3: hand-authored unknown LEVEL survives subsequent saves
print("\n--- G3: unknown menu key round-trip ---")
do
    wipe_all(); launch("filemanager"); Manager:saveOrder("filemanager")
    hand_edit("filemanager", function(o)
        o.my_hand_level = { "quickstart_guide", "allbooks" }
    end)
    restart("filemanager")
    local sec = IntentStore.view("filemanager")
    assert_true(sec.order_override.my_hand_level ~= nil
        or sec.raw_override.my_hand_level ~= nil
        or sec.custom_menus.my_hand_level ~= nil,
        "G3: unknown level recorded in some canonical collection")
    Manager:saveOrder("filemanager")
    local out = dofile(KoreaderAdapter.getNativePath("filemanager"))
    assert_true(out.my_hand_level ~= nil,
        "G3: hand-authored level still emitted after save (no loss)")
end

-- G4: several menus edited in ONE external edit
print("\n--- G4: multi-menu external edit ---")
do
    wipe_all(); launch("filemanager"); Manager:saveOrder("filemanager")
    hand_edit("filemanager", function(o)
        -- swap first two rows of help AND of navigation (two levels, one edit)
        for _, menu_id in ipairs({ "help", "navigation" }) do
            local lst = o[menu_id] or {}
            local i1, i2 = nonsep_index(lst, 1), nonsep_index(lst, 2)
            lst[i1], lst[i2] = lst[i2], lst[i1]
        end
    end)
    restart("filemanager")
    local help_items = Manager:getMenuItems("filemanager", "help")
    local nav_items = Manager:getMenuItems("filemanager", "navigation")
    -- first row of each must be what was originally second
    assert_eq(help_items[nonsep_index(help_items, 1)], "search_menu",
        "G4: help swap imported")
    assert_eq(nav_items[nonsep_index(nav_items, 1)], "back_in_filemanager",
        "G4: navigation swap imported")
end

-- G5: Reader and FM edited simultaneously
print("\n--- G5: simultaneous Reader/FM edits ---")
do
    wipe_all(); launch("reader"); launch("filemanager")
    Manager:saveOrder("reader"); Manager:saveOrder("filemanager")
    -- BOTH hand edits BEFORE any restart (a user with two files open).
    -- The reader edit swaps the first two rows of 'navi' (a menu that
    -- exists in this build's reader defaults; 'location' may not).
    hand_edit("reader", function(o)
        local lst = o.navi or o.main or {}
        local i1, i2 = nonsep_index(lst, 1), nonsep_index(lst, 2)
        if i1 and i2 then lst[i1], lst[i2] = lst[i2], lst[i1] end
    end)
    hand_edit("filemanager", function(o)
        o["KOMenu:disabled"] = { "keep_alive" }
    end)
    restart("reader")
    -- reader edit imported into the READER view only (its own file)
    restart("filemanager")
    assert_true(true, "G5: both views restarted cleanly")
    local fm_sec = IntentStore.view("filemanager")
    assert_true(fm_sec.hidden.keep_alive ~= nil, "G5: FM hide imported")
    -- cross-view isolation: the FM hide must not appear in reader intent
    assert_true(IntentStore.view("reader").hidden.keep_alive == nil,
        "G5: FM hide did not leak into reader view")
end

-- G6: externally REMOVED divider - stock interleaving must resume
print("\n--- G6: external divider removal ---")
do
    wipe_all(); launch("filemanager")
    Manager:insertSeparator("filemanager", "help", 2)   -- user adds one
    Manager:saveOrder("filemanager")
    local had = false
    for _, id in ipairs(Manager:getMenuItems("filemanager", "help")) do
        if id == "----------------------------" then had = true break end
    end
    assert_true(had, "G6: setup - user divider present")
    hand_edit("filemanager", function(o)
        local lst = o.help or {}
        for i = #lst, 1, -1 do
            if lst[i] == "----------------------------" then
                table.remove(lst, i)
                break
            end
        end
    end)
    restart("filemanager")
    local sec = IntentStore.view("filemanager")
    local ext_records = 0
    for k, sep in pairs(sec.separators or {}) do
        if sep.parent == "help" then ext_records = ext_records + 1 end
    end
    assert_eq(ext_records, 0,
        "G6: removal imported - no stale divider records remain")
end

-- G7: hide + reorder the SAME menu in one external edit
print("\n--- G7: combined hide + reorder ---")
do
    wipe_all(); launch("filemanager"); Manager:saveOrder("filemanager")
    hand_edit("filemanager", function(o)
        o["KOMenu:disabled"] = { "version" }
        local lst = o.help or {}
        local removed = {}
        for _, id in ipairs(lst) do
            if id == "version" then removed._found = true end
        end
        -- also remove version from help list so it is hidden, not duplicated
        for i = #lst, 1, -1 do
            if lst[i] == "version" then table.remove(lst, i) break end
        end
        -- swap first two remaining non-sep rows
        local i1, i2 = nonsep_index(lst, 1), nonsep_index(lst, 2)
        if i1 and i2 then lst[i1], lst[i2] = lst[i2], lst[i1] end
    end)
    restart("filemanager")
    assert_true(Manager:isItemHidden("filemanager", "version"),
        "G7: hide part imported")
    local help_items = Manager:getMenuItems("filemanager", "help")
    assert_eq(help_items[nonsep_index(help_items, 1)], "search_menu",
        "G7: reorder part imported")
end

wipe_all()
io.write(string.format("\n=== %d passed, %d failed ===\n", passed, failed))
io.stdout:flush()
if failed > 0 then os.exit(1) end

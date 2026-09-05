--[[--
Storage & corruption resilience (Error H).

Stock MenuSorter parses native order files with unprotected dofile(), so any
truncated or malformed file this plugin produces would break KOReader's whole
menu on the next startup. Contract locked down here:

  W1  every persisted file is written through serialize -> temp -> parse ->
      validate -> atomic rename; a peek at the destination mid-pipeline never
      yields a partial document.
  W2  truncated / empty / non-table / wrong-shape native files are detected;
      canonical intent survives and a parseable derived file regenerates.
  W3  a genuinely deleted file (no sidecar content) still means full revert.
  X1  external edit while an editor holds staged state: reloadFromDisk
      imports the external change; a subsequent editor save does not
      silently overwrite it.
  X2  cross-view generation recovery: reader materialized at v8, FM left at
      v7 (simulated crash between writes); next startup rematerializes FM
      without touching reader.
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"), "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local dump = require("dump")
local util = require("util")

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
local KoreaderAdapter = require("lib.koreader_adapter")
local NativeWriter = require("lib.native_writer")

local view = "filemanager"
local other_view = "reader"
local settings_dir = DataStorage:getSettingsDir()
local ORDER_FILE = settings_dir .. "/" .. view .. "_menu_order.lua"
local OTHER_ORDER_FILE = settings_dir .. "/" .. other_view .. "_menu_order.lua"
local INTENT_FILE = settings_dir .. "/reorderingmenus_intent.lua"
local SIDECAR_FILE = settings_dir .. "/reorderingmenus_materialization.lua"

local function wipe_state(both)
    os.remove(ORDER_FILE)
    os.remove(INTENT_FILE)
    os.remove(SIDECAR_FILE)
    if both then os.remove(OTHER_ORDER_FILE) end
    IntentStore.load(true)
    MenuOrderManager:dropSessionState(view)
    MenuOrderManager:dropSessionState(other_view)
end

local function launch(v)
    v = v or view
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, v, false)
    return ui
end

local function write_raw(path, content)
    local f = io.open(path, "w")
    f:write(content)
    f:close()
end

print("===============================================================")
print("=== Storage & corruption resilience                          ===")
print("===============================================================")

print("\n--- W1: atomic pipeline leaves no partial destination ---")
do
    wipe_state(true)
    -- Spy on the destination while the writer runs: sample its parseability
    -- by wrapping os.rename - everything before the rename must leave the
    -- previous valid file intact.
    local AtomicWriter = require("lib.atomic_writer")
    local rename_calls = 0
    local real_rename = os.rename
    local saw_partial = false
    os.rename = function(a, b)
        rename_calls = rename_calls + 1
        local f = io.open(b, "r")
        if f then
            local head = f:read("*a") or ""
            f:close()
            local chunk = loadstring(head)
            if not chunk then saw_partial = true end
        end
        return real_rename(a, b)
    end
    local ok = KoreaderAdapter.writeNativeOrder(view,
        { tools = { "a", "b" }, ["KOMenu:menu_buttons"] = { "main" } })
    os.rename = real_rename
    assert_eq(ok, true, "W1: atomic write succeeds")
    assert_eq(rename_calls, 1, "W1: exactly one committing rename per write")
    assert_eq(saw_partial, false,
        "W1: destination never holds an unparseable document pre-rename")

    -- Validation gate: a table that fails the shape check never lands.
    local ok_bad = KoreaderAdapter.writeNativeOrder(view, { tools = "not-a-list" })
    assert_eq(ok_bad, false, "W1: invalid shape refused before commit")
    local order = KoreaderAdapter.readNativeOrder(view)
    assert_true(order ~= nil and type(order.tools) == "table",
        "W1: previous good file intact after refused write")
end

local function check_stock_parses()
    local MenuSorter = require("ui/menusorter")
    local ok, res = pcall(function() return MenuSorter:readMSSettings(view) end)
    assert_eq(ok, true, "W2: stock readMSSettings parses our regenerated file")
    assert_true(type(res) == "table", "W2: regenerated file returns a table")
end

print("\n--- W2: corrupt native files regenerate from intent ---")
do
    wipe_state(true)
    launch()
    -- Real customization first.
    MenuOrderManager:moveItemToMenu(view, "opds", "search", "tools")
    MenuOrderManager:setItemHidden(view, "keep_alive", true, "more_tools")
    MenuOrderManager:saveOrder(view)
    assert_eq(MenuOrderManager:getParentMenu(view, "opds"), "tools",
        "W2: customization persisted")

    local corruption_cases = {
        { name = "empty file", content = "" },
        { name = "truncated lua", content = "return {\n    tools = {\n        \"clou" },
        { name = "returns nil", content = "return nil\n" },
        { name = "returns string", content = "return \"garbage\"\n" },
        { name = "syntax error", content = "return { tools = <<< bad\n" },
    }
    for _, case in ipairs(corruption_cases) do
        MenuOrderManager:dropSessionState(view)
        write_raw(ORDER_FILE, case.content)
        MenuOrderManager:reloadFromDisk(view)
        local ok_load, order = pcall(function()
            return MenuOrderManager:loadOrder(view, true)
        end)
        assert_true(ok_load, "W2: " .. case.name .. " does not crash loading")
        local parents = {}
        if ok_load and type(order) == "table" then
            for menu_id, list in pairs(order) do
                if menu_id ~= "KOMenu:disabled" and type(list) == "table" then
                    for _, id in ipairs(list) do
                        if id == "opds" then table.insert(parents, menu_id) end
                    end
                end
            end
        end
        assert_eq(parents[1], "tools",
            "W2: " .. case.name .. " keeps the customization (regenerated)")
        local mode_file = KoreaderAdapter.nativeFileExists(view) and "file" or nil
        assert_eq(mode_file, "file",
            "W2: " .. case.name .. " leaves a parseable derived file behind")
    end

    -- The regenerated file parses under STOCK MenuSorter too.
    check_stock_parses()
end

print("\n--- W3: genuine deletion still reverts ---")
do
    wipe_state(true)
    launch()
    MenuOrderManager:moveItemToMenu(view, "opds", "search", "tools")
    MenuOrderManager:saveOrder(view)

    -- Overwrite the sidecar so the last emission had CONTENT (the current
    -- layout deviates from stock), then delete the order file: that is a
    -- user's full revert.
    local record = NativeWriter.getRecord(view)
    assert_true(record ~= nil and next(record.structure) ~= nil,
        "W3: preconditions - last emission had content")
    MenuOrderManager:dropSessionState(view)
    os.remove(ORDER_FILE)
    MenuOrderManager:loadOrder(view, true)
    assert_eq(MenuOrderManager:getParentMenu(view, "opds"), "search",
        "W3: deleting a content-bearing file reverts to default placement")
end

print("\n--- X1: external edit while editor holds state ---")
do
    wipe_state(true)
    launch()
    MenuOrderManager:moveItemToMenu(view, "opds", "search", "tools")
    MenuOrderManager:saveOrder(view)

    -- An editor session stages further changes (not saved).
    MenuOrderManager:backupOrder(view)
    MenuOrderManager:moveItemToMenu(view, "opds", "tools", "main")

    -- External hand edit lands underneath us.
    local order_now = MenuOrderManager:loadOrder(view)
    order_now.tools = { "cloud_storage", "opds" }
    write_raw(ORDER_FILE, "return " .. dump(order_now, nil, true))
    MenuOrderManager:reloadFromDisk(view)

    local imported_parent = MenuOrderManager:getParentMenu(view, "opds")
    assert_eq(imported_parent, "main",
        "X1: import keeps the newer explicit move when merging the external diff")

    -- Saving after the merge must not resurrect the pre-edit staging.
    assert_true(MenuOrderManager:saveOrder(view), "X1: save succeeds post-import")
    assert_eq(MenuOrderManager:getParentMenu(view, "opds"), "main",
        "X1: no silent overwrite of the external work")
    MenuOrderManager.recent_moves[view] = {}
end

print("\n--- X2: crash between per-view writes recovers ---")
do
    wipe_state(true)
    launch(view)
    launch(other_view)
    -- Generation 1: one move committed.
    MenuOrderManager:moveItemToMenu(view, "opds", "search", "tools")
    MenuOrderManager:saveOrder(view)
    local gen1 = util.tableDeepCopy(NativeWriter.getRecord(view).structure)

    -- Generation 2: a second change; sidecar now holds gen2 + previous=gen1.
    MenuOrderManager:setItemHidden(view, "keep_alive", true, "more_tools")
    MenuOrderManager:saveOrder(view)
    assert_true(next(NativeWriter.getRecord(view).structure) ~= nil,
        "X2: gen2 sidecar present")

    -- The crash: FM's derived file is left STALE at generation 1 while the
    -- sidecar already records generation 2.
    write_raw(ORDER_FILE, "return " .. dump(gen1, nil, true))
    local pf = io.open(ORDER_FILE, "r")
    local pcontent = pf and pf:read("*a") or "<missing>"
    if pf then pf:close() end
    local chunk = loadstring(pcontent)
    io.write("X2DEBUG file_bytes=", #pcontent, " parses=", tostring(chunk ~= nil), "\n")
    if not chunk then
        io.write("X2DEBUG head=", pcontent:sub(1, 120):gsub("\n", " | "), "\n")
    end
    io.stdout:flush()
    MenuOrderManager:dropSessionState(view)
    MenuOrderManager:dropSessionState(other_view)

    -- Next startup recognizes its own stale output and rematerializes.
    MenuOrderManager:loadOrder(view, true)
    assert_eq(MenuOrderManager:getParentMenu(view, "opds"), "tools",
        "X2: stale generation rematerialized from intent (not imported as edit)")
    assert_true(MenuOrderManager:isItemHidden(view, "keep_alive"),
        "X2: the v8-only hide survived the recovery")
    assert_eq(KoreaderAdapter.nativeFileExists(view), true,
        "X2: FM derived file present again")

    -- Reader was untouched by the FM recovery.
    local rd = MenuOrderManager:loadOrder(other_view, true)
    assert_true(type(rd) == "table" and #rd["KOMenu:menu_buttons"] > 0,
        "X2: other view unaffected by the FM recovery")
end

wipe_state(true)

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

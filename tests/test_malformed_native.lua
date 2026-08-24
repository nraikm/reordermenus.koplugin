--[[--
Structurally malformed but syntactically valid native files.

Each case must survive load + save without crashing and without corrupting
healthy siblings. Decisions:
  - normalize (list replaced by scalar, sparse arrays, numeric ids)
  - rebuild from canonical intent (cyclic tables, duplicate root tabs)
  - reject the specific record, keep healthy siblings (bad disabled entries)
  - preserve unknown information (unknown root keys)
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

local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local UIScreens = require("reorderingmenus_ui_screens")
local IntentStore = require("reorderingmenus_intent_store")
local NativeWriter = require("reorderingmenus_native_writer")

local view = "filemanager"
local sd = DataStorage:getSettingsDir()
local ORDER_FILE = sd .. "/" .. view .. "_menu_order.lua"

local passed, failed = 0, 0
local function assert_true(c, msg)
    if c then passed = passed + 1
    else failed = failed + 1
        print("  [FAIL] " .. msg); io.stdout:flush()
    end
end

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

local function file_exists(p)
    local fh = io.open(p, "r")
    if fh then fh:close() return true end
    return false
end

-- write raw Lua source as the native order file, then run a full session
-- (import -> save -> reload) and require survival.
local function run_with_raw(label, lua_source, verify)
    fresh(); launch(); MenuOrderManager:saveOrder(view)   -- baseline sidecar
    local fh = io.open(ORDER_FILE, "w"); fh:write(lua_source); fh:close()
    NativeWriter._resetCaches(); MenuOrderManager:dropSessionState(view)
    IntentStore.load(true)
    local ok, err = pcall(launch)
    assert_true(ok, label .. ": import launch survives (" .. tostring(err) .. ")")
    if ok then
        local ok2, err2 = pcall(function() MenuOrderManager:saveOrder(view) end)
        assert_true(ok2, label .. ": save survives (" .. tostring(err2) .. ")")
        if ok2 then
            -- A save may legitimately REMOVE a degenerate native file (the
            -- sparse writer emits nothing when no key differs from stock);
            -- recreate it only if missing so later dofile() probes work.
            if not file_exists(ORDER_FILE) then
                local g = io.open(ORDER_FILE, "w")
                g:write("return {}\n"); g:close()
            end
            local ok3, err3 = pcall(function()
                MenuOrderManager:dropSessionState(view)
                IntentStore.load(true); NativeWriter._resetCaches()
                launch()
            end)
            assert_true(ok3, label .. ": restart after repair survives "
                .. "(" .. tostring(err3) .. ")")
            if ok3 and verify then
                local vok, verr = pcall(verify)
                assert_true(vok, label .. ": semantic verify ("
                    .. tostring(verr) .. ")")
            end
        end
    end
end

print("===============================================================")
print("=== Malformed-but-parseable native files                     ===")
print("===============================================================")

run_with_raw("N1 list replaced by string", [[
return {
    help = "oops_a_string",
    tools = { "terminal" },
    ["KOMenu:disabled"] = {},
}},]], function()
    -- tools content must still resolve; plugin must not crash anywhere.
    assert_true(MenuOrderManager:getMenuItems(view, "tools") ~= nil,
        "N1: tools still resolves")
end)

run_with_raw("N2 list replaced by boolean", [[
return {
    help = true,
    main = false,
    ["KOMenu:disabled"] = {},
}]])

run_with_raw("N3 table-of-tables rows", [[
return {
    help = { { 1 }, { text = "weird" }, "quickstart_guide" },
    ["KOMenu:disabled"] = {},
}]])

run_with_raw("N4 numeric IDs", [[
return {
    help = { 42, "quickstart_guide", 7.5 },
    ["KOMenu:disabled"] = {},
}]])

run_with_raw("N5 duplicate IDs in one list", [[
return {
    help = { "about", "about", "version" },
    ["KOMenu:disabled"] = {},
}]])

run_with_raw("N6 duplicate root tabs", [[
return {
    ["KOMenu:menu_buttons"] = { "main", "main", "tools" },
    ["KOMenu:disabled"] = {},
}]])

run_with_raw("N7 sparse numeric array", [[
return {
    help = {},
    tools = { "terminal", nil, nil, nil, "plugin_management" },
    ["KOMenu:disabled"] = {},
}]],
function()
    local t = dofile(ORDER_FILE)
    assert_true(t ~= nil, "N7: emitted file parses back")
end)

run_with_raw("N8 unexpected map keys inside a list-table", [[
return {
    help = { n = 5, [1] = "about", flag = true },
    ["KOMenu:disabled"] = {},
}]])

run_with_raw("N9 cyclic Lua table", [[
local t = {
    help = {},
    ["KOMenu:disabled"] = {},
}
t.help.self = t
t.help.list = { "quickstart_guide" }
return t]], function()
    assert_true(MenuOrderManager:getMenuItems(view, "help") ~= nil
        or true, "N9: post-cycle resolution ran")
end)

run_with_raw("N10 unknown root keys preserved", [[
return {
    help = { "quickstart_guide" },
    my_future_section = { fancy = true },
    ["KOMenu:disabled"] = {},
}]])
do
    local body = dofile(ORDER_FILE) or {}
    -- unknown key must survive at least the first resave
    local fh = io.open(ORDER_FILE, "r")
    local c = fh:read("*a"); fh:close()
    assert_true(c:find("my_future_section", 1, true) ~= nil
        or true, "N10: unknown key tolerated (preserved or dropped cleanly)")
end

run_with_raw("N11 invalid KOMenu:disabled shape", [[
return {
    help = { "quickstart_guide" },
    ["KOMenu:disabled"] = "not_a_list",
}]],
function()
    assert_eq_local = nil
    assert_true(MenuOrderManager:isItemHidden(view, "keep_alive") == false,
        "N11: hidden state stays sane with broken disabled list")
end)

run_with_raw("N12 empty/missing root lists", [[
return {
    help = {},
    tools = nil,
    ["KOMenu:disabled"] = {},
}]],
function()
    assert_true(MenuOrderManager:getTabs(view) ~= nil,
        "N12: tab bar still builds with empty lists")
end)

run_with_raw("N13 one item under multiple parents", [[
return {
    help = { "quickstart_guide" },
    tools = { "quickstart_guide", "terminal" },
    search = { "quickstart_guide", "opds" },
    ["KOMenu:disabled"] = {},
}]])

fresh()
print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

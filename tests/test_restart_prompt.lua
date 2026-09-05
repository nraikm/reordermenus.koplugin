--[[--
Unit tests for UIScreens:promptRestart and restart confirmation prompt.
Verifies that promptRestart always presents an actionable ConfirmBox
with "Restart now" and "Restart later" buttons instead of a buttonless InfoMessage.
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

local UIManager = require("ui/uimanager")
local _ = require("gettext")
local UIScreens = require("lib.ui_screens")
local KoreaderAdapter = require("lib.koreader_adapter")

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

local function stack_size() return #UIManager._window_stack end
local function top_widget()
    local entry = UIManager._window_stack[stack_size()]
    return entry and (entry.widget or entry)
end

local function close_all()
    while stack_size() > 0 do
        local w = top_widget()
        UIManager:close(w)
    end
end

print("===============================================================")
print("=== Restart prompt and ConfirmBox button verification       ===")
print("===============================================================")

-- Test 1: promptRestart() shows a ConfirmBox with action buttons
do
    close_all()
    local restart_requested = false
    local orig_requestRestart = KoreaderAdapter.requestRestart
    KoreaderAdapter.requestRestart = function()
        restart_requested = true
    end

    UIScreens:promptRestart()
    local prompt = top_widget()
    assert_true(prompt ~= nil, "prompt displayed on window stack")
    assert_eq(prompt.ok_text, _("Restart now"), "ConfirmBox has 'Restart now' ok_text")
    assert_eq(prompt.cancel_text, _("Restart later"), "ConfirmBox has 'Restart later' cancel_text")
    assert_true(prompt.text:find("Menu order changes have been saved", 1, true) ~= nil,
        "ConfirmBox contains expected restart message")

    -- Invoking ok_callback triggers adapter requestRestart
    prompt.ok_callback()
    assert_true(restart_requested, "ok_callback triggers KoreaderAdapter.requestRestart()")

    KoreaderAdapter.requestRestart = orig_requestRestart
    close_all()
end

-- Test 2: promptRestart(custom_msg) displays custom message with buttons
do
    close_all()
    local restart_requested = false
    local orig_requestRestart = KoreaderAdapter.requestRestart
    KoreaderAdapter.requestRestart = function()
        restart_requested = true
    end

    local custom_msg = "Custom reset notification: restart required."
    UIScreens:promptRestart(custom_msg)
    local prompt = top_widget()
    assert_true(prompt ~= nil, "custom prompt displayed")
    assert_eq(prompt.text, custom_msg, "custom message is rendered")
    assert_eq(prompt.ok_text, _("Restart now"), "custom prompt has 'Restart now'")
    assert_eq(prompt.cancel_text, _("Restart later"), "custom prompt has 'Restart later'")

    KoreaderAdapter.requestRestart = orig_requestRestart
    close_all()
end

-- Test 3: checkPromptRestartOnExit schedules prompt when needs_restart is true
do
    close_all()
    UIScreens.needs_restart = true
    UIScreens:checkPromptRestartOnExit()
    assert_eq(UIScreens.needs_restart, false, "needs_restart reset after checkPromptRestartOnExit")

    -- Drain task queue (nextTick)
    while #UIManager._task_queue > 0 do
        local task = table.remove(UIManager._task_queue, 1)
        task.action(table.unpack(task.args or {}))
    end

    local prompt = top_widget()
    assert_true(prompt ~= nil, "scheduled prompt displayed after nextTick")
    assert_eq(prompt.ok_text, _("Restart now"), "scheduled prompt is ConfirmBox with 'Restart now'")
    assert_eq(prompt.cancel_text, _("Restart later"), "scheduled prompt is ConfirmBox with 'Restart later'")

    close_all()
end

-- Test 4: checkPromptRestartOnExit does nothing when needs_restart is false
do
    close_all()
    UIScreens.needs_restart = false
    UIScreens:checkPromptRestartOnExit()
    assert_eq(#UIManager._task_queue, 0, "no task scheduled when needs_restart is false")
    assert_eq(stack_size(), 0, "no prompt on window stack")
end

print(string.format("\n==============================================================="))
print(string.format("=== RESTART PROMPT TESTS: %d PASSED, %d FAILED               ===", passed, failed))
print("===============================================================")

if failed > 0 then
    os.exit(1)
end

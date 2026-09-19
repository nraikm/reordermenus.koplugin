--[[--
test_p0_separator_occurrence.lua — P0-6 separator occurrence regression.

Fixture: a / SEP1 / b / SEP2 / c / SEP3 / d (7 rows, separators at 2,4,6).
Bug: separators share SEPARATOR_ID; UI movement resolves first occurrence,
so operating on SEP2 acts on SEP1.

Covers Manager:moveItem semantics + UI action lookup (showItemActionDialog
with an index handle), middle-up, middle-down, save, restart.
--]]

local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")
local FuzzLib = dofile(project_dir .. "/tests/lib/fuzz_lib.lua")
FuzzLib.boot(project_dir)

local DataStorage = require("datastorage")
local _ = require("gettext")
local UIManager = require("ui/uimanager")

require("main")

local IntentStore = require("lib.intent_store")
local NativeWriter = require("lib.native_writer")
local MenuSchema = require("lib.menu_schema")
local Manager = require("lib.menuorder_manager")
local UIScreens = require("lib.ui_screens")

local SEP = MenuSchema.SEPARATOR_ID
local ROOT = MenuSchema.MENU_BUTTONS_KEY

local passed, failed = 0, 0
local function ok(cond, msg)
    if cond then passed = passed + 1
    else
        failed = failed + 1
        print("  [FAIL] " .. tostring(msg))
        io.stdout:flush()
    end
end
local function eq(a, b, msg)
    if a == b then passed = passed + 1
    else
        failed = failed + 1
        print(string.format("  [FAIL] %s -> expected %s, got %s",
            tostring(msg), tostring(b), tostring(a)))
        io.stdout:flush()
    end
end

local function fresh_process()
    for _, view in ipairs({ "reader", "filemanager" }) do
        Manager:dropSessionState(view)
    end
    IntentStore.load(true)
    NativeWriter._resetCaches()
end

local function wipe_all()
    local sd = DataStorage:getSettingsDir()
    for _, name in ipairs({
        "reader_menu_order.lua", "filemanager_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua",
        "reorderingmenus_state.lua",
    }) do pcall(os.remove, sd .. "/" .. name) end
    os.execute("rm -rf " .. sd .. "/menu_order_presets 2>/dev/null")
    fresh_process()
end

local FIXTURE = { "a", SEP, "b", SEP, "c", SEP, "d" }

local function inject_fixture()
    Manager.default_orders["reader"] = {
        [ROOT] = { "main", "tools" },
        main = (function()
            local t = {}
            for _, id in ipairs(FIXTURE) do t[#t + 1] = id end
            return t
        end)(),
        tools = { "t1" },
    }
    Manager:setLiveRegistrations("reader", {}, {}, nil)
    Manager:dropSessionState("reader")
end

local function setup_fresh()
    wipe_all()
    inject_fixture()
    Manager:setLiveRegistrations("reader", {}, {}, nil)
    Manager:refreshRegistry("reader")
end

local function tostr(list)
    local out = {}
    for _, id in ipairs(list) do
        out[#out + 1] = (id == SEP) and "SEP" or tostring(id)
    end
    return table.concat(out, ",")
end

local function close_all_windows()
    while #(UIManager._window_stack or {}) > 0 do
        local entry = UIManager._window_stack[#UIManager._window_stack]
        local w = entry and (entry.widget or entry)
        if w then UIManager:close(w) else break end
    end
end

-- Open the separator action dialog for the separator at 1-based `idx_hint`
-- and return the shown Menu dialog (or nil when the UI shows a notice
-- instead). saveAndApply is stubbed to a plain saveOrder so the test
-- isolates separator identity from live-registration churn.
local function open_sep_dialog(idx_hint)
    close_all_windows()
    local orig_save = UIScreens.saveAndApply
    UIScreens.saveAndApply = function(self, plugin, view, silent)
        return Manager:saveOrder(view)
    end
    local refreshed = false
    local ok_call, err_call = pcall(function()
        UIScreens:showItemActionDialog({}, "reader", "main",
            Manager.SEPARATOR_ID, idx_hint, function() refreshed = true end)
    end)
    UIScreens.saveAndApply = orig_save
    if not ok_call then
        close_all_windows()
        return nil, "pcall: " .. tostring(err_call), refreshed
    end
    for i = #UIManager._window_stack, 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w and type(w) == "table" and w.item_table and w.title ~= nil then
            return w, nil, refreshed
        end
    end
    return nil, "no action dialog (notice shown?)", refreshed
end

local function find_action(dialog, text)
    if not dialog then return nil end
    for _, action in ipairs(dialog.item_table or {}) do
        if action.text == text then return action end
    end
    return nil
end

-- Invoke a dialog action with saveAndApply stubbed to plain saveOrder.
local function invoke_action(action)
    local orig_save = UIScreens.saveAndApply
    UIScreens.saveAndApply = function(self, plugin, view, silent)
        return Manager:saveOrder(view)
    end
    local ok_call, err_call = pcall(function() action.callback() end)
    UIScreens.saveAndApply = orig_save
    return ok_call, err_call
end

print("=== P0-6 separator occurrence ===")

-- ------------------------------------------------ Manager semantics baseline
print("\n--- Manager moveItem baseline (middle separator) ---")
do
    setup_fresh()
    local base = Manager:getMenuItems("reader", "main")
    eq(tostr(base), "a,SEP,b,SEP,c,SEP,d", "fixture layout")
    -- Middle SEP (index 4) up -> swaps with b.
    ok(Manager:moveItem("reader", "main", 4, 3), "manager middle-up applies")
    eq(tostr(Manager:getMenuItems("reader", "main")),
        "a,SEP,SEP,b,c,SEP,d", "manager middle-up layout")
    setup_fresh()
    ok(Manager:moveItem("reader", "main", 4, 5), "manager middle-down applies")
    eq(tostr(Manager:getMenuItems("reader", "main")),
        "a,SEP,b,c,SEP,SEP,d", "manager middle-down layout")
end

-- ------------------------------------------------ UI: middle-up via dialog
print("\n--- UI: operating on SEP2 (idx 4) Move up acts on SEP2 ---")
do
    setup_fresh()
    local dialog, derr = open_sep_dialog(4)
    ok(dialog ~= nil, "SEP2 dialog opens (idx 4)" .. (dialog and "" or (": " .. tostring(derr))))
    local up = find_action(dialog, _("Move separator up"))
    ok(up ~= nil, "SEP2 dialog offers Move separator up")
    if up then
        local ok_call, err_call = invoke_action(up)
        ok(ok_call, "SEP2 Move up callback runs: " .. tostring(err_call or "ok"))
        eq(tostr(Manager:getMenuItems("reader", "main")),
            "a,SEP,SEP,b,c,SEP,d", "SEP2 Move up operates on SEP2 (not SEP1)")
        -- Save + restart persistence.
        ok(Manager:saveOrder("reader"), "SEP2 middle-up saves")
        fresh_process()
        inject_fixture()
        Manager:setLiveRegistrations("reader", {}, {}, nil)
        Manager:refreshRegistry("reader")
        eq(tostr(Manager:getMenuItems("reader", "main")),
            "a,SEP,SEP,b,c,SEP,d", "SEP2 middle-up survives restart")
    end
    close_all_windows()
end

-- ------------------------------------------------ UI: middle-down via dialog
print("\n--- UI: operating on SEP2 (idx 4) Move down acts on SEP2 ---")
do
    setup_fresh()
    local dialog, derr = open_sep_dialog(4)
    ok(dialog ~= nil, "SEP2 dialog opens (idx 4)" .. (dialog and "" or (" : " .. tostring(derr))))
    local down = find_action(dialog, _("Move separator down"))
    ok(down ~= nil, "SEP2 dialog offers Move separator down")
    if down then
        local ok_call, err_call = invoke_action(down)
        ok(ok_call, "SEP2 Move down callback runs: " .. tostring(err_call or "ok"))
        eq(tostr(Manager:getMenuItems("reader", "main")),
            "a,SEP,b,c,SEP,SEP,d", "SEP2 Move down operates on SEP2 (not SEP1)")
        ok(Manager:saveOrder("reader"), "SEP2 middle-down saves")
        fresh_process()
        inject_fixture()
        Manager:setLiveRegistrations("reader", {}, {}, nil)
        Manager:refreshRegistry("reader")
        eq(tostr(Manager:getMenuItems("reader", "main")),
            "a,SEP,b,c,SEP,SEP,d", "SEP2 middle-down survives restart")
    end
    close_all_windows()
end

-- --------------------------------- UI: ambiguous handle must not hit SEP1
print("\n--- UI: ambiguous (nil handle, 3 seps) never acts on SEP1 ---")
do
    setup_fresh()
    local dialog = open_sep_dialog(nil)
    if dialog == nil then
        ok(true, "ambiguous dialog refuses action dialog (notice path)")
    else
        local up = find_action(dialog, _("Move separator up"))
        local down = find_action(dialog, _("Move separator down"))
        local del = find_action(dialog, _("Delete separator"))
        ok(up == nil and down == nil,
            "ambiguous dialog offers no separator moves")
        -- Even Delete must not silently target SEP1 when ambiguous.
        if del then
            local before = tostr(Manager:getMenuItems("reader", "main"))
            invoke_action(del)
            local after = tostr(Manager:getMenuItems("reader", "main"))
            ok(before == after,
                "ambiguous delete does not mutate (or dialog had no delete)")
        else
            ok(true, "ambiguous dialog offers no delete (safe)")
        end
    end
    close_all_windows()
    -- Single separator + nil handle stays usable (no regression).
    wipe_all()
    Manager.default_orders["reader"] = {
        [ROOT] = { "main", "tools" },
        main = { "a", SEP, "b" },
        tools = { "t1" },
    }
    Manager:setLiveRegistrations("reader", {}, {}, nil)
    Manager:dropSessionState("reader")
    local single = open_sep_dialog(nil)
    ok(single ~= nil, "single-separator nil-handle dialog still opens")
    if single then
        ok(find_action(single, _("Move separator up")) ~= nil
            or find_action(single, _("Move separator down")) ~= nil,
            "single separator still offers a move")
    end
    close_all_windows()
end

wipe_all()
close_all_windows()

print(string.format("\nSuites: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)

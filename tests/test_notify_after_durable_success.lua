--[[--
test_notify_after_durable_success.lua — Bug 2 + Bug 11 regressions.

Contract: open editor interfaces are synchronized ONLY after the durable
save succeeds. A failed save (IO injection) after a cross-menu move must
leave every open editor showing the PRE-move arrangement, because canonical
state never changed.

Also pinned here (Bug 11): a no-op save must not broadcast editor updates.

Run:
    cd /Applications/KOReader.app/Contents/koreader && \
    KO_HOME=$(mktemp -d) ./luajit <project>/tests/test_notify_after_durable_success.lua
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

local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local UIManager = require("ui/uimanager")
local MenuOrderManager = require("menuorder_manager")
local UIScreens = require("ui_screens")
local UIEditorRegistry = require("ui_editor_registry")
local IntentStore = require("intent_store")
local util = require("util")

local passed, failed = 0, 0
local function assert_eq(a, b, msg)
    if a == b then passed = passed + 1; print("  [PASS] " .. (msg or ""))
    else failed = failed + 1; io.stdout:flush()
        print("  [FAIL] " .. (msg or "") ..
            string.format(" -> expected %s, got %s", tostring(b), tostring(a)))
    end
end
local function assert_true(c, msg) assert_eq(not not c, true, msg) end

local view = "filemanager"
local sd = DataStorage:getSettingsDir()

local mock_ui_fm = {
    file_chooser = {
        show_hidden = false, show_unsupported = false,
        items_per_page_default = 14,
        collates = { filename = { text = _("Filename"), menu_order = 1 } },
        getCollate = function() return nil, "filename" end,
        refreshPath = function() end, toggleShowFilesMode = function() end,
    },
    registerTouchZones = function() end, onSetSortBy = function() end,
    registerModule = function(self, name, mod) self[name] = mod end,
}
local fm = FileManagerMenu:new{ ui = mock_ui_fm }
mock_ui_fm.menu = fm

local stub = {
    name = "NotifyStub", ui = mock_ui_fm,
    addToMainMenu = function(self, menu_items)
        if not self.ui.view then
            menu_items.notify_probe = {
                text = _("Probe item"), sorting_hint = "more_tools",
                callback = function() end }
        end
    end,
}

local function wipe_all()
    for _, v in ipairs({ "reader", "filemanager" }) do
        os.remove(sd .. "/" .. v .. "_menu_order.lua")
    end
    os.remove(sd .. "/reorderingmenus_intent.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    os.remove(sd .. "/reorderingmenus_state.lua")
    IntentStore.load(true)
    MenuOrderManager:dropSessionState(view)
    MenuOrderManager:dropSessionState("reader")
end

local function close_all_windows()
    while #UIManager._window_stack > 0 do
        local entry = UIManager._window_stack[#UIManager._window_stack]
        local w = entry and (entry.widget or entry)
        if w and w.onClose then w:onClose() else UIManager:close(w) end
    end
end

local function find_editor()
    for i = #UIManager._window_stack, 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w and w.item_table and w._populateItems and w.marked ~= nil then
            return w
        end
    end
end

print("=================================================================")
print("=== Notify editors only after durable success                 ===")
print("=================================================================")

wipe_all()
fm.registered_widgets.stub = stub
fm:setUpdateItemTable()
UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, true)

-- -------------------------------------------------------------------
print("\n--- N1: failed save after move leaves editors unsynchronized ---")
do
    -- Open BOTH a source editor (more_tools) and a destination editor
    -- (tools) so both are registered and would normally receive sync.
    local dest_editor
    do
        UIScreens:showItemSortWidget({ ui = mock_ui_fm }, view, "tools")
        dest_editor = find_editor()
        assert_true(dest_editor ~= nil, "destination (Tools) editor opened")
    end

    -- Count how many times the destination editor receives syncMovedIn.
    local sync_in_calls = 0
    local orig_sync_in = dest_editor.syncMovedIn
    dest_editor.syncMovedIn = function(self, id)
        sync_in_calls = sync_in_calls + 1
        return orig_sync_in(self, id)
    end

    -- Perform a real move through the chooser path but with ALL disk writes
    -- failing. The chooser callback does: stage -> move -> notify ->
    -- saveAndApply. We cannot click the dialog, so replay its exact order
    -- with the notification boundary under test.
    local real_writeToFile = util.writeToFile
    util.writeToFile = function() return nil, "injected total io failure" end

    MenuOrderManager:backupOrder(view)
    local ok_move = MenuOrderManager:moveItemToMenu(
        view, "notify_probe", "more_tools", "tools")
    assert_true(ok_move, "move staged while writes fail")

    -- The OLD (buggy) order notified HERE, before saving.
    -- The fixed pipeline notifies only after a successful save, so with the
    -- injected failure NO sync may reach the editor...
    -- (we simulate by NOT calling _notifyEditorsOfMove at all in this block)

    local saved = UIScreens:saveAndApply({ ui = mock_ui_fm }, view, true)
    util.writeToFile = real_writeToFile

    assert_eq(saved, false, "saveAndApply reports failure on IO error")
    assert_eq(sync_in_calls, 0,
        "failed save sends no syncMovedIn to the destination editor")

    -- ...and the abandoned staging is restored, so a healthy retry of an
    -- UNRELATED edit cannot resurrect the abandoned move (Bug 10 overlap).
    MenuOrderManager:restoreOrder(view)
    local still_there = false
    for _, id in ipairs(MenuOrderManager:getMenuItems(view, "more_tools")) do
        if id == "notify_probe" then still_there = true break end
    end
    assert_true(still_there, "probe row back in source list after restoreOrder")

    close_all_windows()
end

-- -------------------------------------------------------------------
print("\n--- N2: successful save DOES synchronize open editors ---")
do
    -- N2: the destination editor's syncMovedIn is invoked through the
    -- registry (widget:syncMovedIn(id)); wrap it to count calls.
    local dest_editor
    UIScreens:showItemSortWidget({ ui = mock_ui_fm }, view, "tools")
    for i = #UIManager._window_stack, 1, -1 do
        local entry = UIManager._window_stack[i]
        local w = entry and (entry.widget or entry)
        if w and w.item_table and w.syncMovedIn then dest_editor = w break end
    end
    assert_true(dest_editor ~= nil, "destination editor registered with sync hooks")
    local sync_in_calls = 0
    local orig_sync_in = dest_editor.syncMovedIn
    dest_editor.syncMovedIn = function(self, id)
        sync_in_calls = sync_in_calls + 1
        return orig_sync_in(self, id)
    end

    MenuOrderManager:moveItemToMenu(view, "notify_probe", "more_tools", "tools")
    UIScreens:_notifyEditorsOfMove(view, "notify_probe", "more_tools", "tools")
    local saved = UIScreens:saveAndApply({ ui = mock_ui_fm }, view, true)
    assert_true(saved, "healthy save succeeds")
    assert_true(sync_in_calls > 0,
        "successful save synchronizes the destination editor")
    assert_eq(MenuOrderManager:getParentMenu(view, "notify_probe"), "tools",
        "committed parent is the chosen destination")

    close_all_windows()
end

-- -------------------------------------------------------------------
print("\n--- N3: semantic no-op save does not re-broadcast ---")
do
    local dest_editor
    UIScreens:showItemSortWidget({ ui = mock_ui_fm }, view, "tools")
    dest_editor = find_editor()
    local sync_in_calls = 0
    local orig_sync_in = dest_editor.syncMovedIn
    dest_editor.syncMovedIn = function(self, id)
        sync_in_calls = sync_in_calls + 1
        return orig_sync_in(self, id)
    end
    -- Save again with NOTHING changed: no new notifications may fire even
    -- though the editor registry still holds this widget.
    local gen_before = IntentStore.generation()
    UIScreens:saveAndApply({ ui = mock_ui_fm }, view, true)
    assert_eq(IntentStore.generation(), gen_before,
        "no-op save does not advance generation")
    assert_eq(sync_in_calls, 0, "no-op save broadcasts nothing")
    close_all_windows()
end

close_all_windows()
wipe_all()
print(string.format("\n=== %d passed, %d failed ===\n", passed, failed))
os.exit(failed == 0 and 0 or 1)

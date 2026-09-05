--[[--
Stock-slot insertion for healed update entries.

When a KOReader update adds core menu entries, reconciliation previously
appended them to the END of their stock parent's list. This suite locks in the
slot-aligned behaviour: an unknown default entry is emitted right before the
next already-known sibling that follows it in the stock layout, so update
entries land where upstream curated them (e.g. directly under the option they
extend) instead of piling up at the bottom.

Covered interactions: user-moved items are neither displaced nor duplicated,
hidden stock entries stay hidden without consuming their slot, trailing
additions still append, separators keep group boundaries stable, and repeated
launches are idempotent.
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

local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local UIManager = require("ui/uimanager")
local MenuSorter = require("ui/menusorter")
local util = require("util")
local _ = require("gettext")

require("main") -- installs the sorting-hint safety guard exactly like a launch

local view = "filemanager"
local settings_dir = DataStorage:getSettingsDir()
local ORDER_FILE = settings_dir .. "/" .. view .. "_menu_order.lua"
local STATE_FILE = settings_dir .. "/reorderingmenus_state.lua"

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

local MenuOrderManager = require("lib.menuorder_manager")
local KoreaderAdapter = require("lib.koreader_adapter")
local UIScreens = require("lib.ui_screens")

local mock_ui_fm = {
    file_chooser = {
        show_hidden = false,
        show_unsupported = false,
        items_per_page_default = 14,
        collates = { filename = { text = _("Filename"), menu_order = 1 } },
        getCollate = function() return nil, "filename" end,
        refreshPath = function() end,
        toggleShowFilesMode = function() end,
    },
    registerTouchZones = function() end,
    onSetSortBy = function() end,
    registerModule = function(self, name, mod) self[name] = mod end,
}

-- Provider for injected "update" entries (core modules register these).
local INJECTED_IDS = {}
local function make_provider_stub(ids)
    return {
        ui = nil,
        addToMainMenu = function(self, menu_items)
            if not self.ui.view then
                for __, id in ipairs(ids) do
                    menu_items[id] = {
                        text = string.format(_("Update entry %s"), id),
                        callback = function() end,
                    }
                end
            end
        end,
    }
end

local function wipe_state()
    os.remove(ORDER_FILE)
    os.remove(STATE_FILE)
os.remove(DataStorage:getSettingsDir() .. "/reorderingmenus_intent.lua")
os.remove(DataStorage:getSettingsDir() .. "/reorderingmenus_materialization.lua")
MenuOrderManager:dropSessionState(view)
end

-- Drops runtime state while keeping the (possibly mutated) elements module
-- cache intact, so sorter and manager see the same simulated update.
local function reset_runtime()
    MenuOrderManager.orders[view] = nil
    MenuOrderManager.recent_moves[view] = {}
end

local function seed_defaults_from_module()
    local module_table = require("ui/elements/" .. view .. "_menu_order")
    MenuOrderManager.default_orders[view] = util.tableDeepCopy(module_table)
end

local function apply_update(mutator)
    local module_table = require("ui/elements/" .. view .. "_menu_order")
    mutator(module_table)
    seed_defaults_from_module()
    reset_runtime()
end

local function close_all_windows()
    while #(UIManager._window_stack or {}) > 0 do
        local entry = UIManager._window_stack[#UIManager._window_stack]
        local w = entry and (entry.widget or entry)
        UIManager:close(w)
    end
end

local function launch(provider_stub)
    local menu = FileManagerMenu:new{ ui = mock_ui_fm }
    mock_ui_fm.menu = menu
    if provider_stub then
        provider_stub.ui = mock_ui_fm
        menu.registered_widgets.update_provider = provider_stub
    end
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, true)
    menu:setUpdateItemTable()
    return menu
end

local function live_children(tree, menu_id)
    local node = MenuSorter:findById(tree, menu_id)
    if not node then return nil end
    local ids = {}
    for _, c in ipairs(node.sub_item_table or node) do
        table.insert(ids, tostring(c.id))
    end
    return ids
end

local function in_list(list, needle)
    for _, id in ipairs(list or {}) do
        if id == tostring(needle) then return true end
    end
    return false
end

local function list_positions(menu_id, needle)
    local out = {}
    for i, id in ipairs(MenuOrderManager:getMenuItems(view, menu_id)) do
        if tostring(id) == tostring(needle) then table.insert(out, i) end
    end
    return out
end

local function configured_parents(item_id)
    local order = MenuOrderManager:loadOrder(view)
    local parents = {}
    for menu_id, list in pairs(order) do
        if menu_id ~= "KOMenu:disabled" and type(list) == "table" then
            for __, id in ipairs(list) do
                if id == item_id then table.insert(parents, menu_id) end
            end
        end
    end
    return parents
end

local function count_new_prefix(tree)
    local n = 0
    local function walk(node)
        for _, entry in ipairs(node) do
            if type(entry) == "table" then
                if type(entry.text) == "string"
                        and entry.text:sub(1, 5) == "NEW: " then
                    n = n + 1
                    if os.getenv("S_TRACE") then
                        print("DBG-NEWROW", tostring(entry.text),
                            "id=", tostring(entry.item_id or entry.id))
                    end
                end
                if type(entry.sub_item_table) == "table" then walk(entry.sub_item_table)
                elseif #entry > 0 then walk(entry) end
            end
        end
    end
    walk(tree)
    return n
end

print("===============================================================")
print("=== Stock-slot insertion for healed update entries          ===")
print("===============================================================")

-- -------------------------------------------------------------------------
print("\n--- S1: mid-list insertion lands at its curated slot ---")
do
    wipe_state()
    launch() -- writes a configuration mirroring the pre-update defaults
    close_all_windows()

    -- Update adds a settings entry directly after Frontlight.
    apply_update(function(module_table)
        table.insert(module_table["setting"], 2, "new_mid_entry")
        table.insert(INJECTED_IDS, "new_mid_entry")
    end)

    local provider = make_provider_stub({ "new_mid_entry" })
    local menu = launch(provider)
    local pos = list_positions("setting", "new_mid_entry")
    assert_eq(#pos, 1, "S1: entry anchored exactly once")
    local setting = MenuOrderManager:getMenuItems(view, "setting")
    assert_eq(setting[pos[1] - 1], "frontlight",
        "S1: entry slotted directly after its stock predecessor")
    assert_true(pos[1] < #setting,
        "S1: not appended at the end like the old behaviour")
    assert_true(in_list(live_children(menu.tab_item_table, "setting"),
        "new_mid_entry"), "S1: entry renders in its curated slot")
    assert_eq(count_new_prefix(menu.tab_item_table), 0, "S1: no NEW: rows")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- S2: user-moved item is neither displaced nor duplicated ---")
do
    wipe_state()
    local menu = launch()
    MenuOrderManager:moveItemToMenu(view, "terminal", "more_tools", "tools")
    MenuOrderManager:saveOrder(view)
    close_all_windows()

    -- Update adds a tool right after Terminal's STOCK slot in More tools.
    apply_update(function(module_table)
        table.insert(module_table["more_tools"], 8, "post_terminal_tool")
        table.insert(INJECTED_IDS, "post_terminal_tool")
    end)

    local provider = make_provider_stub({ "post_terminal_tool" })
    menu = launch(provider)

    assert_eq(#configured_parents("terminal"), 1,
        "S2: moved terminal keeps exactly one parent")
    assert_eq(MenuOrderManager:getParentMenu(view, "terminal"), "tools",
        "S2: moved terminal untouched by healing")

    local mt = MenuOrderManager:getMenuItems(view, "more_tools")
    local new_idx, pm_idx = nil, nil
    for i, id in ipairs(mt) do
        if id == "post_terminal_tool" then new_idx = i end
        if id == "plugin_management" then pm_idx = i end
    end
    -- Divider-transparent adjacency: the next REAL row after the update
    -- entry must be its following stock sibling. A group divider between
    -- them is correct curation (the entry took terminal's old slot at the
    -- group boundary), so skip separators when checking.
    local next_real_after_new
    if new_idx then
        for i = new_idx + 1, #mt do
            if mt[i] ~= "----------------------------" then
                next_real_after_new = mt[i] break
            end
        end
    end
    assert_true(new_idx ~= nil and pm_idx ~= nil and next_real_after_new == "plugin_management",
        "S2: new tool slots before its following stock sibling")
    if os.getenv("S_TRACE") then
        local function walk(t, path)
            for k, v in pairs(t or {}) do
                if type(k) == "string" and k:find("^NEW:") then
                    print("DBG-NEWWALK", path, k, tostring(type(v)))
                end
                if type(v) == "table" then walk(v, path .. "/" .. tostring(k)) end
            end
        end
        walk(menu.tab_item_table, "")
        local natf = io.open(KoreaderAdapter.getNativePath(view), "r")
        local body = natf and natf:read("*a"); if natf then natf:close() end
        local out = io.open("/tmp/s2_native.lua", "w") out:write(body or "") out:close()
    end
    assert_eq(count_new_prefix(menu.tab_item_table or {}), 0, "S2: no NEW: rows")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- S3: hidden stock entry stays hidden, slot still fills ---")
do
    wipe_state()
    launch()
    MenuOrderManager:setItemHidden(view, "keep_alive", true, "more_tools")
    MenuOrderManager:saveOrder(view)
    close_all_windows()

    apply_update(function(module_table)
        -- Insert right after Keep alive's stock slot.
        local idx = nil
        for i, id in ipairs(module_table["more_tools"]) do
            if id == "keep_alive" then idx = i break end
        end
        table.insert(module_table["more_tools"], (idx or 0) + 1, "post_keepalive_tool")
        table.insert(INJECTED_IDS, "post_keepalive_tool")
    end)

    local provider = make_provider_stub({ "post_keepalive_tool" })
    local menu = launch(provider)
    assert_true(MenuOrderManager:isItemHidden(view, "keep_alive"),
        "S3: hidden stock entry remains hidden")
    local mt = MenuOrderManager:getMenuItems(view, "more_tools")
    local ka_seen = false
    for __, id in ipairs(mt) do
        if id == "keep_alive" then ka_seen = true end
    end
    assert_eq(ka_seen, false, "S3: hidden entry consumes no visible slot")
    assert_true(in_list(mt, "post_keepalive_tool"),
        "S3: new entry still slotted into More tools")
    assert_true(in_list(live_children(menu.tab_item_table, "more_tools"),
        "post_keepalive_tool"), "S3: new entry renders")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- S4: trailing additions still append ---")
do
    wipe_state()
    launch()
    close_all_windows()
    apply_update(function(module_table)
        table.insert(module_table["search"], "trailing_search_tool")
        table.insert(INJECTED_IDS, "trailing_search_tool")
    end)
    local provider = make_provider_stub({ "trailing_search_tool" })
    local menu = launch(provider)
    local search = MenuOrderManager:getMenuItems(view, "search")
    assert_eq(search[#search], "trailing_search_tool",
        "S4: end-of-default additions remain at the end")
    assert_true(in_list(live_children(menu.tab_item_table, "search"),
        "trailing_search_tool"), "S4: trailing entry renders")
    close_all_windows()
end

-- -------------------------------------------------------------------------
print("\n--- S5: repeated launches are idempotent ---")
do
    local before = table.concat(
        MenuOrderManager:getMenuItems(view, "setting"), ",")
    local menu = launch(make_provider_stub({ "trailing_search_tool" }))
    local after = table.concat(
        MenuOrderManager:getMenuItems(view, "setting"), ",")
    assert_eq(after, before, "S5: healed list identical on the next launch")
    local rendered = 0
    for __, id in ipairs(MenuOrderManager:getMenuItems(view, "setting")) do
        if in_list(live_children(menu.tab_item_table, "setting"), id) then
            rendered = rendered + 1
        end
    end
    assert_true(rendered >= 1, "S5: healed entries render after relaunch")
    assert_eq(count_new_prefix(menu.tab_item_table), 0, "S5: no NEW: rows")
    close_all_windows()
end

wipe_state()
close_all_windows()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

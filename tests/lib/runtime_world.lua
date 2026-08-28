--[[--
runtime_world.lua — shared harness for runtime/lifecycle suites.

Provides the exact launch/wipe/tree-inspection machinery the older suites
carry inline, plus two things they lack:

  stock_launch(view, stubs)
      Simulates a TRUE stock KOReader launch with this plugin completely
      absent: pristine sandbox copy of menusorter.lua, native override file
      read through stock readMSSettings, defaults dofile'd fresh from disk,
      items collected ONLY from the given third-party widgets. No plugin
      guard can interfere because no plugin code participates.

  make_stub(...)
      Third-party provider fixtures, including the shared-entry-table style
      (module-level constant returned on every addToMainMenu) that some
      real plugins use.

Everything runs against the sandboxed ./settings directory of the installed
KOReader; suites wipe what they touch.
--]]

local RW = {}

function RW.bootstrap()
    local koreader_dir = os.getenv("KOREADER_DIR") or "/Applications/KOReader.app/Contents/koreader"
    dofile(koreader_dir .. "/setupkoenv.lua")
    local project_dir
    for level = 2, 12 do
        local info = debug.getinfo(level, "S")
        if not info then break end
        local src = info.source
        if src:sub(1, 1) == "@" then src = src:sub(2) end
        project_dir = src:match("^(.*)/tests/[^/]+$")
        if project_dir then break end
    end
    project_dir = assert(project_dir, "cannot locate plugin directory")
    package.path = project_dir .. "/?.lua;" .. package.path

    local LuaSettings = require("luasettings")
    local DataStorage = require("datastorage")
    G_reader_settings = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/settings.reader.lua")
    G_defaults = require("luadefaults"):open()

    local Device = require("device")
    local CanvasContext = require("document/canvascontext")
    CanvasContext:init(Device)

    return {
        DataStorage = DataStorage,
        settings_dir = DataStorage:getSettingsDir(),
    }
end

function RW.assert_counter()
    local passed, failed = 0, 0
    local function assert_eq(actual, expected, msg)
        if actual == expected then
            passed = passed + 1
            print("  [PASS] " .. (msg or ""))
        else
            failed = failed + 1
            print("  [FAIL] " .. (msg or "") ..
                string.format(" -> expected %s, got %s",
                    tostring(expected), tostring(actual)))
        end
        io.stdout:flush()
    end
    local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end
    local function summary(name)
        print(string.format("=== %s: %d passed, %d failed ===", name, passed, failed))
        if failed > 0 then os.exit(1) end
    end
    return {
        assert_eq = assert_eq,
        assert_true = assert_true,
        summary = summary,
    }
end

-- -------------------------------------------------------------------------
-- Mock UIs (same shape the established suites use)
-- -------------------------------------------------------------------------

function RW.mock_fm_ui(gettext)
    return {
        file_chooser = {
            show_hidden = false,
            show_unsupported = false,
            items_per_page_default = 14,
            collates = { filename = { text = gettext("Filename"), menu_order = 1 } },
            getCollate = function() return nil, "filename" end,
            refreshPath = function() end,
            toggleShowFilesMode = function() end,
        },
        registerTouchZones = function() end,
        onSetSortBy = function() end,
        registerModule = function(self, name, mod) self[name] = mod end,
    }
end

function RW.mock_reader_ui(file)
    return {
        document = { file = file or "dummy.epub" },
        registerTouchZones = function() end,
        onSetSortBy = function() end,
        registerModule = function(self, name, mod) self[name] = mod end,
    }
end

-- -------------------------------------------------------------------------
-- State hygiene
-- -------------------------------------------------------------------------

local STATE_FILES = {
    "%s/%s_menu_order.lua",
    "%s/reorderingmenus_intent.lua",
    "%s/reorderingmenus_materialization.lua",
    "%s/reorderingmenus_state.lua",
}

function RW.wipe_view(settings_dir, view, MenuOrderManager)
    RW.persistent_widgets = {}
    for _, pattern in ipairs(STATE_FILES) do
        os.remove(string.format(pattern, settings_dir, view))
    end
    pcall(function()
        require("reorderingmenus_intent_store").load(true)
        require("reorderingmenus_native_writer")._resetCaches()
    end)
    MenuOrderManager:dropSessionState(view)
    package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
    MenuOrderManager.orders[view] = nil
    MenuOrderManager.default_orders[view] = nil
    MenuOrderManager.recent_moves[view] = {}
end

function RW.wipe_all(settings_dir, MenuOrderManager)
    RW.wipe_view(settings_dir, "reader", MenuOrderManager)
    RW.wipe_view(settings_dir, "filemanager", MenuOrderManager)
end

function RW.drop_session_caches(view, MenuOrderManager)
    package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
    MenuOrderManager.orders[view] = nil
    MenuOrderManager.default_orders[view] = nil
    MenuOrderManager.recent_moves[view] = {}
end

function RW.close_all_windows(UIManager)
    while #(UIManager._window_stack or {}) > 0 do
        local entry = UIManager._window_stack[#UIManager._window_stack]
        local w = entry and (entry.widget or entry)
        if w and w.onClose then w:onClose() else UIManager:close(w) end
    end
end

-- -------------------------------------------------------------------------
-- Provider fixtures
-- -------------------------------------------------------------------------

-- opts.hint      sorting_hint carried by the entry
-- opts.children  array of { text = ... } rendered as sub_item_table
-- opts.shared    reuse ONE entry table object across every addToMainMenu call
-- opts.text      display text (default derived from id)
-- opts.view_gate "reader" | "filemanager" | nil (both)
function RW.make_stub(item_id, opts)
    opts = opts or {}
    local gettext = require("gettext")
    local shared_entry = opts.shared and {
        text = opts.text or gettext(item_id),
        sorting_hint = opts.hint,
        callback = function() end,
    } or nil
    local stub = {
        itemId = item_id,
        ui = nil,
        name = opts.name or ("stub_" .. item_id),
        addToMainMenu = function(s, menu_items)
            if opts.view_gate and s.ui then
                local is_reader = s.ui.document ~= nil
                if opts.view_gate == "reader" and not is_reader then return end
                if opts.view_gate == "filemanager" and is_reader then return end
            end
            if shared_entry then
                menu_items[item_id] = shared_entry
                return
            end
            local entry = {
                text = opts.text or gettext(item_id),
                sorting_hint = opts.hint,
                callback = function() end,
            }
            if opts.children then
                entry.sub_item_table = {}
                for _, c in ipairs(opts.children) do
                    table.insert(entry.sub_item_table, {
                        text = c.text, callback = function() end })
                end
            end
            menu_items[item_id] = entry
        end,
        last_entry = function() return shared_entry end,
    }
    return stub
end

-- -------------------------------------------------------------------------
-- Plugin-present launches (real ReaderMenu/FileManagerMenu builds)
-- -------------------------------------------------------------------------

function RW.launch(view, ui, stubs, UIScreens)
    local menu
    if view == "reader" then
        local ReaderMenu = require("apps/reader/modules/readermenu")
        menu = ReaderMenu:new{ ui = ui, view = ui.view }
    else
        local FileManagerMenu = require("apps/filemanager/filemanagermenu")
        menu = FileManagerMenu:new{ ui = ui }
    end
    ui.menu = menu
    -- Faithful "plugin enabled at launch": main.lua inserts its entry into
    -- the SHARED elements module once per process. Cache drops simulate
    -- restarts for everything EXCEPT that module singleton, so re-run the
    -- exact same guarded insertion production performs at require time.
    pcall(function()
        local already = false
        local ok_fm, fm_order =
            pcall(require, "ui/elements/filemanager_menu_order")
        if ok_fm and type(fm_order) == "table"
                and type(fm_order.more_tools) == "table" then
            for _, id in ipairs(fm_order.more_tools) do
                if id == "reordering_menus" then already = true break end
            end
        end
        if not already then
            require("ui/plugin/insert_menu").add("reordering_menus")
        end
    end)

    -- Register the plugin widget itself, exactly like ReorderingMenus:init.
    pcall(function()
        local plugin_class = require("main")
        local instance = plugin_class:new{ ui = ui }
        if menu.registerToMainMenu then
            menu:registerToMainMenu(instance)
        end
    end)

    for i, stub in ipairs(stubs or {}) do
        stub.ui = ui
        menu.registered_widgets[stub.name .. "_" .. i] = stub
    end
    -- Persistent third-party providers: suites register fixtures that must
    -- survive every rebuild (each rebuild constructs a NEW menu instance).
    RW.persistent_widgets = RW.persistent_widgets or {}
    for key, stub in pairs(RW.persistent_widgets) do
        stub.ui = ui
        menu.registered_widgets[key] = stub
    end
    if UIScreens then
        UIScreens:reconcileRegisteredItems({ ui = ui }, view, true)
    end
    menu:setUpdateItemTable()
    return menu
end

-- -------------------------------------------------------------------------
-- Rendered-tree inspection
-- -------------------------------------------------------------------------

function RW.walk(tree, fn)
    local function rec(node)
        for _, e in ipairs(node) do
            if type(e) == "table" then
                fn(e)
                if type(e.sub_item_table) == "table" then
                    rec(e.sub_item_table)
                elseif #e > 0 then
                    rec(e)
                end
            end
        end
    end
    rec(tree)
end

function RW.count_id(tree, needle)
    local n = 0
    RW.walk(tree, function(e) if e.id == needle then n = n + 1 end end)
    return n
end

function RW.find_id(tree, needle)
    local MenuSorter = require("ui/menusorter")
    return MenuSorter:findById(tree, needle)
end

function RW.children_of(tree, menu_id)
    local node = RW.find_id(tree, menu_id)
    if not node then return nil end
    local ids = {}
    for _, c in ipairs(node.sub_item_table or node) do
        table.insert(ids, tostring(c.id))
    end
    return ids
end

function RW.new_orphans(tree, prefix)
    local found = {}
    RW.walk(tree, function(e)
        if type(e.text) == "string" and e.text:sub(1, #prefix) == prefix then
            table.insert(found, tostring(e.id))
        end
    end)
    return found
end

-- Order-stable structural fingerprint of a rendered tree (ids + separators).
function RW.tree_fingerprint(tree)
    local function fp(node)
        local inner = {}
        for _, e in ipairs(node) do
            if type(e) == "table" then
                local row = tostring(e.id or "?")
                if e.separator then row = row .. "*" end
                if type(e.sub_item_table) == "table" then
                    row = row .. ">" .. fp(e.sub_item_table)
                elseif #e > 0 then
                    row = row .. ">" .. fp(e)
                end
                table.insert(inner, row)
            elseif e == "KOMenu:separator" then
                table.insert(inner, "-")
            end
        end
        return "[" .. table.concat(inner, ",") .. "]"
    end
    return fp(tree)
end

-- -------------------------------------------------------------------------
-- TRUE stock launch (plugin absent)
-- -------------------------------------------------------------------------

-- Pristine sandbox copy of the installed menusorter.lua: no plugin guards.
local stock_sorter_cache
function RW.stock_sorter()
    if stock_sorter_cache then return stock_sorter_cache end
    local chunk = assert(loadfile("frontend/ui/menusorter.lua"))
    local env = setmetatable({ require = require }, { __index = _G })
    if setfenv then setfenv(chunk, env) end
    stock_sorter_cache = assert(chunk())
    return stock_sorter_cache
end

-- Build the view menu exactly like stock KOReader would with this plugin
-- gone: defaults parsed fresh from disk, native overrides overlaid, items
-- contributed only by the given third-party widgets.
-- Returns ok, rendered_tree, orphan_id_list.
function RW.stock_launch(view, stubs)
    local sort = RW.stock_sorter()
    local MenuSorter = require("ui/menusorter")
    local ok_def, defaults = pcall(dofile,
        string.format("frontend/ui/elements/%s_menu_order.lua", view))
    local order = (ok_def and type(defaults) == "table") and defaults or {}
    local native = MenuSorter:readMSSettings(view) or {}
    for k, v in pairs(native) do order[k] = v end

    local items = { ["KOMenu:menu_buttons"] = {} }
    for _, w in ipairs(stubs or {}) do
        local ok_call, err = pcall(w.addToMainMenu, w, items)
        if not ok_call then return false, err end
    end

    -- Faithfulness: real KOReader always defines its OWN menu items (core
    -- widgets register through the same addToMainMenu path). Supply minimal
    -- definitions for every id the merged order references so hint targets,
    -- containers, and leaves exist exactly like production - EXCEPT ids in
    -- this plugin's reserved namespace, which only this plugin synthesizes
    -- and which therefore genuinely do not exist once it is removed.
    local function define(id)
        if type(id) ~= "string" or id == "----------------------------" then
            return
        end
        if id:sub(1, #"reorderingmenus:") == "reorderingmenus:" then
            return
        end
        if items[id] == nil then items[id] = { text = id } end
    end
    for menu_id, list in pairs(order) do
        if menu_id ~= "KOMenu:custom_submenus" and type(list) == "table" then
            for _, id in ipairs(list) do define(id) end
        end
    end

    local ok_sort, result = pcall(sort.sort, sort, items, order)
    if not ok_sort then return false, result end
    local orphans = RW.new_orphans(result, sort.orphaned_prefix or "NEW: ")
    return true, result, orphans
end

-- Classification used by the plugin-absence fuzz:
--   "unsafe/crash"     stock build raised
--   "safely degraded"  builds, but rows resurfaced as NEW: orphans
--   "safely preserved" builds, no leakage
function RW.classify_absent(view, stubs)
    local ok, result, orphans = RW.stock_launch(view, stubs)
    if not ok then return "unsafe/crash", result end
    if orphans and #orphans > 0 then return "safely degraded", orphans end
    return "safely preserved", nil
end

return RW



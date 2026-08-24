--[[--
ui/plugin/insert_menu call-once discipline (Error J).

KOReader documents insert_menu as process-singleton state that mutates the
shared Reader/FM order tables directly, with callers "expected to call add()
only once to avoid duplicates". main.lua therefore guards the call by
scanning more_tools first. Locked down here:

  J1  requiring main twice in one process registers reordering_menus exactly
      once in both shared order modules.
  J2  building Reader and FileManager menus repeatedly (open -> close ->
      reopen cycles) renders reordering_menus exactly once per menu tree.
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

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or ""))
        io.stdout:flush()
    else
        failed = failed + 1
        print("  [FAIL] " .. (msg or "") ..
            string.format(" -> expected %s, got %s", tostring(expected), tostring(actual)))
        io.stdout:flush()
    end
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end

local function count_in(list, needle)
    local n = 0
    for _, id in ipairs(list or {}) do
        if id == needle then n = n + 1 end
    end
    return n
end

print("===============================================================")
print("=== insert_menu singleton discipline                         ===")
print("===============================================================")

print("\n--- J1: double require cannot duplicate the registration ---")
do
    package.loaded["main"] = nil -- force re-execution of the module body
    require("main")
    package.loaded["main"] = nil
    require("main")

    local fm_order = require("ui/elements/filemanager_menu_order")
    local rd_order = require("ui/elements/reader_menu_order")
    assert_eq(count_in(fm_order.more_tools, "reordering_menus"), 1,
        "J1: FM more_tools holds reordering_menus exactly once")
    assert_eq(count_in(rd_order.more_tools, "reordering_menus"), 1,
        "J1: Reader more_tools holds reordering_menus exactly once")
end

print("\n--- J2: repeated menu construction renders one entry ---")
do
    local UIManager = require("ui/uimanager")
    local ReaderMenu = require("apps/reader/modules/readermenu")
    local FileManagerMenu = require("apps/filemanager/filemanagermenu")
    local MenuSorter = require("ui/menusorter")

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
    local mock_ui_reader = {
        document = { file = "dummy.epub" },
        registerTouchZones = function() end,
        registerModule = function(self, name, mod) self[name] = mod end,
    }

    local function count_entries(tree, needle)
        local n = 0
        local function walk(node)
            for _, e in ipairs(node) do
                if type(e) == "table" then
                    if e.id == needle then n = n + 1 end
                    if type(e.sub_item_table) == "table" then walk(e.sub_item_table) end
                    if #e > 0 then walk(e) end
                end
            end
        end
        walk(tree)
        return n
    end

    local ok_cycles = true
    for i = 1, 3 do
        local plugin_fm = require("main"):new{ ui = mock_ui_fm }
        mock_ui_fm.menu = FileManagerMenu:new{ ui = mock_ui_fm }
        mock_ui_fm.menu:registerToMainMenu(plugin_fm)
        mock_ui_fm.menu:setUpdateItemTable()
        if count_entries(mock_ui_fm.menu.tab_item_table, "reordering_menus") ~= 1 then
            ok_cycles = false
        end

        local plugin_rd = require("main"):new{ ui = mock_ui_reader }
        mock_ui_reader.menu = ReaderMenu:new{ ui = mock_ui_reader, view = nil }
        mock_ui_reader.menu:registerToMainMenu(plugin_rd)
        mock_ui_reader.menu:setUpdateItemTable()
        if count_entries(mock_ui_reader.menu.tab_item_table, "reordering_menus") ~= 1 then
            ok_cycles = false
        end

        -- destroy Reader like closing a book, open another one next cycle
        mock_ui_reader.menu = nil
        mock_ui_reader.document = { file = "other.epub" }
        _ = UIManager
    end
    assert_true(ok_cycles,
        "J2: three Reader/FM construction cycles render exactly one entry each")
end

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

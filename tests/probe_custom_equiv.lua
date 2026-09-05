-- Probe (#10): does a custom submenu created via the manager render in the
-- live KOReader menu through the SAME addToMainMenu/MenuSorter path a stock
-- plugin uses? Equivalence = customs need NO separate injection mechanism.
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
local _sd = DataStorage:getSettingsDir()
pcall(os.remove, _sd .. "/reorderingmenus_intent.lua")
pcall(os.remove, _sd .. "/reorderingmenus_materialization.lua")

local UIManager = require("ui/uimanager")
local MenuSorter = require("ui/menusorter")
local FileManagerMenu = require("apps/filemanager/filemanagermenu")
local ReorderingMenus = require("main")
local UIScreens = require("lib.ui_screens")
local Mgr = require("lib.menuorder_manager")

local view = "filemanager"
local mock_ui_fm = {
    registerModule = function(self, name, mod) self[name] = mod end,
    file_chooser = {
        update = function() end,
        collates = {},
        getCollate = function() return "title", "strcoll" end,
    },
}

local fm_menu = FileManagerMenu:new{ ui = mock_ui_fm }
mock_ui_fm.menu = fm_menu
local plugin = ReorderingMenus:new{ ui = mock_ui_fm }
fm_menu:registerToMainMenu(plugin)

-- Create a custom submenu under tools with go_to inside it.
local ok, sub_id = Mgr:createSubmenu(view, "tools", "Probe Sub")
print("created:", ok, sub_id ~= nil)
print("staged into custom:", Mgr:stageList(view, sub_id, { "go_to" }))
local function kids(tag)
    local l = Mgr:getMenuItems(view, sub_id) or {}
    local t = {}
    for _, r in ipairs(l) do t[#t+1] = type(r) == "table" and (r.id or "?") or tostring(r) end
    print("KIDS[" .. tag .. "] = " .. table.concat(t, ","))
end
kids("after-stage")
local saved_ok, saved_path = Mgr:saveOrder(view)
print("saved:", saved_ok, saved_path)
kids("after-save")
-- Raw persisted file: does the uuid list carry go_to?
local f = io.open(saved_path, "r")
local raw = f and f:read("*a") or ""
if f then f:close() end
print("FILE_HAS_GOTO:", raw:find("go_to", 1, true) ~= nil)
UIScreens:reconcileRegisteredItems(plugin, view, true)
kids("after-reconcile")

fm_menu:setUpdateItemTable()

-- Walk the live rendered tree looking for the custom title's menu level.
local function find_by_text(tree, text)
    for _, e in ipairs(tree or {}) do
        if type(e) == "table" then
            if e.text == text then return e end
            if e.sub_item_table then
                local hit = find_by_text(e.sub_item_table, text)
                if hit then return hit end
            end
        end
    end
end

local node = find_by_text(fm_menu.tab_item_table, "Probe Sub")
if node then
    local kids = {}
    for _, c in ipairs(node.sub_item_table or {}) do kids[#kids+1] = tostring(c.id) end
    print("RENDERED with children:", table.concat(kids, ","))
else
    -- Fallback: findById by id (title may be wrapped).
    node = MenuSorter:findById(fm_menu.tab_item_table, sub_id)
    if node then
        local kids = {}
        for _, c in ipairs(node.sub_item_table or {}) do kids[#kids+1] = tostring(c.id) end
        print("RENDERED(by id) children:", table.concat(kids, ","))
    else
        print("NOT RENDERED")
    end
end

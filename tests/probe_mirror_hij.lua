--[[-- probe_mirror_hj.lua — pre-test probes for H/I/J gap scenarios.

P1: move a dual-context item into an FM-only destination under mirror ON —
    what does reader canonical/projection hold?
P2: failed intent persist with mirror staged — do BOTH view sections roll back?
P3: setTabHidden under mirror ON — does the tab hide cross-write?
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
CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
local _ = require("gettext")
require("main")

local Manager = require("reorderingmenus_menuorder_manager")
local IntentStore = require("reorderingmenus_intent_store")
local NativeWriter = require("reorderingmenus_native_writer")
local util = require("util")

local sd = DataStorage:getSettingsDir()
local function wipe_all()
    for _, f in ipairs({ "filemanager_menu_order.lua", "reader_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        os.remove(sd .. "/" .. f)
    end
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}
    Manager.recent_moves.reader = {}
    Manager:dropSessionState("filemanager")
    Manager:dropSessionState("reader")
end

local function rec_to_str(v)
    if type(v) ~= "table" then return tostring(v) end
    local parts = {}
    for k, val in pairs(v) do
        parts[#parts + 1] = tostring(k) .. "=" .. (type(val) == "table"
            and "{" .. rec_to_str(val) .. "}" or tostring(val))
    end
    return table.concat(parts, ",")
end

local function dump(tag, t) print(tag .. ": " .. rec_to_str(t)) end

-- ---------------- P1: FM-only destination under mirror ----------------
wipe_all()
Manager:setMirroringEnabled(true)
Manager:setLiveRegistrations("reader",
    { mir_p1 = { sorting_hint = "more_tools" } }, { mir_p1 = "prov_r" })
Manager:setLiveRegistrations("filemanager",
    { mir_p1 = { sorting_hint = "more_tools" } }, { mir_p1 = "prov_f" })
Manager:reconcileRegisteredItems("reader",
    { mir_p1 = { sorting_hint = "more_tools" } }, { mir_p1 = "prov_r" })
Manager:reconcileRegisteredItems("filemanager",
    { mir_p1 = { sorting_hint = "more_tools" } }, { mir_p1 = "prov_f" })
Manager:saveOrder("reader"); Manager:saveOrder("filemanager")

print("\n=== P1: move into FM-only destination ===")
local fm_menus = Manager:getAllMenusAndSubmenus("filemanager")
print("FM menus: " .. tostring(fm_menus and type(fm_menus) == "table" and #fm_menus or fm_menus))
local ok = Manager:moveItemToMenu("filemanager", "mir_p1", "more_tools", "filemanager_settings")
print("move ok=" .. tostring(ok))
print("FM parent: " .. tostring(Manager:getParentMenu("filemanager", "mir_p1")))
print("reader canonical po: " .. tostring(IntentStore.view("reader").parent_override.mir_p1
    and rec_to_str(IntentStore.view("reader").parent_override.mir_p1) or "nil"))
print("reader projected parent: " .. tostring(Manager:getParentMenu("reader", "mir_p1")))
local r_menu_items = Manager:getMenuItems("reader", "filemanager_settings")
print("reader getMenuItems(filemanager_settings): "
    .. (r_menu_items and table.concat(r_menu_items, ",") or "nil"))
local ok2 = pcall(function() Manager:saveOrder("reader"); Manager:saveOrder("filemanager") end)
print("saves ok=" .. tostring(ok2))
print("after save reader projected parent: " .. tostring(Manager:getParentMenu("reader", "mir_p1")))

-- ---------------- P2: cross-view rollback atomicity ----------------
print("\n=== P2: failed persist rolls back BOTH sections ===")
wipe_all()
Manager:setMirroringEnabled(true)
Manager:setLiveRegistrations("reader",
    { mir_p2 = { sorting_hint = "more_tools" } }, { mir_p2 = "w" })
Manager:setLiveRegistrations("filemanager",
    { mir_p2 = { sorting_hint = "more_tools" } }, { mir_p2 = "w" })
Manager:reconcileRegisteredItems("reader",
    { mir_p2 = { sorting_hint = "more_tools" } }, { mir_p2 = "w" })
Manager:reconcileRegisteredItems("filemanager",
    { mir_p2 = { sorting_hint = "more_tools" } }, { mir_p2 = "w" })
Manager:saveOrder("reader"); Manager:saveOrder("filemanager")

local real_writeToFile = util.writeToFile
util.writeToFile = function() return nil, "injected total io failure" end
Manager:moveItemToMenu("filemanager", "mir_p2", "more_tools", "setting")
local save_ok = Manager:saveOrder("filemanager")
util.writeToFile = real_writeToFile
print("saveOrder returned: " .. tostring(save_ok))
print("FM canonical po: " .. tostring(IntentStore.view("filemanager").parent_override.mir_p2
    and rec_to_str(IntentStore.view("filemanager").parent_override.mir_p2) or "nil"))
print("reader canonical po: " .. tostring(IntentStore.view("reader").parent_override.mir_p2
    and rec_to_str(IntentStore.view("reader").parent_override.mir_p2) or "nil"))
print("FM staged po: " .. tostring(Manager:stagedView("filemanager").parent_override.mir_p2
    and "present" or "nil"))
print("reader staged po: " .. tostring(Manager:stagedView("reader").parent_override.mir_p2
    and "present" or "nil"))
-- healthy retry after recovery
print("retry save: " .. tostring(Manager:saveOrder("filemanager")))
print("retry reader projected parent: " .. tostring(Manager:getParentMenu("reader", "mir_p2")))

-- ---------------- P3: tab hide mirroring ----------------
print("\n=== P3: setTabHidden cross-write ===")
wipe_all()
Manager:setMirroringEnabled(true)
local tabs = Manager:getTabs("filemanager")
print("FM tabs: " .. table.concat(tabs, ","))
local rtabs = Manager:getTabs("reader")
print("reader tabs: " .. table.concat(rtabs, ","))
if #tabs > 0 then
    local t = tabs[1]
    Manager:setTabHidden("filemanager", t, true)
    print("hid FM tab '" .. t .. "'")
    print("reader disabled contains it: " .. tostring(
        util.arrayContains(Manager:getDisabledItems("reader") or {}, t)))
    print("FM disabled contains it: " .. tostring(
        util.arrayContains(Manager:getDisabledItems("filemanager") or {}, t)))
end
wipe_all()
print("\nprobe done")

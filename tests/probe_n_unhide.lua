-- Full fuzz-sequence isolation with save_order after hides (like the real run).
package.path = "/Users/nr/Development/ReorderingMenus/?.lua;" .. package.path
dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
_ = require("gettext")
require("main")
local Manager = require("menuorder_manager")
local IntentStore = require("intent_store")
local util = require("util")

local VIEW = "filemanager"
Manager.default_orders[VIEW] =
    util.tableDeepCopy(require("ui/elements/filemanager_menu_order"))
Manager:resetOrder(VIEW)
Manager:dropSessionState(VIEW)
_ = Manager:loadOrder(VIEW)

local function bar(tag)
    local order = Manager:loadOrder(VIEW)
    io.stderr:write(tag .. " bar=[" ..
        table.concat(order["KOMenu:menu_buttons"] or {}, ",") .. "]\n")
end
local function hidden_ids(tag)
    local s = {}
    for id in pairs(IntentStore.view(VIEW).hidden or {}) do
        s[#s + 1] = id
    end
    table.sort(s)
    io.stderr:write(tag .. " hidden={" .. table.concat(s, ",") .. "}\n")
end

-- exact fuzz prefix: add ntab1, reset x2, save, restart(sim), unhide_all, hide x2, save,
-- remove setting, reorder, remove fm_settings, unhide_all

-- upstream_add_tab ntab1
do
    local defaults = util.tableDeepCopy(Manager.default_orders[VIEW])
    table.insert(defaults["KOMenu:menu_buttons"], "ntab1")
    defaults["ntab1"] = { "welcome_row_ntab1" }
    Manager.default_orders[VIEW] = defaults
    Manager:dropSessionState(VIEW)
end
Manager:resetOrder(VIEW)   -- reset 1
Manager:resetOrder(VIEW)   -- reset 2
print("save1:", Manager:saveOrder(VIEW))
bar("after resets+save")
-- restart equivalent
Manager:dropSessionState(VIEW)
_ = Manager:loadOrder(VIEW)
-- unhide_all (no-op; nothing disabled yet)
do
    local disabled = Manager:getDisabledItems(VIEW)
    for _, id in ipairs(disabled) do pcall(Manager.setItemHidden, Manager, VIEW, id, false) end
end
-- hide tabs search + setting
print("hide search:", Manager:setTabHidden(VIEW, "search", true))
print("hide setting:", Manager:setTabHidden(VIEW, "setting", true))
hidden_ids("after-hides")
print("save2:", Manager:saveOrder(VIEW))
hidden_ids("after-save2")

-- upstream_remove_tab setting (HIDDEN at this point)
do
    local defaults = util.tableDeepCopy(Manager.default_orders[VIEW])
    for i, t in ipairs(defaults["KOMenu:menu_buttons"]) do
        if t == "setting" then table.remove(defaults["KOMenu:menu_buttons"], i) break end
    end
    defaults["setting"] = nil
    Manager.default_orders[VIEW] = defaults
    Manager:dropSessionState(VIEW)
end
hidden_ids("after-remove-setting")
bar("after-remove-setting bar")
-- reorder visible tabs (rotate first to end)
local tabs = Manager:getTabs(VIEW)
local perm = {}
for _, t in ipairs(tabs) do perm[#perm + 1] = t end
table.insert(perm, table.remove(perm, 1))
print("reorder:", Manager:reorderTabs(VIEW, perm))
-- upstream_remove_tab filemanager_settings
do
    local defaults = util.tableDeepCopy(Manager.default_orders[VIEW])
    for i, t in ipairs(defaults["KOMenu:menu_buttons"]) do
        if t == "filemanager_settings" then
            table.remove(defaults["KOMenu:menu_buttons"], i) break
        end
    end
    defaults["filemanager_settings"] = nil
    Manager.default_orders[VIEW] = defaults
    Manager:dropSessionState(VIEW)
end
hidden_ids("after-remove-fms")
bar("after-remove-fms bar")
-- unhide_all
do
    local disabled = Manager:getDisabledItems(VIEW)
    io.stderr:write("disabled n=" .. #disabled ..
        (disabled[1] and (" first=" .. disabled[1]) or "") .. "\n")
    for _, id in ipairs(disabled) do
        pcall(Manager.setItemHidden, Manager, VIEW, id, false)
    end
end
hidden_ids("after-unhide-all")
bar("final bar")
os.exit(0)

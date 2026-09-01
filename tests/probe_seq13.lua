-- After step-13 unhide_all, is the record cleared after a SAVE? And what
-- does the I6 checker read (staged vs canonical)?
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
local World = require("tests.lib.sm_world")
local IntentStore = require("intent_store")
local Manager = require("menuorder_manager")

-- Run steps 1-12 exactly as before (same biased stepper, same seed).
local TAB_OPS = { "hide_tab", "reorder_tabs", "upstream_add_tab",
    "upstream_remove_tab", "save_order", "restart", "reset_view",
    "unhide_all", "apply_preset" }
World.step = function(self)
    local weights, total = {}, 0
    for _, name in ipairs(World.OP_NAMES) do
        local w = 0
        for _, t in ipairs(TAB_OPS) do if t == name then w = 12 break end end
        if w == 0 and (name == "move_item_in_menu" or name == "hide_item") then w = 1 end
        weights[name] = w; total = total + w
    end
    local roll = self:rand(total)
    local chosen
    for _, name in ipairs(World.OP_NAMES) do
        local w = weights[name] or 0
        if roll <= w and w > 0 then chosen = name break end
        roll = roll - w
    end
    chosen = chosen or "save_order"
    local spec = World.OPS[chosen]
    local args = spec.pick(self)
    if args == nil then return chosen, nil, chosen .. "(skipped)" end
    self.history[#self.history + 1] = { op = chosen, args = args }
    self.op_counter = self.op_counter + 1
    local ok, desc = pcall(spec.apply, self, args)
    if not ok then desc = "OPERROR: " .. tostring(desc) end
    return chosen, args, desc
end

local seed = 570434
local w = World:new(seed)
for i = 1, 12 do w:step() end

io.stderr:write("after 12: canonical hidden.setting? " ..
    tostring(IntentStore.view(w.view).hidden.setting ~= nil) .. "\n")

-- Step 13 equivalent: unhide_all via getDisabledItems + setItemHidden.
local disabled = Manager:getDisabledItems(w.view)
io.stderr:write("disabled includes setting? ")
for _, id in ipairs(disabled) do
    if id == "setting" then io.stderr:write("YES ") end
end
io.stderr:write("\n")
for _, id in ipairs(disabled) do
    pcall(Manager.setItemHidden, Manager, w.view, id, false)
end

io.stderr:write("after unhide_all: canonical hidden.setting? " ..
    tostring(IntentStore.view(w.view).hidden.setting ~= nil) ..
    " staged? " ..
    tostring(Manager:stagedView(w.view).hidden.setting ~= nil) .. "\n")

print("save now:", Manager:saveOrder(w.view))
io.stderr:write("after save: canonical hidden.setting? " ..
    tostring(IntentStore.view(w.view).hidden.setting ~= nil) .. "\n")

-- restore upstream defaults so 'setting' returns, reload:
local util = require("util")
Manager.default_orders[w.view] =
    util.tableDeepCopy(require("ui/elements/filemanager_menu_order"))
Manager:dropSessionState(w.view)
_ = Manager:loadOrder(w.view)
local order = Manager:loadOrder(w.view)
io.stderr:write("final bar=[" ..
    table.concat(order["KOMenu:menu_buttons"] or {}, ",") .. "]\n")
os.exit(0)

-- After step-13 unhide_all, run the I6 checker WITHOUT a save: does it fail?
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
local IntentStore = require("reorderingmenus_intent_store")
local Manager = require("reorderingmenus_menuorder_manager")

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

-- Step 13 equivalent: unhide_all WITHOUT saving afterward.
local disabled = Manager:getDisabledItems(w.view)
for _, id in ipairs(disabled) do
    pcall(Manager.setItemHidden, Manager, w.view, id, false)
end

-- Now run the invariant battery exactly like the fuzz does (no save first).
local ok, failures = w:check()
if not ok then
    io.stderr:write("CHECK FAILED BEFORE ANY SAVE:\n")
    for _, f in ipairs(failures) do
        io.stderr:write("  - " .. tostring(f):sub(1, 180) .. "\n")
    end
else
    io.stderr:write("check clean without save\n")
end

-- Then save and check again.
print("save:", Manager:saveOrder(w.view))
ok, failures = w:check()
if not ok then
    io.stderr:write("CHECK STILL FAILING AFTER SAVE:\n")
    for _, f in ipairs(failures) do
        io.stderr:write("  - " .. tostring(f):sub(1, 180) .. "\n")
    end
else
    io.stderr:write("check clean after save\n")
end
os.exit(0)

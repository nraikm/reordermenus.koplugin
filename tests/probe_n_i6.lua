-- N repro v2: dump the world state at the failure step.
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

local TAB_OPS = { "hide_tab", "reorder_tabs", "upstream_add_tab",
    "upstream_remove_tab", "save_order", "restart", "reset_view",
    "unhide_all", "apply_preset" }
local real_step = World.step
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
for i = 1, 25 do
    local name, args = w:step()
    io.stderr:write(string.format("%2d %-22s %s\n", i, name,
        (args and (args.id or args.view or "") or "")))
    if name == "reset_view" then
        local sec = IntentStore.view(w.view)
        io.stderr:write("   post-reset tab_order=" ..
            tostring(sec.tab_order and table.concat(sec.tab_order, ",") or "nil")
            .. " view=" .. w.view .. "\n")
        local order = w:projection()
        io.stderr:write("   bar=[" ..
            table.concat(order["KOMenu:menu_buttons"] or {}, ",") .. "]\n")
    end
    if name == "unhide_all" then
        local sec = IntentStore.view(w.view)
        io.stderr:write("   post-unhide hidden n=" ..
            ((function() local n=0 for _ in pairs(sec.hidden or {}) do n=n+1 end return n end)())
            .. " view=" .. w.view .. "\n")
        local order = w:projection()
        io.stderr:write("   bar=[" ..
            table.concat(order["KOMenu:menu_buttons"] or {}, ",") .. "]\n")
        for id in pairs(sec.hidden or {}) do
            io.stderr:write("   still-hidden: " .. tostring(id) .. "\n")
        end
    end
    local ok, failures = w:check()
    if not ok then
        io.stderr:write("FAILED AT STEP " .. i .. ": " ..
            tostring(failures[1]):sub(1, 200) .. "\n")
        break
    end
end
os.exit(0)

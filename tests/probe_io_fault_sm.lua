--[[--
probe_io_fault_sm.lua — trace seed 7919 around the io_fault_save op.

Replays the manager-verb world deterministically, prints every op, and
dumps canonical-intent + projections immediately before/after the injected
IO fault and after the view switch, to expose what a failed commit leaves
behind (session caches, active transaction, canonical bytes).
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
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
local _ = require("gettext")
require("main")

local World = require("tests.lib.sm_world")
local Manager = require("menuorder_manager")
local IntentStore = require("intent_store")
local dump = require("dump")

local function fp(value)
    return World.fingerprint(value)
end

local w = World:new(7919)
for step = 1, 22 do
    local opname, args, desc = w:step()
    local line = string.format("step %2d: %-24s %s", step, opname, tostring(desc))
    if opname == "io_fault_save" then
        print(line .. "   <<< FAULT")
        print("   canonical fp after fault (no reload):",
            fp(IntentStore.load().views[w.view]))
        print("   search list:", table.concat(Manager:getMenuItems("filemanager", "search"), ","))
        print("   tools list :", table.concat(Manager:getMenuItems("filemanager", "tools"), ","))
        -- the harness recovery the verbs suite performs:
        Manager:dropSessionState(w.view)
        IntentStore.load(true)
        print("   canonical fp after dropSession+reload:", fp(IntentStore.load().views[w.view]))
        print("   search list after reload:",
            table.concat(Manager:getMenuItems("filemanager", "search"), ","))
        print("   tools list after reload:",
            table.concat(Manager:getMenuItems("filemanager", "tools"), ","))
    elseif opname == "reader_fm_switch" then
        print(line .. "   <<< SWITCH -> " .. w.view)
        local v = w.view
        print(string.format("   %s search:", v),
            table.concat(Manager:getMenuItems(v, "search"), ","))
        print(string.format("   %s tools:", v),
            table.concat(Manager:getMenuItems(v, "tools"), ","))
        local sec = IntentStore.load().views[v]
        print("   order_override keys:", fp(sec.order_override or {}))
        print("   hidden:", fp(sec.hidden or {}))
    else
        print(line)
    end
    local ok, failures = w:check({})
    if not ok then
        print("   INVARIANT FAILURES:")
        for _, f in ipairs(failures) do print("     - " .. f) end
        break
    end
end
print("probe done")

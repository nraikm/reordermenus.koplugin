-- P1 helper: replay given fixture files and print full failure detail
dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = "/Users/nr/Development/ReorderingMenus/tests/probe_cluster_detail.lua"
local project_dir = "/Users/nr/Development/ReorderingMenus"
package.path = project_dir .. "/?.lua;" .. package.path
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
require("main")
local World = require("tests.lib.sm_world")

for _, fname in ipairs({...}) do
    local chunk = assert(loadfile(project_dir .. "/tests/fixtures/regression/" .. fname))
    local fx = chunk()
    local w = World:new(fx.seed)
    local ops = {}
    for i, entry in ipairs(fx.history or {}) do
        ops[#ops+1] = entry.op .. "(" .. tostring(World.fingerprint(entry.args)):sub(1,60) .. ")"
        local desc = w:replay(entry)
        if type(desc) == "string" and desc:sub(1,8) == "OPERROR:" then
            print(fname, "OPERROR at op", i, desc)
            goto continue
        end
        local ok, ffails = w:check({})
        if not ok then
            print("FIXTURE", fname, "fails_at_op", i, "history_len", #(fx.history or {}))
            for _, e in ipairs(fx.history or {}) do print("  op:", e.op) end
            for _, f in ipairs(ffails) do print("  fail:", f) end
            break
        end
        ::continue::
    end
end

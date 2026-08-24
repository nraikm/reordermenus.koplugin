-- P1: classify every fixture by (trigger_op, invariant signature)
dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = "/Users/nr/Development/ReorderingMenus/tests/probe_trigger_scan.lua"
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
local lfs = require("libs/libkoreader-lfs")
local FailureSig = dofile(project_dir .. "/tests/lib/failure_sig.lua")

local files = {}
for e in lfs.dir(project_dir .. "/tests/fixtures/regression") do
    if e:match("%.lua$") then files[#files+1] = e end
end
table.sort(files)
for _, fname in ipairs(files) do
    local chunk = loadfile(project_dir .. "/tests/fixtures/regression/" .. fname)
    if chunk then
        local fx = chunk()
        if type(fx) == "table" and fx.history then
            local w = World:new(fx.seed)
            local outcome = "passes"
            local trig = "-"
            for i, entry in ipairs(fx.history) do
                local desc = w:replay(entry)
                if type(desc) == "string" and desc:sub(1,8) == "OPERROR:" then
                    -- skipped ops are fine; only count a crash of the LAST op? no:
                    -- treat OPERROR as skip-continuation unless it is the final op
                    if i == #fx.history then outcome = "OPERROR" trig = entry.op end
                else
                    local ok, ffails = w:check({})
                    if not ok then
                        outcome = "fails"
                        trig = entry.op
                        print(string.format("%s\t%s\t%s\t%s", fname, outcome, trig,
                            FailureSig.normalize(ffails)))
                        break
                    end
                end
            end
            if outcome == "passes" then
                print(string.format("%s\tXPASS\t-\t-", fname))
            end
        end
    end
end

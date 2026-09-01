dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = "/Users/nr/Development/ReorderingMenus/tests/probe_replay_stability.lua"
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
local chunk = assert(loadfile(project_dir .. "/tests/fixtures/regression/seed-23757-step-2-save_preset.lua"))
local fx = chunk()
local w = World:new(fx.seed)
for i, entry in ipairs(fx.history) do
    local spec_ok, desc = pcall(function() return w:replay(entry) end)
    if not spec_ok then
        print("REPLAY_CRASH_OP", i)
        print(desc)
    elseif type(desc) == "string" and desc:sub(1,8) == "OPERROR:" then
        print("OP_CRASH_OP", i, entry.op)
        -- re-run without pcall inside replay to get lua traceback:
        local OpsRaw = nil
        print("traceback follows:")
        local ok, err = pcall(function()
            -- direct call path: Manager:savePreset like the op does
            local Manager = require("menuorder_manager")
            Manager:savePreset(w.view, "probe_preset_1")
        end)
        if not ok then print(err) end
        break
    end
end

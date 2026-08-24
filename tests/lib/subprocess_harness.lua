--[[
Reusable subprocess harness for real-process restart testing (Area 9).

Each "process" is a separate luajit invocation of the installed KOReader
runtime, so package.loaded, module-level caches, singletons, and global
guards reset exactly like on a user's device. The parent script spawns
children with run_phase() and asserts on their captured stdout.

-- Usage from a test:
--     local H = dofile(".../tests/lib/subprocess_harness.lua")
--     local out1 = H.run_phase("phase1", "...lua code...")
--     assert(out1.some_key == "some_value")

Environment variables honored inside phases:
    RM_PHASE_SETTINGS_DIR - isolated settings dir (hermetic runs)
--]]

local function sh_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local H = {}

H.koreader_dir = "/Applications/KOReader.app/Contents/koreader"
H.luajit = H.koreader_dir .. "/luajit"
H.plugin_dir = arg and arg[0]
    and arg[0]:match("^(.*)/tests/[^/]+$") or nil

function H.run_phase(phase_name, code, env_extra)
    if not H.plugin_dir then error("cannot locate plugin dir", 0) end
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. sh_quote(dir))
    local file = dir .. "/" .. phase_name .. ".lua"
    local f = assert(io.open(file, "w"))
    f:write("-- subprocess phase: " .. phase_name .. "\n")
    f:write([[
dofile("]] .. H.koreader_dir .. [[/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
package.path = ]] .. string.format("%q", H.plugin_dir .. "/?.lua;") .. [[ .. package.path
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
require("gettext")
]])
    f:write(code)
    f:write("\nos.exit(0)\n")
    f:close()

    local env = ""
    if env_extra then
        for k, v in pairs(env_extra) do
            env = env .. k .. "=" .. sh_quote(v) .. " "
        end
    end
    -- 2>&1 merged: KOReader logging is noisy, so the caller greps.
    local out_pipe = io.popen(env .. sh_quote(H.luajit) .. " " .. sh_quote(file) .. " 2>&1")
    local captured = {}
    for line in out_pipe:lines() do
        table.insert(captured, line)
    end
    local ok_run, _, status = out_pipe:close()
    return {
        output = table.concat(captured, "\n"),
        exit_ok = ok_run == true or status == 0,
        raw_lines = captured,
    }, dir
end

-- Extract `key<TAB>value` result lines a phase printed via H.emit().
H.RESULT_MARK = "RM_RESULT\t"

function H.emit(key, value)
    print(H.RESULT_MARK .. tostring(key) .. "\t" .. tostring(value))
end

function H.parse_results(result)
    local values = {}
    for line in result.output:gmatch("[^\n]+") do
        local key, value = line:match("^" .. H.RESULT_MARK:gsub("%p", "%%%p") .. "(.-)\t(.*)$")
        if key then values[key] = value end
    end
    return values
end

return H

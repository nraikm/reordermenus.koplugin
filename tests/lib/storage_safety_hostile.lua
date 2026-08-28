-- One hostile payload per process, driven by run_storage_safety_hostile.sh.
-- Every case must end with "RESULT OK" on stdout; a hang gets the process
-- watchdog-killed and counts as failure.
io.stdout:setvbuf("no")
local koreader_dir = os.getenv("KOREADER_DIR") or "/Applications/KOReader.app/Contents/koreader"
local plugin_dir = os.getenv("PLUGIN_DIR") or "."
dofile(koreader_dir .. "/setupkoenv.lua")
package.path = plugin_dir .. "/?.lua;" .. package.path

local DataLoader = require("reorderingmenus_data_loader")
local case = arg and arg[1] or ""
local path = "/tmp/rm_hostile_case.lua"
local f = assert(io.open(path, "wb"))

if case == "infinite" then
    f:write("return (function() while true do end end)()\n")
elseif case == "tailcall" then
    f:write("local function f() while true do end end return f()\n")
elseif case == "huge" then
    f:write("local t = {} for i = 1, 50e6 do t[i] = {i} end return t\n")
elseif case == "hugefn" then
    f:write("return (function() local t = {} for i = 1, 50e6 do "
        .. "t[i] = {i} end return #t end)()\n")
elseif case == "oversize" then
    f:write('return { pad = "', string.rep("x", 9 * 1024 * 1024), '" }\n')
else
    f:close()
    error("unknown case: " .. case)
end
f:close()

local t0 = os.clock()
local data, err = DataLoader.loadTable(path)
local elapsed = os.clock() - t0
if data ~= nil then
    print(string.format("RESULT FAIL case=%s unexpectedly loaded", case))
    os.exit(1)
end
if elapsed > 5 then
    print(string.format("RESULT FAIL case=%s took %.2fs (budget ineffective)", case, elapsed))
    os.exit(1)
end
print(string.format("RESULT OK case=%s rejected after %.3fs: %.60s",
    case, elapsed, tostring(err)))

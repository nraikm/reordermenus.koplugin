--[[
data_loader.lua — the ONE restricted table loader for serialized state.

Every file this plugin treats as DATA (canonical intent, materialization
sidecar, presets, hidden-builtins list, legacy sidecar state) must be
executed in a restricted environment that returns a value without granting
application privileges. Legitimate CODE files (KOReader's own menu order
modules, menusorter.lua probes) are NOT routed through here: they keep
loading through require()/dofile() exactly as before.

Contract of loadTable(path):

  * the file is rejected before compilation when its byte size exceeds
    MAX_FILE_BYTES - persisted plugin state is kilobytes, so eight mebibytes
    is already pathological (crash-loop garbage or an attack), never user
    data;
  * the chunk runs with a restricted environment - no _G, no io, no os,
    no dofile, no require, no package; ANY global access raises;
  * execution runs under an instruction budget: a count-mode debug hook
    fires every EXEC_HOOK_INTERVAL VM instructions and aborts once
    EXEC_BUDGET instructions have been consumed, so `while true do end`
    payloads and huge table constructions fail fast instead of hanging
    startup or exhausting memory. The chunk is excluded from JIT tracing
    first: on this runtime, count hooks DO NOT FIRE inside JIT-compiled
    loops (verified: an unrestricted `while true do end` never triggers
    the hook), so jit.off is what makes the budget actually enforceable;
  * the only way to return anything is the `return` statement, so a data
    file can never perform side effects that survive the call: mutating
    globals lands in a throwaway sandbox table, writing files is
    impossible, os.execute is unreachable;
  * the result must be a table; anything else is reported as a failure
    with the parse/runtime error text preserved for diagnostics;
  * valid historical files produced by dump() / AtomicWriter.writeTable
    ("-- <path>\nreturn <table>") load byte-compatibly.

Shape validation stays with the caller (validateIntentState,
normalizeNativeOrder, preset format checks): this module decides ONLY
"does this file parse, respect the resource bounds, and return a table
under restriction".

Both limits are module fields so tests can tighten them temporarily.
--]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local DataLoader = {}

-- Reject absurdly large files BEFORE compiling them. Realistic canonical
-- intent / preset / sidecar state is well under 100 KB even with thousands
-- of records; 8 MiB leaves two orders of magnitude of headroom while still
-- bounding the cost of a hostile or corrupt file.
DataLoader.MAX_FILE_BYTES = 8 * 1024 * 1024

-- Instruction budget for executing the loaded chunk. Counted in units of
-- EXEC_HOOK_INTERVAL VM instructions (the debug-hook granularity). A valid
-- serialized-data file executes only a handful of instructions per table
-- node; 50M instructions allows multi-megabyte legitimate states many times
-- over yet stops `while true do end` and giant-construction bombs in well
-- under a second (measured: 50M-row construction aborts in ~0.1s).
DataLoader.EXEC_BUDGET = 50 * 1000 * 1000
DataLoader.EXEC_HOOK_INTERVAL = 1000

local RESTRICTED_ENV = setmetatable({}, {
    __index = function(_, key)
        -- Data files legitimately reference nothing. Any global access is
        -- a bug in the producer, not something to serve from _G.
        error("restricted data loader: global access to " .. tostring(key), 2)
    end,
    -- Writes must fail loudly as well: assignments land nowhere - not in
    -- this table, not in _G - and the chunk aborts with a clear error.
    __newindex = function(_, key)
        error("restricted data loader: global assignment to "
            .. tostring(key), 2)
    end,
})

local function readBounded(path)
    local attr = lfs.attributes(path, "size")
    if type(attr) == "number" and attr > DataLoader.MAX_FILE_BYTES then
        return nil, string.format("file too large (%d bytes, limit %d)",
            attr, DataLoader.MAX_FILE_BYTES)
    end
    local file = io.open(path, "r")
    if not file then return nil, "unreadable" end
    local raw_text = file:read(DataLoader.MAX_FILE_BYTES + 1)
    file:close()
    if type(raw_text) ~= "string" then return nil, "unreadable" end
    -- Re-check after reading: the file may have grown between stat and read.
    if #raw_text > DataLoader.MAX_FILE_BYTES then
        return nil, string.format("file too large (%d bytes, limit %d)",
            #raw_text, DataLoader.MAX_FILE_BYTES)
    end
    return raw_text, nil
end
DataLoader.readBounded = readBounded

--- Load a data-only Lua file and return its table.
--- Returns table, nil on success; nil, err on any failure.
function DataLoader.loadTable(path)
    if type(path) ~= "string"
            or lfs.attributes(path, "mode") ~= "file" then
        return nil, "not a file"
    end
    local raw_text, read_err = readBounded(path)
    if not raw_text then return nil, read_err end

    local chunk, load_err = loadstring(raw_text, "@" .. path)
    if not chunk then return nil, tostring(load_err) end
    if setfenv then setfenv(chunk, RESTRICTED_ENV) end
    -- Make the instruction budget enforceable: count hooks do not fire in
    -- JIT-traced code, so exclude this chunk - and every function nested in
    -- it (a `return (function() while true do end end)()` payload otherwise
    -- escapes the budget entirely) - from tracing. The recursive flag is
    -- what matters: measured on this runtime, plain jit.off(chunk) only
    -- protects loops living directly in the main chunk, and machine-wide
    -- jit.off(true, true) does NOT make hooks fire at all. The hook is
    -- process-global state; it is removed again before every return below.
    if jit and jit.off then pcall(jit.off, chunk, true) end
    local consumed = 0
    local interval = math.max(1, DataLoader.EXEC_HOOK_INTERVAL or 1000)
    debug.sethook(function()
        consumed = consumed + interval
        if consumed > (DataLoader.EXEC_BUDGET or 0) then
            error("data loader: execution budget exceeded "
                .. tostring(consumed) .. " instructions", 0)
        end
    end, "", interval)

    local ok, loaded = pcall(chunk)
    debug.sethook()

    if not ok then return nil, tostring(loaded) end
    if type(loaded) ~= "table" then
        return nil, "payload is " .. type(loaded) .. ", expected table"
    end
    return loaded, nil
end

--- pcall(dofile, path)-shaped drop-in for historical call sites.
--- Returns the table or nil (logging the reason once, like readNativeOrder did).
function DataLoader.loadTableLogged(path, what)
    local data, err = DataLoader.loadTable(path)
    if not data then
        logger.warn("ReorderingMenus: cannot load", what or "data file",
            tostring(path), "-", tostring(err))
    end
    return data
end

return DataLoader

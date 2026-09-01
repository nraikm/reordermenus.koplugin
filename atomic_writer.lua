--[[--
atomic_writer.lua — crash-safe Lua-table persistence (atomic file replacement).

Every persisted file this plugin produces (canonical intent, derived native
orders, noncanonical sidecars) goes through the same pipeline:

    serialize -> temp file in the destination directory
              -> load/parse the temp file back
              -> validate the returned shape
              -> atomic rename over the destination

Persistence Guarantee:
  * Atomic File Replacement: POSIX os.rename replaces the destination
    atomically. The destination path always holds either the previous complete
    file or the new complete file — never a truncated or half-written document.
    Stock KOReader parses these files with unprotected dofile(), so this
    guarantee protects against process termination, crash-loops, and syntax
    corruption.
  * Power-Loss Durability: True durability across sudden hardware power loss /
    kernel panic requires filesystem-level fsync / fdatasync, which is not
    exposed in standard Lua standard I/O in the KOReader environment. This
    mechanism provides crash-safe atomic file replacement, not a multi-file
    power-loss journal.
--]]

local dump = require("dump")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local AtomicWriter = {}

local seq = 0

-- -------------------------------------------------------------------------
-- Deterministic serialization (P1B): KOReader's `dump` walks plain pairs(),
-- so equivalent tables can serialize byte-differently across processes
-- (LuaJIT hash seeds). Preset envelopes must be reproducible: the same
-- semantic state always writes identical bytes, whatever inserted the keys.
-- Every key is emitted bracketed and sorted (numbers before strings by
-- tostring); arrays therefore keep their order, maps their sorted identity.
-- -------------------------------------------------------------------------

local function serialize_value(value, out, seen)
    local t = type(value)
    if t == "nil" then
        out[#out + 1] = "nil"
    elseif t == "boolean" or t == "number" then
        out[#out + 1] = tostring(value)
    elseif t == "string" then
        out[#out + 1] = string.format("%q", value)
    elseif t == "table" then
        for i = 1, #seen do
            if seen[i] == value then
                error("atomic-writer: cannot deterministically serialize loops")
            end
        end
        seen[#seen + 1] = value
        local keys = {}
        for key in pairs(value) do
            keys[#keys + 1] = key
        end
        table.sort(keys, function(a, b)
            local ta, tb = type(a), type(b)
            if ta ~= tb then return ta < tb end
            return tostring(a) < tostring(b)
        end)
        out[#out + 1] = "{"
        for i, key in ipairs(keys) do
            if i > 1 then out[#out + 1] = "," end
            out[#out + 1] = "["
            serialize_value(key, out, seen)
            out[#out + 1] = "]="
            serialize_value(value[key], out, seen)
        end
        out[#out + 1] = "}"
        seen[#seen] = nil
    else
        error("atomic-writer: cannot serialize value of type " .. t)
    end
end

--- Deterministic body for a table: identical semantic state yields
--- byte-identical output regardless of key insertion order or hash seed.
function AtomicWriter.serializeSorted(tbl)
    local out = {}
    serialize_value(tbl, out, {})
    return table.concat(out)
end

local function temporaryPath(dir, base)
    seq = seq + 1
    -- Destination bytes are deterministic; the staging filename does not
    -- need to be. A per-call token prevents two KOReader processes from
    -- selecting the same temporary file after both observe it as absent.
    local identity = tostring({}):gsub("[^%w]", "")
    return string.format("%s/.%s.tmp.%d_%d_%s", dir, base,
        os.time(), seq, identity)
end

-- Write `tbl` as a dofile-ready Lua file at `path`, atomically.
-- `validate` (optional) is a function(table) -> truthy checking the parsed
-- shape before the rename commits. `opts` (optional): { sorted = true }
-- serializes with deterministic sorted keys instead of KOReader's `dump`
-- (preset envelopes use this so equivalent state writes identical bytes).
-- Returns true, path or false, err.
function AtomicWriter.writeTable(path, tbl, validate, opts)
    if type(path) ~= "string" or type(tbl) ~= "table" then
        return false, "atomic write needs a path and a table"
    end
    local dir = path:match("^(.*)/[^/]+$") or "."
    local base = path:match("([^/]+)$") or "file"
    local tmp = temporaryPath(dir, base)

    -- util.writeToFile normally embeds the path it writes to in the Lua-file
    -- header. Compose that wrapper ourselves with the stable DESTINATION path
    -- so unique staging names do not make identical states byte-different.
    local payload
    if opts and opts.sorted then
        payload = AtomicWriter.serializeSorted(tbl)
    else
        payload = dump(tbl, nil, true)
    end
    local body = table.concat({
        "-- ", path, "\nreturn ", payload, "\n",
    })
    local ok_write, err_write = util.writeToFile(body,
        tmp, true, false, true)
    if not ok_write then
        pcall(os.remove, tmp)
        logger.warn("ReorderingMenus: atomic write failed staging", path, err_write)
        return false, err_write
    end

    -- Parse the staged copy back before touching the destination.
    local chunk, load_err = loadfile(tmp)
    if not chunk then
        pcall(os.remove, tmp)
        logger.warn("ReorderingMenus: staged file failed to parse,", path, load_err)
        return false, "staged file does not parse"
    end
    local ok_run, res = pcall(chunk)
    if not ok_run or type(res) ~= "table"
            or (validate and not validate(res)) then
        pcall(os.remove, tmp)
        logger.warn("ReorderingMenus: staged file failed validation,", path)
        return false, "staged file failed validation"
    end

    -- POSIX rename replaces an existing destination atomically. Do not unlink
    -- `path` first: doing so creates a crash window where no valid destination
    -- exists and also destroys the previous file when rename fails.
    local ok_rename, rename_err = os.rename(tmp, path)
    if not ok_rename then
        pcall(os.remove, tmp)
        logger.warn("ReorderingMenus: atomic rename failed for", path, rename_err)
        return false, rename_err or "rename failed"
    end
    return true, path
end

-- True when the file exists on disk (readable or not).
function AtomicWriter.fileExists(path)
    return lfs.attributes(path, "mode") == "file"
end

return AtomicWriter

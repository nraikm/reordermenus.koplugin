--[[--
atomic_writer.lua — crash-safe Lua-table persistence.

Every persisted file this plugin produces (canonical intent, derived native
orders, noncanonical sidecars) goes through the same pipeline:

    serialize -> temp file in the destination directory
              -> load/parse the temp file back
              -> validate the returned shape
              -> atomic rename over the destination

The destination therefore always holds either the previous complete file or
the new complete file - never a truncated half-Lua document. Stock KOReader
parses these files with unprotected dofile(), so a partial write would take
the whole menu system down on the next startup.

This is crash-safe file replacement, not a cross-process locking protocol.
--]]

local dump = require("dump")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local AtomicWriter = {}

local seq = 0

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
-- shape before the rename commits. Returns true, path or false, err.
function AtomicWriter.writeTable(path, tbl, validate)
    if type(path) ~= "string" or type(tbl) ~= "table" then
        return false, "atomic write needs a path and a table"
    end
    local dir = path:match("^(.*)/[^/]+$") or "."
    local base = path:match("([^/]+)$") or "file"
    local tmp = temporaryPath(dir, base)

    -- util.writeToFile normally embeds the path it writes to in the Lua-file
    -- header. Compose that wrapper ourselves with the stable DESTINATION path
    -- so unique staging names do not make identical states byte-different.
    local body = table.concat({
        "-- ", path, "\nreturn ", dump(tbl, nil, true), "\n",
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

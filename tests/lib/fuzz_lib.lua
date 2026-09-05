--[[--
fuzz_lib.lua — shared infrastructure for interaction fuzzing suites.

Provides:
  * boot()            — KOReader environment bootstrap (call once per process)
  * fresh_world()     — wipe persisted menu state, return live modules
  * SemanticFP        — canonical semantic fingerprint of a projection
  * intent_bytes      — deterministic serialization of an intent section
  * deep_eq           — value-equality for plain tables
  * SortedPairs       — deterministic iteration helper
  * UNICODE_POOLS etc — adversarial label/id corpora (§I/J/X)

All new suites share this so failure reports stay comparable across areas.
--]]

local FuzzLib = {}

function FuzzLib.boot(project_dir)
    local koreader_dir = os.getenv("KOREADER_DIR") or "/Applications/KOReader.app/Contents/koreader"
    dofile(koreader_dir .. "/setupkoenv.lua")
    assert(project_dir, "FuzzLib.boot needs the plugin directory")
    package.path = project_dir .. "/?.lua;" .. package.path

    local LuaSettings = require("luasettings")
    local DataStorage = require("datastorage")
    G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir()
        .. "/settings.reader.lua")
    G_defaults = require("luadefaults"):open()
    local Device = require("device")
    local CanvasContext = require("document/canvascontext")
    CanvasContext:init(Device)
    local _ = require("gettext")
    require("main")
    return project_dir
end

local VIEWS = { "reader", "filemanager" }
FuzzLib.VIEWS = VIEWS

-- Wipe every persisted artifact the plugin owns (fresh-process equivalent).
function FuzzLib.fresh_world(opts)
    opts = opts or {}
    local DataStorage = require("datastorage")
    local KoreaderAdapter = require("lib.koreader_adapter")
    local IntentStore = require("lib.intent_store")
    local Manager = require("lib.menuorder_manager")
    local lfs = require("libs/libkoreader-lfs")

    local sd = DataStorage:getSettingsDir()
    local names = {
        "reader_menu_order.lua", "filemanager_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua",
        "reorderingmenus_state.lua",
    }
    for _, name in ipairs(names) do pcall(os.remove, sd .. "/" .. name) end

    local function rmtree(path)
        if lfs.attributes(path, "mode") ~= "directory" then return end
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                local full = path .. "/" .. entry
                if lfs.attributes(full, "mode") == "directory" then
                    rmtree(full)
                else
                    pcall(os.remove, full)
                end
            end
        end
        pcall(lfs.rmdir, path)
    end
    if not opts.keep_presets then
        rmtree(sd .. "/menu_order_presets")
    end

    for _, v in ipairs(VIEWS) do
        pcall(function() os.remove(KoreaderAdapter.getNativePath(v)) end)
        Manager:resetOrder(v)
        Manager:dropSessionState(v)
    end
    IntentStore.load(true)
end

-- Stable semantic fingerprint of a projection: per-menu ordered ids,
-- hidden set, tab order. Hash-order independent by construction.
function FuzzLib.semantic_fp(view, Manager)
    local order = Manager:loadOrder(view)
    local parts = {}
    local keys = {}
    for k in pairs(order) do table.insert(keys, k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local val = order[k]
        if type(val) == "table" then
            table.insert(parts, k .. "=" .. table.concat(val, ">"))
        else
            table.insert(parts, k .. "=" .. tostring(val))
        end
    end
    return table.concat(parts, "|")
end

-- Deterministic byte serialization of a plain table (sorted keys).
-- Used for byte-identical comparison where intended (§E).
local function ser(value, indent)
    indent = indent or ""
    local t = type(value)
    if t == "nil" then return "nil"
    elseif t == "boolean" then return tostring(value)
    elseif t == "number" then return string.format("%.17g", value)
    elseif t == "string" then
        return string.format("%q", value):gsub("\\\n", "\\n")
    elseif t == "table" then
        -- detect array part
        local n = #value
        local parts = {}
        for i = 1, n do parts[#parts + 1] = ser(value[i], indent .. " ") end
        local keys = {}
        for k in pairs(value) do
            if not (type(k) == "number" and k % 1 == 0 and k >= 1 and k <= n) then
                keys[#keys + 1] = k
            end
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = "[" .. ser(k, indent .. " ") .. "]="
                .. ser(value[k], indent .. " ")
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    error("unserializable type " .. t)
end

--- Byte-serialize any acyclic plain-data table deterministically.
function FuzzLib.intent_bytes(value)
    return ser(value)
end

FuzzLib.serialize = ser

--- Value equality for plain tables (recursive, cycle-free).
function FuzzLib.deep_eq(a, b, depth)
    depth = depth or 0
    if depth > 60 then return false end
    if a == b then return true end
    local ta, tb = type(a), type(b)
    if ta ~= tb then return false end
    if ta ~= "table" then return false end
    local n = 0
    for k, v in pairs(a) do
        n = n + 1
        if not FuzzLib.deep_eq(v, b[k], depth + 1) then return false end
    end
    for _ in pairs(b) do
        n = n - 1
        if n < 0 then return false end
    end
    return n == 0
end

-- ---------------------------------------------------------------------
-- Adversarial corpora (§I serialization torture, §J unicode ids, §X locale)
-- ---------------------------------------------------------------------
FuzzLib.NASTY_FRAGMENTS = {
    ['dq']     = '"',
    ['sq']     = "'",
    ['bs']     = '\\',
    ['nl']     = "\n",
    ['tab']    = "\t",
    ['lb']     = "[[",
    ['rb']     = "]]",
    ['lbrb']   = "]] ]] [[",
    ['brace']  = "{}",
    ['ret']    = "return",
    ['cmt']    = "--]]",
    ['cmt2']   = "--[==[",
    ['emoji']  = "🚀📚",
    ['rtl']    = "عربى עברית",
    ['comb']   = "e\u{0301}\u{0327}",
    ['zwj']    = "👩\u{200D}💻",
    ['punct']  = "%s+(.-)$%^$#",
}

FuzzLib.UNICODE_IDS = {
    "café",                    -- precomposed é
    "cafe\u{0301}",            -- decomposed e + combining accent
    "قائمة",                   -- Arabic
    "תפריט",                   -- Hebrew
    "菜单設定",                 -- CJK
    "🚀rocket📚",              -- emoji
    "with space",
    "semi;colon",
    "amp&and",
    "eq=uals",
    "slash/path",
    "back\\slash",
    "UPPER", "upper",
    "Ünïcödé",
}

FuzzLib.LOCALE_LABELS = {
    { id = "x_a", title = "A" },
    { id = "x_aring", title = "Å" },
    { id = "x_adia", title = "Ä" },
    { id = "x_odia", title = "Ö" },
    { id = "x_eac", title = "É" },
    { id = "x_elow", title = "e" },
    { id = "x_eacc2", title = "é" },
    { id = "x_sharp", title = "ß" },
    { id = "x_cjk", title = "中" },
    -- deliberate duplicates to force tie-breaking
    { id = "x_dup1", title = "Same" },
    { id = "x_dup2", title = "Same" },
    { id = "x_dup3", title = "same" },
    -- pathological lengths / whitespace
    { id = "x_long", title = string.rep("L4k", 1333) .. "L" },  -- ~4k chars
    { id = "x_ws", title = " \t " },
    { id = "x_empty", title = "" },
}

--- Seeded PRNG (deterministic across LuaJIT builds; avoids math.random
--- state coupling between suites sharing a process).
function FuzzLib.rng(seed)
    local s = seed % 2147483647
    if s <= 0 then s = s + 2147483646 end
    return function(lo, hi)
        s = (s * 16807) % 2147483647
        if lo then
            hi = hi or lo
            lo = 1
            return lo + (s % (hi - lo + 1))
        end
        return s / 2147483647
    end
end

return FuzzLib

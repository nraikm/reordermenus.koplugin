--[[--
plugin_prefs.lua — ORDINARY plugin preferences (never layout intent).

Canonical menu layout lives exclusively in the P0 intent store. A few
operational toggles are NOT layout state:

  - which BUILT-IN presets the user hid from the picker
  - how hidden rows are presented in editors (in place vs bottom)
  - whether cross-view mirroring is enabled        (see note)

They are ordinary KOReader plugin preferences: they ride G_reader_settings,
persist through the normal settings lifecycle, and never enter the
canonical transaction, the native emission, or preset envelopes.

Note on mirroring: the toggle currently keeps one foot in canonical meta
because its Save/Discard coupling is a pinned P0 contract
(test_p0_editor_consistency). This module exposes the storage so a later
product decision can move it wholesale; the layout-intent boundary above
is the rule this lane enforces today.
--]]

local logger = require("logger")

local Prefs = {}

local NAMESPACE = "reorderingmenus"

local function settings()
    return G_reader_settings
end

--- Flush through the host lifecycle. Safe to call anywhere; cheap when the
--- settings framework batches writes anyway.
function Prefs.flush()
    local s = settings()
    if s and s.flush then pcall(function() s:flush() end) end
    return true
end

function Prefs.get(key, default)
    local s = settings()
    if not s then return default end
    local ns = s:readSetting(NAMESPACE)
    if type(ns) ~= "table" then return default end
    local v = ns[key]
    if v == nil then return default end
    return v
end

function Prefs.set(key, value)
    local s = settings()
    if not s then return false end
    local ns = s:readSetting(NAMESPACE)
    if type(ns) ~= "table" then
        ns = {}
        s:saveSetting(NAMESPACE, ns)
    end
    ns[key] = value
    return true
end

-- -------------------------------------------------------------------------
-- Hidden built-in presets, per view: array of builtin preset ids.
-- Legacy source: ".hidden_builtins.lua" inside the view's preset directory
-- (a file the OLD architecture wrote next to presets). Imported once per
-- process, then removed - the setting, not a preset-dir artifact, is the
-- single storage from here on.
-- -------------------------------------------------------------------------

function Prefs.hiddenBuiltinsKey(view)
    return "hidden_builtins_" .. tostring(view)
end

--- Import the legacy per-view hidden-builtins file when it exists.
--- Cheap no-op otherwise (one stat). Returns true when a migration
--- happened (caller may flush).
function Prefs.importLegacyHiddenBuiltins(view, legacy_path, loader)
    if type(legacy_path) ~= "string" then return false end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(legacy_path, "mode") ~= "file" then return false end
    local DataLoader = require("reorderingmenus_data_loader")
    local load_fn = type(loader) == "function" and loader or DataLoader.loadTable
    local data = load_fn(legacy_path)
    if type(data) ~= "table" then
        os.remove(legacy_path)
        return false
    end
    local ids = {}
    for _, id in ipairs(data) do
        if type(id) == "string" then table.insert(ids, id) end
    end
    -- Merge into whatever the setting already holds (idempotent union).
    local current = Prefs.get(Prefs.hiddenBuiltinsKey(view), {})
    local seen = {}
    for _, id in ipairs(current) do seen[id] = true end
    for _, id in ipairs(ids) do
        if not seen[id] then
            table.insert(current, id)
            seen[id] = true
        end
    end
    local ok_set = Prefs.set(Prefs.hiddenBuiltinsKey(view), current)
    Prefs.flush()
    if ok_set then
        os.remove(legacy_path)
        logger.info("ReorderingMenus: imported hidden-builtin preference for",
            view, "(#", #ids, ") into plugin settings")
        return true
    end
    return false
end

function Prefs.getHiddenBuiltins(view)
    return Prefs.get(Prefs.hiddenBuiltinsKey(view), {})
end

function Prefs.setHiddenBuiltins(view, ids)
    local clean = {}
    for _, id in ipairs(type(ids) == "table" and ids or {}) do
        if type(id) == "string" then table.insert(clean, id) end
    end
    Prefs.set(Prefs.hiddenBuiltinsKey(view), clean)
end

return Prefs

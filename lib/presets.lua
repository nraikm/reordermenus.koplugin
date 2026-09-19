--[[--
presets.lua — snapshots and merging of INTENT, not runtime menu arrays.

A preset captures what the user did (sparse intent records), never the fully
resolved menu. Applying one therefore keeps working across KOReader/plugin
updates: whatever the snapshot does not mention continues to follow the
current defaults, and entries that appeared after the snapshot are kept.

Formats:
  v2 view preset     : format = "reorderingmenus_intent_preset", version 2,
                       carries a sparse intent section for one view
  v2 submenu preset  : format = "reorderingmenus_submenu_preset", version 2,
                       carries per-menu sequences plus created-submenu titles
  legacy formats     : dense order tables with NEITHER a format nor a version
                       field; they are converted against the CURRENT defaults
                       on load

Version admission policy (enforced BEFORE anything is applied):

  current version            -> loads
  older supported version    -> migrated stepwise, then loads
  newer/future version       -> REJECTED read-only; the file is never
                                applied, updated, or overwritten, so a
                                downgraded build cannot clobber data written
                                by a newer one
  format marker w/o version  -> rejected (that combination was never written
                                by any released build; treating it as legacy
                                dense would misparse an envelope as orders)
  neither field              -> documented legacy-dense policy above

Built-in layouts are code-defined intent fragments resolved against the
running installation at apply time.
--]]

local KoreaderAdapter = require("lib.koreader_adapter")
local AtomicWriter = require("lib.atomic_writer")
local DataLoader = require("lib.data_loader")
local Materializer = require("lib.materializer")
local UnicodeFold = require("lib.unicode_fold")
local PluginPrefs = require("lib.plugin_prefs")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local MenuSchema = require("lib.menu_schema")
local util = require("util")
local bit = require("bit")
local Placement = require("lib.placement")
local _ = require("gettext")

-- Positional translation helper (translators can reorder %1/%2/...).
local T = require("ffi/util").template
-- Plural forms via gettext's ngettext.
local N_ = require("gettext").ngettext

local Presets = {}

local SEPARATOR_ID = MenuSchema.SEPARATOR_ID

-- -------------------------------------------------------------------------
-- Version admission policy
--
-- PRESET_VERSION is the envelope version this build writes. History:
--   (absent)  : pre-envelope dense order tables (no format field either);
--               admitted through the documented legacy-dense migration
--   2         : first versioned envelope ("reorderingmenus_intent_preset" /
--               "reorderingmenus_submenu_preset" + intent/menus payload)
-- A FUTURE declared version is never partially applied: the file stays on
-- disk untouched (read-only rejection) until a build that understands it.
-- -------------------------------------------------------------------------
local PRESET_VERSION = 2

--- Classify a loaded preset table's declared version.
--- Returns "legacy" (no format AND no version: dense orders),
--- "current" (declared version this build supports), or
--- "future" (declared version newer than anything this build knows).
local function classifyPresetVersion(data)
    local declared = tonumber(data and data.version)
    if declared == nil then return "legacy" end
    if declared > PRESET_VERSION then return "future" end
    return "current"
end

--- Gate a preset that carries a format marker through the admission
--- policy. Envelopes MUST declare a supported version: a format marker
--- without a version was written by no released build, so refusing beats
--- misparsing an unknown future envelope as legacy dense orders.
--- Returns true when admissible; nil + message when not.
local function admitVersionedPreset(data, what)
    if data.format ~= nil then
        local class = classifyPresetVersion(data)
        if class == "future" then
            return nil, string.format(
                _("%s was saved by a newer version of ReorderingMenus (format version %s) and cannot be opened here. The file was left unchanged."),
                what or _("This preset"), tostring(data.version))
        end
        if class == "legacy" then
            return nil, string.format(
                _("%s has an unrecognized preset format and cannot be opened."),
                what or _("This preset"))
        end
        if data.version < PRESET_VERSION then
            -- Older SUPPORTED envelope: migrate forward here when a v3+ of
            -- the plugin ever ships; v2 is the oldest versioned envelope,
            -- so nothing to do today beyond admitting it.
            logger.info("ReorderingMenus: admitted older preset version",
                data.version)
        end
    elseif data.version ~= nil then
        -- Version without format: also an envelope-shaped file we do not
        -- know (dense legacy tables carry neither field).
        return nil, string.format(
            _("%s has an unrecognized preset format and cannot be opened."),
            what or _("This preset"))
    end
    return true
end

Presets.admitVersionedPreset = admitVersionedPreset
Presets.PRESET_VERSION = PRESET_VERSION

-- -------------------------------------------------------------------------
-- Paths / names
-- -------------------------------------------------------------------------

local function ensureDir(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    local ok, err = util.makePath(path)
    if not ok then
        return nil, tostring(err or "mkdir failed")
    end
    -- makePath can report success while racing another creator; trust the
    -- filesystem, not the return value alone.
    if lfs.attributes(path, "mode") ~= "directory" then
        return nil, "directory did not exist after creation"
    end
    return true
end

function Presets.getPresetsDir(view)
    -- Pure path resolution: NEVER creates anything. Read-only discovery
    -- (listing presets) works against an absent directory; write paths
    -- call Presets.ensurePresetsDir() explicitly and surface failures.
    local base_dir = string.format("%s/menu_order_presets",
        KoreaderAdapter.getSettingsDir())
    return string.format("%s/%s", base_dir, view)
end

--- Create the view's preset directory tree for a WRITE operation.
--- Returns true, or nil + a user-presentable failure message.
function Presets.ensurePresetsDir(view)
    local base_dir = string.format("%s/menu_order_presets",
        KoreaderAdapter.getSettingsDir())
    local ok, err = ensureDir(base_dir)
    if not ok then return nil, err end
    local view_dir = string.format("%s/%s", base_dir, view)
    local ok2, err2 = ensureDir(view_dir)
    if not ok2 then return nil, err2 end
    return true
end

-- The LEGACY component sanitizer (kept ONLY for one-time migration of
-- directories written by older builds).
local function legacyPathComponent(value)
    local clean_value = tostring(value or ""):gsub("[^%w_%-]", "_")
    return clean_value ~= "" and clean_value or "submenu"
end

-- Collision-free submenu-preset directory identity.
--
-- The historical sanitizer mapped every non-[w-] byte to "_", so distinct
-- menu ids could collapse onto one component ("plugin:tools" vs
-- "plugin.tools") and silently SHARE one preset storage - each id seeing
-- (and deleting/overwriting) the other's files. Identity is now
-- "<readable prefix>--<hash>" where the hash is a stable digest of the
-- EXACT id (FNV-1a 32-bit twice = 64 bits): deterministic across runs,
-- processes and platforms, bounded length regardless of id length, and
-- collision-resistant far beyond any realistic menu population (2^64).
local function fnv1a32(str, seed)
    -- LuaJIT (Lua 5.1) has no `~` xor operator; use the bit library.
    -- Semantics preserved: 32-bit FNV-1a with wrap-around multiplication.
    local band, bxor = bit.band, bit.bxor
    local h = bxor(seed or 2166136261, 0)
    for i = 1, #str do
        h = bxor(h, str:byte(i))
        h = band(h * 16777619, 0xFFFFFFFF)
    end
    return h
end

local function submenuDirComponent(menu_id)
    menu_id = tostring(menu_id or "")
    local readable = menu_id:gsub("[^%w_%-]", ""):sub(1, 40)
    if readable == "" then readable = "menu" end
    local h1 = fnv1a32(menu_id)
    local h2 = fnv1a32(menu_id, 4294967295 - h1)
    return string.format("%s--%08x%08x", readable, h1, h2)
end

Presets.submenuDirComponent = submenuDirComponent

-- One-time migration per (view, menu_id): a legacy sanitized directory
-- moves to its hashed identity so two previously-colliding ids stop
-- sharing storage. The rename happens only when the target does not yet
-- exist; when two legacy ids truly collided, the first id seen migrates
-- the shared directory and the second keeps working in place (its files
-- are never deleted or overwritten - corruption preservation applies to
-- presets too), and both ids remain reachable through their own dirs.
local submenu_migration_done = {}
local function migrateLegacySubmenuDir(root_dir, view, menu_id)
    local key = view .. "/" .. tostring(menu_id)
    if submenu_migration_done[key] then return end
    submenu_migration_done[key] = true
    local legacy = string.format("%s/%s", root_dir,
        legacyPathComponent(menu_id))
    local target = string.format("%s/%s", root_dir,
        submenuDirComponent(menu_id))
    if legacy == target then return end
    if lfs.attributes(legacy, "mode") ~= "directory" then return end
    if lfs.attributes(target, "mode") == "directory" then return end
    local ok, err = os.rename(legacy, target)
    if ok then
        logger.info("ReorderingMenus: migrated submenu preset directory to",
            target)
    else
        logger.warn("ReorderingMenus: could not migrate submenu preset dir",
            legacy, "-", tostring(err))
    end
end

--- Resolve the per-menu preset directory WITHOUT creating or modifying anything.
--- Returns the directory when it exists, or nil when absent.
function Presets.findSubmenuPresetsDir(view, menu_id)
    local root_dir = string.format("%s/submenus", Presets.getPresetsDir(view))
    local menu_dir = string.format("%s/%s", root_dir,
        submenuDirComponent(menu_id))
    if lfs.attributes(menu_dir, "mode") == "directory" then return menu_dir end
    local legacy = string.format("%s/%s", root_dir,
        legacyPathComponent(menu_id))
    if legacy and lfs.attributes(legacy, "mode") == "directory" then
        return legacy
    end
    return nil
end

--- Resolve AND create the per-menu preset directory for a WRITE operation.
--- Returns the directory path, or nil + failure message.
function Presets.ensureSubmenuPresetsDir(view, menu_id)
    local ok, err = Presets.ensurePresetsDir(view)
    if not ok then return nil, err end
    local root_dir = string.format("%s/submenus", Presets.getPresetsDir(view))
    local ok_root, err_root = ensureDir(root_dir)
    if not ok_root then return nil, err_root end
    migrateLegacySubmenuDir(root_dir, view, menu_id)
    local menu_dir = string.format("%s/%s", root_dir,
        submenuDirComponent(menu_id))
    local ok_menu, err_menu = ensureDir(menu_dir)
    if not ok_menu then return nil, err_menu end
    return menu_dir
end

-- P0-8: preset names are VALIDATED IDENTIFIERS, not paths. Anything that
-- is not a plain single-component name (letters, digits, space, dash,
-- underscore, dot-run that is not a leading traversal) is REJECTED, never
-- silently transformed: a name like "../foo", "/abs", "a/b" or "foo/../bar"
-- has no business reaching the filesystem at all. Rejection over
-- transformation means no normalization ambiguity (repeated separators,
-- Unicode confusables, case tricks, sibling-prefix escapes) can ever turn a
-- "cleaned" name into an escape.
local function cleanPresetName(preset_name)
    if type(preset_name) ~= "string" or preset_name:match("^%s*$") then
        return nil, _("Preset name cannot be empty.")
    end
    if #preset_name > 200 then
        return nil, _("Preset name is too long.")
    end
    -- Structural rejections FIRST: separators and traversal in any form.
    if preset_name:find("[/\\]", 1, true) then
        return nil, _("Preset name cannot contain path separators.")
    end
    if preset_name:match("^%s*%.+%.-%s*$") then
        return nil, _("Invalid preset name.")
    end
    -- Allow-list: word characters, space, dash, underscore, dot.
    -- (Trailing/leading whitespace is tolerated but trimmed; everything the
    -- old sanitizer would have silently replaced - emoji, quotes, semicolons,
    -- control characters - is refused.)
    local trimmed = preset_name:match("^%s*(.-)%s*$")
    if trimmed == "" or not trimmed:match("^[%w%-%_%. %u%l]+$") then
        return nil, _("Invalid preset name.")
    end
    return trimmed
end

--- P0-8: resolve a preset FILENAME against a known directory without any
--- escape possibility. The name must already be a validated identifier;
--- the returned path is always dir .. "/" .. name .. suffix by construction.
local function presetPathIn(dir, clean_name)
    return string.format("%s/%s.lua", dir, clean_name)
end

-- Case-insensitive collision check. On case-insensitive filesystems (macOS,
-- Windows) saving "Tools.lua" silently overwrites "tools.lua"; refusing the
-- near-collision keeps presets from destroying each other.
-- Folded with KOReader's Unicode convention (Utf8Proc.lowercase after
-- fixUtf8) so e.g. "École" and "ecole" variants are caught too, not just
-- ASCII case. Comparison is display-level only: files keep their exact
-- names on disk.
local function findCaseInsensitiveCollision(view, file_path, own_name)
    local dir = Presets.getPresetsDir(view)
    if not lfs.attributes(dir) then return nil end
    local lower_own = UnicodeFold.key(own_name)
    for entry in lfs.dir(dir) do
        if entry:sub(-4) == ".lua" then
            local stem = entry:sub(1, -5)
            if UnicodeFold.key(stem) == lower_own then
                local full = dir .. "/" .. entry
                -- Same resolved file is fine (overwrite of itself); any other
                -- case-variant is a collision.
                if full ~= file_path then return full end
            end
        end
    end
    return nil
end

-- -------------------------------------------------------------------------
-- Built-in presets: intent fragments resolved against current defaults
-- -------------------------------------------------------------------------

local BUILTIN_FRAGMENTS = {
    reader = {
        {
            id = "builtin_reading_focused",
            name = _("Reading Focused"),
            description = _("Puts Typeset and Navigation first; hides Search, Main, and Filemanager."),
            tab_order = { "typeset", "navi", "setting", "tools" },
            hidden_tabs = { "filemanager", "main", "search" },
        },
        {
            id = "builtin_minimalist",
            name = _("Minimalist Reader"),
            description = _("Keeps only Navigation and Typeset tabs for a distraction-free experience."),
            tab_order = { "navi", "typeset" },
            hidden_tabs = { "setting", "tools", "search", "filemanager", "main" },
        },
        {
            id = "builtin_power_user",
            name = _("Full Power User"),
            description = _("All tabs and submenus exposed with Search in the first position."),
            tab_order = { "search", "navi", "typeset", "setting", "tools", "filemanager", "main" },
            hidden_tabs = {},
        },
    },
    filemanager = {
        {
            id = "builtin_clean_fm",
            name = _("Clean File Manager"),
            description = _("Essential browsing and device tools without clutter."),
            tab_order = { "filemanager_settings", "setting", "tools" },
            hidden_tabs = { "search", "filemanager", "main" },
        },
        {
            id = "builtin_power_user",
            name = _("Full Power User"),
            description = _("All tabs and submenus visible."),
            tab_order = nil,
            hidden_tabs = {},
        },
    },
}

local BUILTIN_PRESETS_CACHE = nil

local function buildBuiltinPresets()
    -- Memoized once per process: the descriptors are immutable metadata
    -- (id/name/description/fragments). Callers that need to mutate a
    -- fragment must copy it (the apply path does).
    if BUILTIN_PRESETS_CACHE then return BUILTIN_PRESETS_CACHE end
    local presets = {
        {
            id = "builtin_default",
            name = _("Default (Stock KOReader)"),
            description = _("Standard factory menu layout. Selecting this empties the config file to restore stock."),
            is_builtin = true,
            is_default = true,
        },
    }
    for _, view in ipairs({ "reader", "filemanager" }) do
        for _, fragment in ipairs(BUILTIN_FRAGMENTS[view] or {}) do
            local preset = util.tableDeepCopy(fragment)
            preset.is_builtin = true
            preset.view = view -- P1B: explicit compatibility tag for ingress
            table.insert(presets, preset)
        end
    end
    BUILTIN_PRESETS_CACHE = presets
    return presets
end

-- -------------------------------------------------------------------------
-- User view presets
-- -------------------------------------------------------------------------

function Presets.parseUserPresetDescriptor(preset)
    local is_builtin = false
    local raw_name
    if type(preset) == "table" then
        is_builtin = preset.is_builtin == true
            or (type(preset.id) == "string" and preset.id:sub(1, 8) == "builtin_")
        raw_name = preset.name
            or (type(preset.path) == "string" and preset.path:match("([^/]+)%.lua$"))
    elseif type(preset) == "string" then
        raw_name = preset
    end
    if is_builtin then
        return nil, _("Built-in presets cannot be updated."), true
    end
    if not raw_name or raw_name == "" then
        return nil, _("Preset not found."), false
    end
    local clean_name, name_err = cleanPresetName(raw_name:gsub("^user_", ""))
    if not clean_name then
        return nil, name_err, false
    end
    return clean_name, nil, false
end

function Presets.saveViewPreset(view, preset_name, intent_section)
    local clean_name, name_err = cleanPresetName(preset_name)
    if not clean_name then return false, name_err end
    -- Directory creation is a WRITE-time concern: its failure is a normal,
    -- presentable result (full disk, read-only storage, path squatted by a
    -- file), not something to discover later via a failed file open.
    local ok_dir, dir_err = Presets.ensurePresetsDir(view)
    if not ok_dir then
        return false, T(_("Could not create preset storage: %1"), dir_err)
    end
    local file_path = string.format("%s/%s.lua", Presets.getPresetsDir(view), clean_name)
    local collision = findCaseInsensitiveCollision(view, file_path, clean_name)
    if collision then
        return false, string.format(
            _("A preset named \"%s\" already exists (name differs only in letter case)."),
            collision:match("([^/]+)%.lua$"))
    end
    local data = {
        format = "reorderingmenus_intent_preset",
        version = 2,
        name = clean_name,
        view = view,
        intent = util.tableDeepCopy(intent_section),
    }
    -- Deterministic envelope bytes: equivalent semantic state always
    -- serializes identically (P1B), whatever order keys were built in.
    local ok, err = AtomicWriter.writeTable(file_path, data, nil,
        { sorted = true })
    if not ok then return false, err end
    return true, file_path
end

function Presets.listUserPresets(view)
    local dir = Presets.getPresetsDir(view)
    local list = {}
    if lfs.attributes(dir) then
        for file in lfs.dir(dir) do
            if file:sub(-4) == ".lua" and file:sub(1, 1) ~= "." then
                local name = file:sub(1, -5)
                table.insert(list, {
                    id = "user_" .. name,
                    name = name,
                    description = _("Custom user preset"),
                    path = string.format("%s/%s", dir, file),
                    is_builtin = false,
                })
            end
        end
    end
    table.sort(list, function(a, b) return UnicodeFold.key(a.name) < UnicodeFold.key(b.name) end)
    return list
end

-- P0-7: preset files are DATA. They load through the restricted loader -
-- a preset file can never execute application code, touch globals, or
-- reach os.execute - and shape validation stays with each caller.
local function readPresetFile(path)
    if type(path) ~= "string" then return nil end
    return DataLoader.loadTable(path)
end

local function removePresetFile(path)
    if type(path) ~= "string" or lfs.attributes(path, "mode") ~= "file" then
        return false, _("Preset file not found.")
    end
    local ok, err = os.remove(path)
    if not ok then return false, err or _("Failed to delete preset file.") end
    return true
end

-- Resolve a preset reference (table/string/builtin id) into
-- { kind = "default"|"builtin"|"user_v2"|"user_file"|"legacy", ... }.
--
-- P0-8: public operations accept preset IDS / validated names - never
-- arbitrary filesystem paths. A table carrying a caller-chosen `path` is
-- refused outright: discovery happens through listUserPresets(), which
-- enumerates the known directory itself, so every user_file resolution is
-- constructed here from a validated name and cannot escape the directory.
-- Built-in lookup is scoped by (view, id): view-local ids (e.g.
-- builtin_power_user exists in BOTH views) must resolve to the requested
-- view's fragment, not to whichever view happens to come first globally.
local function findBuiltin(view, key)
    if type(key) ~= "string" then return nil, nil end
    local cross_view_match
    for _, b in ipairs(buildBuiltinPresets()) do
        if b.id == key or b.name == key then
            if b.is_default then
                return b, nil
            end
            if b.view == view then
                return b, nil
            end
            if cross_view_match == nil then cross_view_match = b end
        end
    end
    return nil, cross_view_match
end

function Presets.resolve(view, preset)
    local preset_type = type(preset)
    local key
    if preset_type == "string" then
        key = preset
    elseif preset_type == "table" then
        key = preset.id
    end
    local builtin_match, cross_view = findBuiltin(view, key)
    builtin_match = builtin_match or cross_view
    if builtin_match then
        -- Built-ins are view-typed for both string IDs and descriptors.
        if builtin_match.view ~= nil and builtin_match.view ~= view then
            return nil, T(
                _("This built-in preset belongs to the %1 layout."),
                builtin_match.view == "reader"
                    and _("Book view") or _("File Manager"))
        end
        return { kind = builtin_match.is_default and "default" or "builtin",
                 fragment = builtin_match }
    end
    if preset_type == "string" then
        local clean_name, name_err = cleanPresetName(
            preset:gsub("^user_", ""))
        if not clean_name then return nil, name_err end
        return { kind = "user_file", path = presetPathIn(
            Presets.getPresetsDir(view), clean_name) }, preset
    elseif preset_type == "table" then
        if preset.intent then
            -- P1B: an in-memory envelope may declare its origin view; honor
            -- the same compatibility gate as file-borne presets.
            local compatible, err = Presets.checkViewCompatibility(view, preset)
            if not compatible then return nil, err end
            return { kind = "user_v2", data = preset }
        end
        -- A table without intent whose only payload is a PATH is no longer
        -- accepted: paths are not identifiers. Callers must pass either an
        -- enumerated preset descriptor (name/id + data) or a name string.
        if preset.path and not preset.name then
            return nil, _("Preset paths are not accepted; use a preset name.")
        end
        if type(preset.name) == "string" then
            local clean_name, name_err = cleanPresetName(
                preset.name:gsub("^user_", ""))
            if not clean_name then return nil, name_err end
            return { kind = "user_file", path = presetPathIn(
                Presets.getPresetsDir(view), clean_name), name = preset.name }
        end
        -- In-memory dense table (tests, legacy callers).
        return { kind = "legacy_dense", dense = preset }
    end
    return nil, _("Preset not found.")
end

function Presets.readUserPreset(path)
    -- Version-aware read used by apply flows: an envelope this build cannot
    -- admit (future version, unknown format/version shape) reads as NIL so
    -- callers report failure instead of partially applying or misparsing it
    -- through the legacy-dense migration path.
    local data = readPresetFile(path)
    if type(data) == "table" and data.format ~= nil then
        local admissible = admitVersionedPreset(data,
            tostring(path):match("([^/]+)%.lua$") or _("This preset"))
        if not admissible then
            logger.warn("ReorderingMenus: refusing preset with unsupported",
                "format/version:", tostring(path))
            return nil
        end
    end
    return data
end

--- P1B ingress gate (view/type compatibility): a view preset envelope
--- declares the view it was saved from. Applying a reader snapshot to the
--- file manager (or vice versa) would replace one view's canonical records
--- with another's - refuse at the BACKEND so no UI path can bypass it.
--- Legacy dense payloads carry no view field and are admitted (their
--- conversion diffs against the TARGET view's current defaults).
--- Returns nil + user-presentable message on mismatch, true otherwise.
function Presets.checkViewCompatibility(view, data)
    if type(data) ~= "table" then return true end
    local saved_view = data.view
    if saved_view == nil then return true end
    if saved_view ~= view then
        return nil, T(_("This preset was saved for the %1 layout."),
            saved_view == "reader" and _("Book view") or _("File Manager"))
    end
    return true
end

-- Apply a user preset onto a transaction. The snapshot governs everything it
-- mentions; records for ids it has never heard about are carried over so
-- entries added since the save keep their placement and visibility.
function Presets.applyUserIntentPreset(view, txn, preset_intent, reg)
    -- The transaction hands out the live staging table for this view.
    local current = txn:view(view)
    local result = current

    -- P1B: build the preset's ID FOOTPRINT once. Every id the snapshot
    -- mentions - hidden, re-parented, anchored, sequenced, or defining a
    -- custom container - is governed by the preset; everything else is
    -- evaluated for carry-over against this single set instead of re-walking
    -- every stored sequence per candidate record (O(records x entries)
    -- before, O(records + entries) now). Transient: lives for this apply.
    local footprint = {}
    do
        local function mark(id)
            if type(id) == "string" then footprint[id] = true end
        end
        for id in pairs(preset_intent.hidden or {}) do mark(id) end
        for id in pairs(preset_intent.parent_override or {}) do mark(id) end
        for id in pairs(preset_intent.position_override or {}) do mark(id) end
        for id in pairs(preset_intent.custom_menus or {}) do mark(id) end
        for _, record in pairs(preset_intent.order_override or {}) do
            for _, entry in ipairs(type(record) == "table"
                    and record.entries or {}) do
                -- Schema v3: sequence entries are records; separator tokens
                -- report SEPARATOR_ID (never a real id).
                mark(MenuSchema.entryId(entry))
            end
        end
    end

    -- P0-2 footprint for menus: order keys, raw keys, separator parents.
    -- A view preset governs only mentioned menus; ungoverned menus keep
    -- current state verbatim (including stock anchors) so unrelated submenus
    -- survive the apply. Computed early so per-id carry can consult it.
    local governed_menus = {}
    for menu_id in pairs(preset_intent.order_override or {}) do
        governed_menus[menu_id] = true
    end
    for menu_id in pairs(preset_intent.raw_override or {}) do
        governed_menus[menu_id] = true
    end
    for _, sep in pairs(preset_intent.separators or {}) do
        if type(sep) == "table" and type(sep.parent) == "string" then
            governed_menus[sep.parent] = true
        end
    end

    -- Carry-over policy for per-id records (hidden/parent/position):
    -- kept ONLY when the id has no stock default home (plugin/ghost).
    -- Stock ids reset to defaults so presets remain undoable for their
    -- footprint (C1). Per-menu state (order/separators/raw/tab, below) uses
    -- the governed_menus footprint so unrelated submenus survive (P0-2/R2).
    local function carriedOver(id)
        if footprint[id] then return false end
        if reg == nil then return true end   -- legacy callers: keep old behavior
        local node = reg.nodes and reg.nodes[id] or nil
        return node == nil or node.default_parent == nil
    end

    local carried_hidden, carried_parent, carried_position, carried_custom = {}, {}, {}, {}
    for id, record in pairs(current.hidden or {}) do
        if carriedOver(id) then carried_hidden[id] = util.tableDeepCopy(record) end
    end
    for id, record in pairs(current.parent_override or {}) do
        if carriedOver(id) then
            carried_parent[id] = util.tableDeepCopy(record)
        end
    end
    for id, record in pairs(current.position_override or {}) do
        if carriedOver(id) then
            carried_position[id] = util.tableDeepCopy(record)
        end
    end
    for id, custom in pairs(current.custom_menus or {}) do
        carried_custom[id] = util.tableDeepCopy(custom)
    end

    -- Snapshot governs the mentioned surface entirely. Schema v3: hidden
    -- ordering rides each record's ordinal, era stamps ride sequence entries;
    -- there is no hidden_order / sequence_eras to copy.
    result.hidden = util.tableDeepCopy(preset_intent.hidden or {})
    -- Legacy presets may carry a v2-style parallel hide-order list: fold it
    -- into per-record ordinals so the relative order survives the apply.
    local legacy_order = type(preset_intent.hidden_order) == "table"
        and preset_intent.hidden_order or nil
    if legacy_order then
        for index, id in ipairs(legacy_order) do
            local record = result.hidden[id]
            if type(record) == "table" and record.ordinal == nil then
                record.ordinal = index
            end
        end
        local max_seen = 0
        for _, record in pairs(result.hidden) do
            if type(record) == "table" and type(record.ordinal) == "number"
                    and record.ordinal > max_seen then
                max_seen = record.ordinal
            end
        end
        local unnumbered = {}
        for id, record in pairs(result.hidden) do
            if type(record) == "table" and record.ordinal == nil then
                table.insert(unnumbered, id)
            end
        end
        table.sort(unnumbered)
        for _, id in ipairs(unnumbered) do
            max_seen = max_seen + 1
            result.hidden[id].ordinal = max_seen
        end
    end
    -- Records without ANY ordinal (fresh snapshots predating ordering):
    -- assign deterministically by sorted id.
    do
        local unnumbered, max_seen = {}, 0
        for id, record in pairs(result.hidden) do
            if type(record) == "table" then
                if type(record.ordinal) == "number" then
                    if record.ordinal > max_seen then
                        max_seen = record.ordinal
                    end
                else
                    table.insert(unnumbered, id)
                end
            end
        end
        if #unnumbered > 0 then
            table.sort(unnumbered)
            for _, id in ipairs(unnumbered) do
                max_seen = max_seen + 1
                result.hidden[id].ordinal = max_seen
            end
        end
    end
    -- governed_menus computed above for per-id carry; reuse it here for
    -- order/separators/raw verbatim carry of ungoverned menus.
    -- NOTE: result aliases current (same table), so snapshot current state
    -- BEFORE overwriting, otherwise the carry loops would read preset data.
    local cur_order = util.tableDeepCopy(current.order_override or {})
    local cur_seps = util.tableDeepCopy(current.separators or {})
    local cur_raw = util.tableDeepCopy(current.raw_override or {})
    local cur_tab = current.tab_order and util.tableDeepCopy(current.tab_order) or nil
    result.parent_override = util.tableDeepCopy(preset_intent.parent_override or {})
    result.position_override = util.tableDeepCopy(preset_intent.position_override or {})
    result.order_override = util.tableDeepCopy(preset_intent.order_override or {})
    result.separators = util.tableDeepCopy(preset_intent.separators or {})
    -- Symmetric with capture (saveViewPreset stores raw_override verbatim):
    -- opaque levels survive the apply. A level the preset governs semantically
    -- keeps its semantic form; only ungoverned levels carry their raw bytes.
    result.raw_override = util.tableDeepCopy(preset_intent.raw_override or {})
    -- Carry ungoverned order sequences verbatim (P0-2).
    for menu_id, rec in pairs(cur_order) do
        if not governed_menus[menu_id]
                and result.order_override[menu_id] == nil
                and result.raw_override[menu_id] == nil then
            result.order_override[menu_id] = util.tableDeepCopy(rec)
        end
    end
    -- Carry ungoverned separator records verbatim, preserving full divider
    -- semantics (removed / zero_dividers / provider); governed levels keep
    -- only the preset's arrangement.
    for key, sep in pairs(cur_seps) do
        if type(sep) == "table" and type(sep.parent) == "string"
                and not governed_menus[sep.parent]
                and result.separators[key] == nil then
            result.separators[key] = util.tableDeepCopy(sep)
        end
    end
    for menu_id, raw in pairs(cur_raw) do
        if result.raw_override[menu_id] == nil
                and (result.order_override or {})[menu_id] == nil
                and not governed_menus[menu_id] then
            result.raw_override[menu_id] = util.tableDeepCopy(raw)
        end
    end
    -- Raw owns its level exclusively: no semantic sequence or divider
    -- records may survive beside a raw passthrough for the same menu.
    for menu_id in pairs(result.raw_override or {}) do
        if result.order_override then result.order_override[menu_id] = nil end
        for key, sep in pairs(result.separators or {}) do
            if type(sep) == "table" and sep.parent == menu_id then
                result.separators[key] = nil
            end
        end
    end
    -- Tab bar: nil in the preset means "not governed" — keep current bar so
    -- an unrelated or dormant tab arrangement survives the apply (P0-2/P0-3).
    if preset_intent.tab_order ~= nil then
        result.tab_order = util.tableDeepCopy(preset_intent.tab_order)
    else
        result.tab_order = cur_tab and util.tableDeepCopy(cur_tab) or nil
    end
    result.custom_menus = {}
    for id, record in pairs(preset_intent.custom_menus or {}) do
        -- Schema v3: custom-menu placement lives ONLY in parent_override; a
        -- creation-time parent on a legacy snapshot folds in there (the
        -- explicit override still wins when both exist).
        if type(record) == "table" then
            local rec_copy = util.tableDeepCopy(record)
            if type(rec_copy.parent) == "string"
                    and result.parent_override[id] == nil then
                result.parent_override[id] =
                    { provider = nil, parent = rec_copy.parent }
            end
            rec_copy.parent = nil
            result.custom_menus[id] = rec_copy
        end
    end

    -- Created later than the snapshot: keep them alive.
    for id, record in pairs(carried_hidden) do
        if result.hidden[id] == nil then
            result.hidden[id] = record
        end
    end
    for id, record in pairs(carried_parent) do
        result.parent_override[id] = record
    end
    for id, record in pairs(carried_position) do
        result.position_override[id] = record
    end
    for id, custom in pairs(carried_custom) do
        if not result.custom_menus[id] then
            result.custom_menus[id] = custom
        end
    end
    -- Centralized safe migration (single authority with editor + resolve):
    -- legacy presets may carry tab_nesting / unknown_parent / stale parents.
    -- Drop unsupported placements deterministically; the preset file on disk
    -- is untouched so user data stays recoverable. No-op when reg absent
    -- (legacy callers keep old behavior).
    if reg ~= nil then
        local ok_san, report = pcall(function()
            return Placement.sanitizeSection(reg, result)
        end)
        if ok_san and report and (#report.dropped_parents > 0
                or #report.stripped_sequences > 0 or report.tab_order_filtered) then
            logger.warn("ReorderingMenus: view preset migrated unsupported placements:",
                "dropped=" .. table.concat(report.dropped_parents, ","))
        end
    end
end

-- -------------------------------------------------------------------------
-- Submenu presets
-- -------------------------------------------------------------------------

local function collectSubtree(reg, intent, menu_id, include_nested)
    local menus = {}
    local visited = {}
    -- Preset capture reads the EFFECTIVE arrangement (repaired), i.e. what
    -- the user sees — not the pre-validation graph. Single source via Resolver.
    local graph = require("lib.resolver").resolve(reg, intent)

    local function children_of(mid)
        local kids = {}
        local seq = graph.lists[mid] or {}
        for _, id in ipairs(seq) do
            if graph.lists[id] and not visited[id] then
                kids[id] = true
            end
        end
        return kids
    end

    local function visit(mid)
        if visited[mid] then return end
        visited[mid] = true
        local sequence = {}
        for _, id in ipairs(graph.lists[mid] or {}) do
            if id ~= SEPARATOR_ID then table.insert(sequence, id) end
        end
        menus[mid] = {
            sequence = sequence,
        }
        if include_nested then
            for kid in pairs(children_of(mid)) do
                visit(kid)
            end
        end
    end

    visit(menu_id)
    return menus
end

function Presets.saveSubmenuPreset(view, menu_id, menu_title, preset_name,
                                   include_nested, reg, intent, staged_items)
    local clean_name, name_err = cleanPresetName(preset_name)
    if not clean_name then return false, name_err end

    local subtree = collectSubtree(reg, intent, menu_id, include_nested == true)
    if staged_items then
        local seq = {}
        local sep_anchors = {}
        local prev = false
        for _, id in ipairs(staged_items) do
            if id ~= SEPARATOR_ID then
                table.insert(seq, id)
                prev = id
            else
                table.insert(sep_anchors, prev)
            end
        end
        subtree[menu_id] = { sequence = seq, sep_anchors = sep_anchors }
    end
    -- Divider records travel with their menus so a capture reproduces the
    -- exact visual grouping on apply. Full records are preserved verbatim
    -- (removed / zero_dividers / provider), not stripped to parent/after.
    -- When staged_items drives the root capture, its sep_anchors are the sole
    -- divider representation for that level (no second separators copy) so
    -- apply does not duplicate dividers.
    do
        local staged_root = subtree[menu_id] and subtree[menu_id].sep_anchors ~= nil
        for mid in pairs(subtree) do
            if not (staged_root and mid == menu_id) then
                local seps = {}
                for key, sep in pairs(intent.separators or {}) do
                    if type(sep) == "table" and sep.parent == mid then
                        seps[key] = util.tableDeepCopy(sep)
                    end
                end
                subtree[mid].separators = next(seps) and seps or nil
            else
                subtree[mid].separators = nil
            end
        end
    end
    local any = false
    for _, frag in pairs(subtree) do
        if frag.sequence then any = true break end
    end
    if not any then
        subtree[menu_id] = subtree[menu_id] or { sequence = nil }
    end

    local customs = {}
    do
        -- P1B (schema v3): a custom menu's HOME lives in parent_override
        -- (custom_menus.parent was folded away). Capture the container's
        -- placement from there so a restore can re-anchor the top of the
        -- captured subtree; without it the recreated root is unplaced and
        -- its whole subtree cascades into KOMenu:disabled.
        local overrides = intent.parent_override or {}
        for cid, custom in pairs(intent.custom_menus or {}) do
            if subtree[cid] then
                local home_rec = type(overrides[cid]) == "table"
                    and overrides[cid] or nil
                customs[cid] = {
                    title = custom.title,
                    parent = home_rec and home_rec.parent or nil,
                }
            end
        end
    end

    local data = {
        format = "reorderingmenus_submenu_preset",
        version = 2,
        name = clean_name,
        view = view,
        menu_id = menu_id,
        menu_title = menu_title or menu_id,
        include_submenus = include_nested == true,
        menus = subtree,
        custom_menus = customs,
    }
    local menu_dir = Presets.ensureSubmenuPresetsDir(view, menu_id)
    if not menu_dir then
        return false, _("Could not create preset storage for this menu.")
    end
    local file_path = string.format("%s/%s.lua", menu_dir, clean_name)
    local ok, err = AtomicWriter.writeTable(file_path, data, nil,
        { sorted = true })
    if not ok then return false, err end
    return true, file_path
end

-- Submenu-preset listing is deliberately UNCACHED (Prompt 5 §5): the previous
-- (mtime, size) directory-fingerprint memo could serve stale descriptors
-- after an in-place content edit that preserved size and fell inside mtime
-- granularity. Preset files are small and listings are infrequent (picker
-- opens, not redraws); correctness beats the micro-optimization. Always scan.
function Presets.listSubmenuPresets(view, menu_id)
    -- Pure discovery: no directory is created, absent storage = no presets.
    local dir = Presets.findSubmenuPresetsDir(view, menu_id)
    local presets = {}
    if not dir then return presets end
    for file in lfs.dir(dir) do
        if file:sub(-4) == ".lua" and file:sub(1, 1) ~= "." then
            local path = string.format("%s/%s", dir, file)
            local data = DataLoader.loadTable(path)
            if data
                    and data.format == "reorderingmenus_submenu_preset"
                    and admitVersionedPreset(data, file) == true
                    and data.menu_id == menu_id and type(data.menus) == "table" then
                local menu_count = 0
                for _ in pairs(data.menus) do menu_count = menu_count + 1 end
                local nested_count = math.max(0, menu_count - 1)
                table.insert(presets, {
                    id = "submenu_" .. file:sub(1, -5),
                    name = data.name or file:sub(1, -5),
                    description = data.include_submenus
                        and T(N_("Order for this menu and 1 nested menu",
                                 "Order for this menu and %1 nested menus",
                                 nested_count),
                              nested_count)
                        or _("Order for this menu only"),
                    include_submenus = data.include_submenus == true,
                    menu_count = menu_count,
                    path = path,
                })
            end
        end
    end
    table.sort(presets, function(a, b) return UnicodeFold.key(a.name) < UnicodeFold.key(b.name) end)
    return presets
end

-- Load a submenu preset onto the transaction: captured sequences govern;
-- residents that appeared afterwards keep their relative order at the tail.
function Presets.loadSubmenuPreset(view, menu_id, preset_ref, reg, txn, staged_items)
    local data
    local dir = Presets.findSubmenuPresetsDir(view, menu_id)
    if type(preset_ref) == "table" and preset_ref.menus then
        data = util.tableDeepCopy(preset_ref)
    else
        local name_candidate = type(preset_ref) == "table"
            and (preset_ref.name or (preset_ref.path and preset_ref.path:match("([^/]+)%.lua$")))
            or (type(preset_ref) == "string" and preset_ref or nil)
        if not name_candidate or not dir then
            return false, _("Submenu preset not found or does not match this menu.")
        end
        local clean_name, name_err = cleanPresetName(name_candidate:gsub("^submenu_", ""))
        if not clean_name then return false, name_err end
        local expected_path = string.format("%s/%s.lua", dir, clean_name)
        data = readPresetFile(expected_path)
    end
    if type(data) ~= "table" or data.format ~= "reorderingmenus_submenu_preset"
            or data.menu_id ~= menu_id or type(data.menus) ~= "table"
            or not data.menus[menu_id] then
        return false, _("Submenu preset not found or does not match this menu.")
    end
    -- P1B ingress: view compatibility when the envelope declares it.
    local view_ok, view_err = Presets.checkViewCompatibility(view, data)
    if not view_ok then return false, view_err end
    -- Version admission BEFORE anything is applied: a future-versioned
    -- preset is rejected whole (read-only) - never partially merged.
    local admissible, version_err = admitVersionedPreset(data,
        _("This submenu preset"))
    if not admissible then
        return false, version_err
    end

    -- Current residents per affected level come from the live EFFECTIVE graph
    -- (single source). Unsaved editor rows (staged_items) for the root level
    -- also count as current residents so post-capture arrivals survive the
    -- tail merge.
    local graph = require("lib.resolver").resolve(reg, txn:view(view))
    local staged_root_members
    if type(staged_items) == "table" then
        staged_root_members = {}
        for _, id in ipairs(staged_items) do
            if id ~= SEPARATOR_ID and type(id) == "string" then
                staged_root_members[#staged_root_members + 1] = id
            end
        end
    end
    local function currentMembers(target)
        local members, seen = {}, {}
        local function add(id)
            if id ~= SEPARATOR_ID and not seen[id] then
                seen[id] = true
                table.insert(members, id)
            end
        end
        for _, id in ipairs(graph.lists[target] or {}) do add(id) end
        if target == menu_id and staged_root_members then
            for _, id in ipairs(staged_root_members) do add(id) end
        end
        -- Hidden members belong here too when their origin says so.
        for hid, record in pairs(txn:view(view).hidden or {}) do
            if type(record) == "table" and record.origin == target then add(hid) end
        end
        return members
    end

    local captured_menus = util.tableDeepCopy(data.menus)
    -- Legacy dense payloads store plain lists instead of fragments.
    for captured_id, value in pairs(captured_menus) do
        if type(value) == "table" and value.sequence == nil and #value > 0 then
            captured_menus[captured_id] = { sequence = value }
        end
    end

    -- The saved fragment governs the root order and divider state. The
    -- editor's current rows (staged_items) only assist reconciliation via
    -- currentMembers above; they never replace the saved sequence.

    -- Bug 7 ordering: required custom submenu definitions must exist BEFORE
    -- captured child sequences are applied. The application loop below gates
    -- each captured level on `graph.lists[captured_id]` — a submenu that only
    -- exists inside this preset would fail that gate, so its saved contents
    -- could never be applied and the recreated container came back empty.
    -- Recreate the definitions first (from the capture), then apply
    -- membership/order, then validation + projection happen in saveOrder.
    local customs = data.custom_menus or {}
    do
        local IntentOps = require("lib.intent_ops")
        for cid, custom in pairs(customs) do
            if type(custom) == "table" and not txn:getCustomMenus(view)[cid]
                    and graph.lists[cid] == nil then
                -- Shared container semantics: definition + home (dormant when
                -- parent vanished; structural violations refused downstream
                -- via sanitize, never recorded here as panics).
                IntentOps.defineCustomContainer(view, txn, cid,
                    custom.title, custom.parent)
            end
        end
    end

    for captured_id, frag in pairs(captured_menus) do
        if type(frag) == "table" and type(frag.sequence) == "table"
                and (graph.lists[captured_id]
                    or txn:getCustomMenus(view)[captured_id]) then
            local merged, used = {}, {}
            for _, id in ipairs(frag.sequence) do
                if not used[id] then
                    used[id] = true
                    table.insert(merged, id)
                end
            end
            -- Shared membership semantics: captured children rejoin the level
            -- via the same parent gate as editor/import moves (dormant for
            -- vanished homes, refused for structural violations).
            do
                local IntentOps = require("lib.intent_ops")
                for _, id in ipairs(frag.sequence) do
                    if type(id) == "string" and id ~= SEPARATOR_ID then
                        if Materializer.effectiveParent(reg, txn:view(view), id)
                                ~= captured_id then
                            IntentOps.setMembership(view, txn, reg, id, captured_id)
                        end
                    end
                end
            end
            for _, id in ipairs(currentMembers(captured_id)) do
                if not used[id] then
                    used[id] = true
                    table.insert(merged, id)
                end
            end
            -- Era-stamped bulk, like every complete arrangement write.
            do
                local IntentOps = require("lib.intent_ops")
                local seq_eras = {}
                for _, id in ipairs(merged) do
                    seq_eras[id] = IntentOps.providerOf(reg, id)
                end
                txn:setOrderOverride(view, captured_id, merged, seq_eras)
            end
            -- Divider arrangement is represented once (P0-4). Staged captures
            -- (sep_anchors present, even empty) reconstruct semantically via
            -- the shared divider gate so empty->zero, default->clear, and
            -- pure-removal->marks round-trip exactly. Non-staged captures
            -- restore full records verbatim (removed / zero / provider kept).
            do
                local IntentOps = require("lib.intent_ops")
                if frag.sep_anchors ~= nil then
                    local observed = {}
                    for _, anchor in ipairs(frag.sep_anchors or {}) do
                        observed[#observed + 1] = anchor == false and false or anchor
                    end
                    IntentOps.setDividerArrangement(view, txn, reg,
                        captured_id, observed)
                elseif frag.separators ~= nil then
                    local section = txn:view(view)
                    for key in pairs(section.separators or {}) do
                        local sep = section.separators[key]
                        if sep and sep.parent == captured_id then
                            section.separators[key] = nil
                        end
                    end
                    local frag_keys = {}
                    for key in pairs(frag.separators or {}) do
                        frag_keys[#frag_keys + 1] = key
                    end
                    table.sort(frag_keys, function(a, b)
                        return tostring(a) < tostring(b)
                    end)
                    for _, key in ipairs(frag_keys) do
                        local sep = frag.separators[key]
                        if type(sep) == "table" then
                            txn:setSeparator(view, key, util.tableDeepCopy(sep))
                        end
                    end
                else
                    -- Non-staged capture with no divider records means stock
                    -- flow at capture: clear the level so a previous custom
                    -- arrangement reverts to stock (exact round-trip).
                    local section = txn:view(view)
                    for key in pairs(section.separators or {}) do
                        local sep = section.separators[key]
                        if sep and sep.parent == captured_id then
                            section.separators[key] = nil
                        end
                    end
                end
            end
        end
    end

    if reg ~= nil then
        pcall(function() return Placement.sanitizeSection(reg, txn:view(view)) end)
    end
    return true
end

-- P0-8: deletion accepts an enumerated descriptor (from listSubmenuPresets)
-- or a validated name - never a raw caller-chosen path. The file is
-- re-derived from the known directory and must match the claimed menu.
function Presets.deleteSubmenuPreset(view, menu_id, preset)
    local clean_name
    if type(preset) == "table" then
        if preset.path and not preset.name then
            return false, _("Preset paths are not accepted; use a preset name.")
        end
        local stem = type(preset.name) == "string"
            and preset.name:gsub("^submenu_", "") or nil
        clean_name = stem and select(1, cleanPresetName(stem)) or nil
        if stem and not clean_name then return false, _("Invalid preset name.") end
    elseif type(preset) == "string" then
        local name_err
        clean_name, name_err = cleanPresetName(preset:gsub("^submenu_", ""))
        if not clean_name then return false, name_err end
    end
    if not clean_name then return false, _("Submenu preset file not found.") end
    local dir = Presets.findSubmenuPresetsDir(view, menu_id)
    if not dir then return false, _("Submenu preset file not found.") end
    local path = presetPathIn(dir, clean_name)
    if lfs.attributes(path, "mode") == "file" then
        local data = DataLoader.loadTable(path)
        if data and data.menu_id == menu_id then
            return removePresetFile(path)
        end
    end
    return false, _("Submenu preset file not found.")
end

-- -------------------------------------------------------------------------
-- Builtin visibility (hide from list).
--
-- P1B: this is an ORDINARY OPERATIONAL PREFERENCE - which entries the user
-- wants hidden from the preset picker - not layout intent. It therefore
-- lives in the plugin's G_reader_settings namespace
-- (plugin_prefs), NOT in canonical state, NOT in a
-- preset-dir sidecar file. The legacy ".hidden_builtins.lua" file is
-- imported once per process on first access, then removed.
--
-- Backend API (UI naming owned by Agent C):
--   Presets.hideBuiltinPreset(view, id)     -> hide one builtin
--   Presets.unhideBuiltinPreset(view, id)   -> restore one builtin
--   Presets.restoreBuiltinPresets(view)     -> restore ALL hidden builtins
-- -------------------------------------------------------------------------

local function syncHiddenBuiltinsFromLegacy(view)
    PluginPrefs.importLegacyHiddenBuiltins(view,
        Presets.getHiddenBuiltinPath(view),
        function(path) return DataLoader.loadTable(path) end)
end

--- LEGACY path of the old hidden-builtins sidecar. Kept ONLY so the one-
--- time import can find (and remove) files written by older builds; new
--- code must never read or write it.
function Presets.getHiddenBuiltinPath(view)
    return string.format("%s/.hidden_builtins.lua", Presets.getPresetsDir(view))
end

function Presets.getHiddenBuiltinIds(view)
    syncHiddenBuiltinsFromLegacy(view)
    return PluginPrefs.getHiddenBuiltins(view)
end

function Presets.isBuiltinHidden(view, preset_id)
    if preset_id == "builtin_default" then return false end
    for _, hid in ipairs(Presets.getHiddenBuiltinIds(view)) do
        if hid == preset_id then return true end
    end
    return false
end

function Presets.hideBuiltinPreset(view, preset_id)
    if preset_id == "builtin_default" then
        return false, _("Cannot delete the default preset.")
    end
    if type(preset_id) ~= "string" or preset_id == "" then
        return false, _("Preset not found.")
    end
    syncHiddenBuiltinsFromLegacy(view)
    local hidden = PluginPrefs.getHiddenBuiltins(view)
    for _, hid in ipairs(hidden) do
        if hid == preset_id then return true end -- already hidden: no write
    end
    table.insert(hidden, preset_id)
    PluginPrefs.setHiddenBuiltins(view, hidden)
    return true
end

function Presets.unhideBuiltinPreset(view, preset_id)
    syncHiddenBuiltinsFromLegacy(view)
    local hidden = PluginPrefs.getHiddenBuiltins(view)
    local new_hidden, found = {}, false
    for _, hid in ipairs(hidden) do
        if hid ~= preset_id then
            table.insert(new_hidden, hid)
        else
            found = true
        end
    end
    if not found then return false end
    PluginPrefs.setHiddenBuiltins(view, new_hidden)
    return true
end

--- P1B backend API: restore every hidden built-in for a view at once.
--- Returns the number of presets restored.
function Presets.restoreBuiltinPresets(view)
    syncHiddenBuiltinsFromLegacy(view)
    local hidden = PluginPrefs.getHiddenBuiltins(view)
    PluginPrefs.setHiddenBuiltins(view, {})
    return #hidden
end

function Presets.getBuiltinPresets(view)
    local hidden = {}
    for _, id in ipairs(Presets.getHiddenBuiltinIds(view)) do
        hidden[id] = true
    end
    local visible = {}
    for _, preset in ipairs(buildBuiltinPresets()) do
        local for_view = preset.id == "builtin_default"
            or (BUILTIN_FRAGMENTS[view] and (function()
                for _, f in ipairs(BUILTIN_FRAGMENTS[view]) do
                    if f.id == preset.id then return true end
                end
                return false
            end)())
        if for_view and not hidden[preset.id] then
            table.insert(visible, preset)
        end
    end
    return visible
end

function Presets.getAllPresets(view)
    local combined = {}
    for _, p in ipairs(Presets.getBuiltinPresets(view)) do
        table.insert(combined, p)
    end
    for _, p in ipairs(Presets.listUserPresets(view)) do
        table.insert(combined, p)
    end
    return combined
end

function Presets.listDeletablePresets(view)
    local deletable = {}
    for _, p in ipairs(Presets.getAllPresets(view)) do
        if p.id ~= "builtin_default" then table.insert(deletable, p) end
    end
    return deletable
end

function Presets.updateUserPresetFile(view, preset, intent_section)
    local name, name_err = Presets.parseUserPresetDescriptor(preset)
    if not name then return false, name_err end
    local file_path = string.format("%s/%s.lua", Presets.getPresetsDir(view), name)
    if lfs.attributes(file_path, "mode") ~= "file" then
        return false, _("Preset file not found.")
    end
    local existing = readPresetFile(file_path)
    if existing and existing.format == "reorderingmenus_intent_preset" then
        -- Never rewrite an envelope this build does not understand: the
        -- update would silently replace future-format data with current-
        -- format data. The file stays read-only until a compatible build.
        local admissible, version_err = admitVersionedPreset(existing, name)
        if not admissible then return false, version_err end
        existing.intent = util.tableDeepCopy(intent_section)
        local ok, err = AtomicWriter.writeTable(file_path, existing, nil,
            { sorted = true })
        if not ok then return false, err end
        logger.info("ReorderingMenus: updated preset", name, "in", view)
        return true, file_path
    end
    if type(existing) == "table" and existing.format ~= nil then
        -- Some OTHER envelope this build does not recognize must never be
        -- clobbered by the legacy-upgrade write below.
        local admissible, version_err = admitVersionedPreset(existing, name)
        if not admissible then return false, version_err end
        return false, _("Preset file has an unrecognized format.")
    end
    -- Legacy file: upgrade it to the intent format on update.
    return Presets.saveViewPreset(view, name, intent_section)
end

function Presets.deletePresetFile(view, preset_name)
    local dir = Presets.getPresetsDir(view)
    local clean_name, name_err = cleanPresetName(
        type(preset_name) == "string" and preset_name:gsub("^user_", "") or nil)
    if not clean_name then return false, name_err end
    local candidates = { clean_name }
    for _, candidate in ipairs(candidates) do
        local file_path = string.format("%s/%s.lua", dir, candidate)
        if lfs.attributes(file_path) then
            return removePresetFile(file_path)
        end
    end
    return false, _("Preset file not found.")
end

return Presets

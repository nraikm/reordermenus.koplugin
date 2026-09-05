--[[--
native_writer.lua — graph -> minimal KOReader native overrides.

KOReader merges its user order per key: a menu list absent from the native
file falls back to the stock list. The writer exploits this by emitting only
the keys whose materialized content actually deviates from the pure-default
projection — an untouched menu stays completely absent, so a KOReader update
can reshape it with zero reconciliation.

Noncanonical metadata: after every write the exact emitted structure and its
fingerprint are recorded in reorderingmenus_materialization.lua. At startup
the native file is compared against that record:

    unchanged            -> normal startup, nothing to do
    externally edited    -> the diff is IMPORTED as explicit user intent
    unrepresentable edit -> scoped raw_override[parent] keeps it verbatim

so hand-editing KOReader's files stays supported while the canonical model
remains semantic.

The native file and materialization record are independently atomic. If a
process stops between them, generation and fingerprint recovery converges the
pair on the next startup; no multi-file journal is required.
--]]

local KoreaderAdapter = require("lib.koreader_adapter")
local Materializer = require("lib.materializer")
local Validator = require("lib.validator")
local AtomicWriter = require("lib.atomic_writer")
local DataLoader = require("lib.data_loader")
local IntentStore = require("lib.intent_store")
local SemanticDiff = require("lib.semantic_diff")
local MenuSchema = require("lib.menu_schema")
local Placement = require("lib.placement")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local NativeWriter = {}

local SEPARATOR_ID = MenuSchema.SEPARATOR_ID
local MENU_BUTTONS_KEY = MenuSchema.MENU_BUTTONS_KEY
local DISABLED_KEY = MenuSchema.DISABLED_KEY
local CUSTOM_SUBMENUS_KEY = MenuSchema.CUSTOM_SUBMENUS_KEY

-- Normalized shape of an externally supplied (or self-produced) native order
-- table. Every reader of a parsed file funnels through here so bizarre but
-- parseable Lua can never crash materialization, fingerprinting, or the
-- importer:
--
--   non-table reserved keys ("KOMenu:disabled" = string/boolean)  -> dropped
--   cyclic tables (self-referencing lists)                        -> cut at cycle
--   numeric menu keys                                             -> dropped
--   sparse arrays / nil holes                                     -> compacted
--   map-shaped or table-of-tables entries inside lists            -> dropped rows
--   duplicate ids in one list                                     -> deduped
--   duplicate root tabs                                           -> deduped
--   unknown top-level menu keys                                   -> normalized lists
--   custom-submenu title registry                                 -> string map
--   empty root lists                                              -> preserved as {}
--
-- Returns (normalized, true) when the input was already clean, so callers can
-- distinguish untouched files from repaired ones.
function NativeWriter.normalizeNativeOrder(native)
    if type(native) ~= "table" then return {}, false end
    local clean = true

    local out = {}
    for k, v in pairs(native) do
        if type(k) ~= "string" then
            clean = false
        elseif type(v) ~= "table" then
            -- A malformed reserved key (or any scalar value) must not reach
            -- ipairs()/fingerprint(): stock KOReader's own parser would choke.
            clean = false
        elseif k == CUSTOM_SUBMENUS_KEY then
            local titles = {}
            for id, title in pairs(v) do
                if type(id) == "string" and type(title) == "string" then
                    titles[id] = title
                else
                    clean = false
                end
            end
            out[k] = titles
        else
            local list, list_clean = {}, true
            local row_seen = {}
            local indices = {}
            for index in pairs(v) do
                if type(index) == "number" and index >= 1
                        and index % 1 == 0 then
                    table.insert(indices, index)
                else
                    list_clean = false
                end
            end
            table.sort(indices)
            for expected, index in ipairs(indices) do
                if index ~= expected then list_clean = false end
                local entry = v[index]
                if type(entry) ~= "string" then
                    list_clean = false
                elseif entry == SEPARATOR_ID then
                    -- Stock layouts legitimately repeat the divider id; every
                    -- occurrence is a distinct row and must survive.
                    table.insert(list, entry)
                elseif not row_seen[entry] then
                    row_seen[entry] = true
                    table.insert(list, entry)
                else
                    list_clean = false
                end
            end
            out[k] = list
            if not list_clean then clean = false end
        end
    end
    return out, clean
end

-- Order-stable AND cycle-safe structural hash. The legacy implementation
-- recursed through every reachable reference; a hand-edited native file that
-- contained a cyclic table overflowed the Lua stack during startup import.
local function fingerprintInner(value, active)
    if type(value) == "table" and active[value] then return "<cycle>" end
    local kind = type(value)
    if kind == "table" then
        active[value] = true
        local is_array = #value > 0
        local parts = {}
        if is_array then
            for i = 1, #value do
                table.insert(parts, fingerprintInner(value[i], active))
            end
            active[value] = nil
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(value) do table.insert(keys, tostring(k)) end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            table.insert(parts, k .. "=" .. fingerprintInner(value[k], active))
        end
        active[value] = nil
        return "{" .. table.concat(parts, ";") .. "}"
    end
    return kind .. ":" .. tostring(value)
end

local function fingerprint(value)
    return fingerprintInner(value, {})
end

local RESERVED = MenuSchema.RESERVED_KEYS
NativeWriter.RESERVED = RESERVED

local STATUS = {
    UNCHANGED                   = "unchanged",
    LEGACY                      = "legacy",
    MALFORMED                   = "malformed",
    CURRENT                     = "current",
    STALE                       = "stale",
    EXTERNAL                    = "external",
    PROTECTED_READONLY          = "protected_readonly",
    REGENERATED                 = "regenerated",
    REGENERATED_INTERRUPTED     = "regenerated_interrupted",
    REGENERATED_MALFORMED       = "regenerated_malformed",
    REGENERATED_LAGGING         = "regenerated_lagging",
    REGENERATED_REGISTRY_DRIFT  = "regenerated_registry_drift",
    REGENERATED_STALE           = "regenerated_stale",
    REGENERATED_WRITER_UPGRADE  = "regenerated_writer_upgrade",
    REGENERATED_SUSPENDED       = "regenerated_suspended",
    CONVERGED_SPARSE            = "converged_sparse",
    IMPORTED_LEGACY             = "imported_legacy",
    IMPORTED_EXTERNAL           = "imported_external",
    REVERTED                    = "reverted",
    CLEAN                       = "clean",
    CLEAN_EMPTY                 = "clean_empty",
    -- Failure modes
    REGENERATION_FAILED         = "regeneration_failed",
    REMOVE_FAILED               = "remove_failed",
    RECORD_CLEAR_FAILED         = "record_clear_failed",
    CHECKPOINT_REFRESH_FAILED   = "checkpoint_refresh_failed",
}
NativeWriter.STATUS = STATUS

-- Bump when the writer/fingerprint algorithm changes in a way that leaves
-- previously emitted files unrecognizable by hash alone. Stamped into each
-- per-view sidecar record by writeView; a record WITHOUT the field counts as
-- version 1 (pre-metadata era).
local WRITER_VERSION = 2
NativeWriter.WRITER_VERSION = WRITER_VERSION

NativeWriter.fingerprint = fingerprint

-- Deep equality for normalized native-order tables: same key sets, and for
-- every key an equal-length row-wise equal array. Both inputs are expected
-- to have passed normalizeNativeOrder (arrays of strings).
local function nativeStructureEquals(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k in pairs(a) do
        local va, vb = a[k], b[k]
        if type(vb) ~= "table" or type(va) ~= "table" then return false end
        if #va ~= #vb then return false end
        for i = 1, #va do
            if va[i] ~= vb[i] then return false end
        end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end
NativeWriter.nativeStructureEquals = nativeStructureEquals


-- -------------------------------------------------------------------------
-- Sidecar: last materialization per view (noncanonical metadata)
-- -------------------------------------------------------------------------

local function sidecarPath()
    return string.format("%s/reorderingmenus_materialization.lua",
        KoreaderAdapter.getSettingsDir())
end

local sidecar_cache

local function loadSidecar()
    if sidecar_cache then return sidecar_cache end
    -- P0-7: the materialization record is DATA, loaded restricted.
    local path = sidecarPath()
    local data = DataLoader.loadTable(path)
    if type(data) ~= "table" or type(data.views) ~= "table" then
        data = { views = {} }
    end
    -- Full per-record shape validation (#6): every field actually consumed
    -- downstream must have its documented type. The sidecar is DERIVED
    -- state - it is always safe to discard malformed records and let the
    -- next syncView/writeView regenerate them from canonical intent. A
    -- malformed sidecar therefore NEVER quarantines anything and NEVER
    -- touches canonical intent; dropping the record only costs one
    -- regeneration. Unknown extra fields are tolerated (additive metadata
    -- from newer writers must not be destroyed by older readers).
    local malformed = 0
    for view_name, record in pairs(data.views) do
        local bad = false
        if type(view_name) ~= "string" or not MenuSchema.isCanonicalView(view_name) then
            bad = true
        elseif type(record) ~= "table" then
            bad = true
        else
            if record.fingerprint ~= nil and type(record.fingerprint) ~= "string" then
                bad = true
            end
            if not bad and record.intent_gen ~= nil
                    and tonumber(record.intent_gen) == nil then
                bad = true
            end
            if not bad and record.writer_version ~= nil
                    and tonumber(record.writer_version) == nil then
                bad = true
            end
            if not bad and record.previous_fingerprint ~= nil
                    and type(record.previous_fingerprint) ~= "string" then
                bad = true
            end
            if not bad and record.structure ~= nil then
                if type(record.structure) ~= "table" then
                    bad = true
                else
                    local _, clean_struct = NativeWriter.normalizeNativeOrder(record.structure)
                    if not clean_struct then
                        bad = true
                    end
                end
            end
            -- Suspension marker (set by suspend-for-disable, cleared by the
            -- resume regeneration). Non-boolean values are corrupt metadata:
            -- drop the record and let the next sync regenerate from intent.
            if not bad and record.suspended ~= nil
                    and type(record.suspended) ~= "boolean" then
                bad = true
            end
        end
        if bad then
            data.views[view_name] = nil
            malformed = malformed + 1
        end
    end
    if malformed > 0 then
        logger.warn("ReorderingMenus: discarded", malformed,
            "malformed materialization record(s); regenerating from intent")
    end
    sidecar_cache = data
    return data
end

local function saveSidecar()
    local path = sidecarPath()
    if not next(loadSidecar().views) then
        if lfs.attributes(path) then
            local ok, err = os.remove(path)
            if not ok then
                logger.warn("ReorderingMenus: failed removing materialization record",
                    err)
                return false, err
            end
        end
        return true
    end
    local ok, err = AtomicWriter.writeTable(path, sidecar_cache,
        function(data) return type(data.views) == "table" end)
    if not ok then
        logger.warn("ReorderingMenus: failed writing materialization record", err)
    end
    return ok, err
end

function NativeWriter.getRecord(view)
    return loadSidecar().views[view]
end

-- True when a view's derived output must be (re)materialized EVEN THOUGH
-- canonical intent did not change:
--   * no checkpoint exists yet (a first save must establish the
--     reconciliation baseline, or later external edits would be misclassified
--     as legacy imports);
--   * the checkpoint predates the current writer version (the upgrade stamp
--     must refresh one-shot);
--   * the checkpoint's bound intent_gen lags the canonical per-view counter
--     (an unrelated-view commit advanced shared bookkeeping - the derived
--     file is stale relative to canonical even though THIS save changed
--     nothing);
--   * REGISTRY DRIFT under unchanged intent (checked separately via
--     emissionMatchesRecord by the funnel: a provider install/uninstall
--     flips dormant tombstones on/off or retires ids - generations stay
--     put while the correct derived output changes).
function NativeWriter.recordNeedsMaterialization(view)
    local record = loadSidecar().views[view]
    if not record then return true end
    if tonumber(record.writer_version) ~= WRITER_VERSION then return true end
    -- The record claims on-disk content but the file is gone (mid-session
    -- external deletion, or a crash after the sidecar write): the derived
    -- state must be rebuilt from canonical before anything trusts it.
    -- (Startup treats the same shape differently - a generation-consistent
    -- content-bearing absence is a deliberate user revert handled by
    -- syncView; this check only fires for IN-SESSION records.)
    if record.structure ~= nil
            and not KoreaderAdapter.nativeFileExists(view) then
        return true
    end
    return tonumber(record.intent_gen) ~= IntentStore.generation(view)
end

-- Test hook: a real crash kills the process, so on-disk state alone decides
-- recovery. In-process crash simulations must drop this cache to be faithful.
function NativeWriter._resetCaches()
    sidecar_cache = nil
end

function NativeWriter.clearRecord(view)
    local views = loadSidecar().views
    local previous = views[view]
    views[view] = nil
    local ok, err = saveSidecar()
    if not ok then views[view] = previous end
    return ok, err
end

-- Suspend-for-disable marker. Called when the plugin is being disabled
-- (stopPlugin): the native override file has just been withdrawn so stock
-- KOReader falls back to its defaults, while canonical intent is preserved
-- for a later re-enable. The flag tells the next startup sync that the
-- file's absence is OURS - not a deliberate user revert - so the world is
-- regenerated from intent instead of wiping it (see syncView).
--
-- No-op (true) when there is nothing withdrawn: no record, or a record
-- describing an already-absent file. Only marks when on-disk content was
-- actually removed, keeping empty-emission baselines untouched.
function NativeWriter.markSuspended(view)
    local record = loadSidecar().views[view]
    if not record then return true end
    local has_content = type(record.structure) == "table"
        and next(record.structure) ~= nil
    if not has_content and not KoreaderAdapter.nativeFileExists(view) then
        return true
    end
    record.suspended = true
    local ok, err = saveSidecar()
    if not ok then record.suspended = nil end
    return ok, err
end

-- -------------------------------------------------------------------------
-- THE one checkpoint constructor (P1A)
--
-- Every per-view materialization record - normal write, empty-emission
-- checkpoint, startup convergence, external adoption/regeneration - is
-- built here and only here. Same schema every time:
--   fingerprint         hash of the on-disk emission ({} when file removed)
--   structure           the on-disk emission itself (nil = no file)
--   intent_gen          the ACTUAL COMMITTED canonical generation at stamp
--                       time (IntentStore.generation reads committed state;
--                       in-flight transactions are not visible until commit)
--   writer_version      writer/fingerprint algorithm stamp
--   previous_fingerprint  hash of the replaced generation's on-disk bytes
--                       (one-generation lookback; see classifyParsedNative)
-- Returns ok, err and restores the previous record on sidecar failure.
-- -------------------------------------------------------------------------
local function setCheckpointRecord(view, fields)
    local prev_record = loadSidecar().views[view]
    local record = {
        fingerprint = fields.fingerprint,
        structure = fields.structure,
        intent_gen = IntentStore.generation(view),
        writer_version = WRITER_VERSION,
    }
    if prev_record then
        record.previous_fingerprint = prev_record.fingerprint
    end
    loadSidecar().views[view] = record
    local ok, err = saveSidecar()
    if not ok then
        loadSidecar().views[view] = prev_record
        return false, err
    end
    return true
end

-- Checkpoint an EMPTY emission (the derived file was deliberately removed -
-- reset to stock). The record binds intent_gen and stamps writer_version so
-- (a) the next startup classifies against a REAL baseline: any bytes that
-- appear are EXTERNAL edits or stale generations of ours, never "legacy
-- first contact"; (b) the maintenance branch of the commit funnel stops
-- re-firing for this view. structure stays nil = "no file on disk".
function NativeWriter.checkpointEmptyEmission(view)
    return setCheckpointRecord(view, {
        fingerprint = fingerprint({}),
        structure = nil,
    })
end

-- -------------------------------------------------------------------------
-- Sparse emission
-- -------------------------------------------------------------------------

-- Compare the customized projection against the pure-default projection and
-- emit only what differs.
function NativeWriter.graphToNative(reg, intent, graph, empty_graph)
    local native = {}

    for menu_id, list in pairs(graph.lists) do
        local is_custom = type(intent.custom_menus) == "table"
            and intent.custom_menus[menu_id] ~= nil
        local differs = not Materializer.listEquals(list,
            empty_graph.lists and empty_graph.lists[menu_id])
        if is_custom or differs then
            native[menu_id] = list
        end
    end

    -- Raw passthroughs are preserved VERBATIM even when the resolved graph
    -- dropped them (unreachable hand-authored levels): the user's bytes are
    -- user data, and stock ignores keys nothing references. Without this the
    -- next save would silently delete a hand-authored level.
    if type(intent.raw_override) == "table" then
        for menu_id, raw in pairs(intent.raw_override) do
            if native[menu_id] == nil and type(raw) == "table"
                    and type(raw.list) == "table" then
                native[menu_id] = util.tableDeepCopy(raw.list)
            end
        end
    end

    if not Materializer.listEquals(graph.tabs, empty_graph.tabs) then
        native[MENU_BUTTONS_KEY] = graph.tabs
    end
    -- KOMenu:disabled and KOMenu:custom_submenus are ALWAYS emitted, even
    -- empty: stock mergeAndSort overlays user keys onto the process-lifetime
    -- elements module, so an omitted key would leave a PREVIOUS generation's
    -- disabled set (or custom titles) baked into every later build - items
    -- unhidden mid-session would stay invisible until restart.
    native[DISABLED_KEY] = graph.disabled
    local titles
    for id, title in pairs(graph.custom_titles or {}) do
        titles = titles or {}
        titles[id] = title
    end
    native[CUSTOM_SUBMENUS_KEY] = titles or {}

    -- Clobber ghost levels. mergeAndSort overlays the native ONTO the stock
    -- defaults, so a hidden/unreachable submenu whose default key survives
    -- would still run through stock's placement pass - consuming children
    -- that were deliberately moved elsewhere (pairs-order dependently!) or
    -- rendering its old subtree. An explicit empty list removes the default
    -- key's contents deterministically.
    for menu_id, info in pairs(reg.menus or {}) do
        if graph.lists[menu_id] == nil and #info.list > 0 then
            native[menu_id] = {}
        end
    end
    return native
end

-- Write one view's sparse override file; an empty result removes the file so
-- stock rules apply untouched.
--
-- Cleaner generation: graphToNative always emits KOMenu:disabled and
-- KOMenu:custom_submenus (even empty) so a mid-session mergeAndSort cannot
-- keep overlaying a PREVIOUS generation's disabled set / titles. But once the
-- PREVIOUS on-disk emission already contained those keys (empty or not), the
-- process-lifetime pollution is gone and an all-empty reserved surface means
-- "nothing to override" again - the file is removed and stock rules flow,
-- keeping true sparseness for pristine worlds.
local function stripEmptyReservedMaps(view, native)
    -- Any real layout content: keep the whole emission verbatim.
    for key in pairs(native) do
        if not RESERVED[key] then return false end
    end
    local record = loadSidecar().views[view]
    local previous = record and record.structure
    for _, key in ipairs({ DISABLED_KEY, CUSTOM_SUBMENUS_KEY }) do
        local value = native[key]
        -- The CURRENT emission carries real reserved data (e.g. the first
        -- hide makes KOMenu:disabled non-empty): that is information and
        -- must reach disk - never strip a meaningful map. (Stripping used
        -- to consult only the PREVIOUS record here and then delete
        -- unconditionally, silently discarding a newly-hidden state.)
        if type(value) == "table" and next(value) ~= nil then return false end
        if type(value) == "string" then return false end
        -- Current value is empty/nil: dropping it is safe UNLESS the
        -- previous on-disk emission held a non-empty map there - that map
        -- may have polluted the process-lifetime elements module, so one
        -- more build needs the explicit empty override to scrub it.
        local prev_value = type(previous) == "table" and previous[key] or nil
        if type(prev_value) == "table" and next(prev_value) ~= nil then
            return false
        end
        if type(prev_value) == "string" then return false end
    end
    native[DISABLED_KEY] = nil
    native[CUSTOM_SUBMENUS_KEY] = nil
    return next(native) == nil
end

-- Compute what writeView would ACTUALLY persist for this emission WITHOUT
-- touching disk: graphToNative output after the cleaner-generation stripping
-- of the reserved surface. Returns nil when writeView would remove/skip the
-- file (everything stripped). Change detectors elsewhere (reconcile's
-- maintenance branch) MUST compare against this projected shape, not the raw
-- graphToNative result: the reserved maps are always filled for mid-session
-- mergeAndSort hygiene but carry no information unless the PREVIOUS on-disk
-- emission held non-empty reserved values - fingerprinting the raw shape can
-- therefore never match an empty-emission checkpoint, making every mere
-- observation look dirty and demanding a pointless durable write.
-- (Declared AFTER stripEmptyReservedMaps: Lua locals are lexically scoped,
-- so an earlier placement resolves it as a nil global at call time.)
function NativeWriter.previewEmission(view, reg, intent, graph)
    local empty_graph = Materializer.resolve(reg, nil)
    local native = NativeWriter.graphToNative(reg, intent, graph, empty_graph)
    if stripEmptyReservedMaps(view, native) then return nil end
    return native
end

--- True when a (projected or parsed) emission carries NO real layout
--- content: every key is a reserved map and every reserved value is an
--- EMPTY table. Such files override nothing in a freshly-required elements
--- module - they exist only as a transient scrub of a PREVIOUS emission's
--- non-empty reserved surface, and startup convergence (syncView) removes
--- them on sight. Callers deciding whether derived output justifies keeping
--- a native file at all (materializeView's empty branch) must treat
--- reserved-only shapes as EMPTY.
function NativeWriter.emissionIsReservedOnly(native)
    -- Inline twin of containsOnlyEmptyReservedMaps (declared further down;
    -- Lua locals are lexically scoped so it is not callable up here).
    if type(native) ~= "table" or next(native) == nil then return false end
    for key, value in pairs(native) do
        if not RESERVED[key] or type(value) ~= "table" or next(value) ~= nil then
            return false
        end
    end
    return true
end

--- Does the CURRENT canonical intent still project to exactly the recorded
--- emission? False means the world moved under an unchanged sidecar record
--- (a provider-era flip gating records out, an updated stock layout, an
--- updated sorting hint): the derived file is STALE even though every
--- generation counter agrees, because canonical never changed. Callers use
--- this as derived-output maintenance signal - the same class as
--- recordNeedsMaterialization, not as user-visible dirt.
function NativeWriter.emissionMatchesRecord(view, reg)
    local record = loadSidecar().views[view]
    if not record then return false end
    if not reg then return true end -- no registry this session; startup owns it
    -- A raise inside the comparison (a fault-injected or genuinely broken
    -- emission builder) conservatively means "assume drift": the caller will
    -- regenerate through the funnel, where failures are contained and
    -- reported per view. Swallowing the error here would hide it; letting it
    -- propagate would escape maintenance paths that run OUTSIDE the funnel's
    -- per-view pcall (startup sync, reconcile drift checks).
    local ok_match, matches = pcall(function()
        local section = IntentStore.view(view)
        local graph = Materializer.resolve(reg, section)
        local _, repaired = Validator.validate(graph, reg, section)
        local would_persist = NativeWriter.previewEmission(view, reg,
            section, repaired)
        return fingerprint(would_persist or {}) == record.fingerprint
    end)
    if not ok_match then return false end
    return matches
end

function NativeWriter.writeView(view, reg, intent, graph)
    local empty_graph = Materializer.resolve(reg, nil)
    local native = NativeWriter.graphToNative(reg, intent, graph, empty_graph)

    local has_content = false
    for key in pairs(native) do
        has_content = true
    end
    -- Cleaner generation policy: graphToNative always fills the reserved
    -- maps so a mid-session mergeAndSort cannot keep overlaying a PREVIOUS
    -- generation's disabled set / titles. But those keys carry information
    -- only when they CHANGE what stock merged earlier - which happens exactly
    -- when the previous on-disk emission held a NON-EMPTY disabled set or
    -- titles map. Otherwise (pristine world, or the cleaner already ran) the
    -- reserved surface is stripped here so an all-empty result removes the
    -- file and stock rules flow untouched.
    if stripEmptyReservedMaps(view, native) then has_content = false end

    -- Record what is ACTUALLY on disk: when the cleaner generation removed
    -- the file, an empty structure would make the next save believe the
    -- previous emission still carried the reserved keys and re-emit them
    -- forever (write/remove/write/...). nil = "no file" for syncView.
    local record = loadSidecar().views[view]
    local on_disk_native = has_content and native or nil
    if not has_content then
        local ok_remove, remove_err = KoreaderAdapter.removeNativeOrder(view)
        if not ok_remove then return false, native, remove_err end
    else
        local ok, err = KoreaderAdapter.writeNativeOrder(view, native)
        if not ok then return false, native, err end
    end

    -- Keep one previous generation: if a startup finds the native file
    -- holding OUR OWN older output (a crash between the per-view writes of a
    -- multi-view commit), it can be regenerated from canonical intent instead
    -- of being misread as an external edit.
    --
    -- fingerprint/structure describe the ON-DISK state (nil structure = file
    -- removed), so the next writeView's cleaner-generation check compares
    -- against reality; intent_gen still binds to this commit.
    local ok_ckpt, ckpt_err = setCheckpointRecord(view, {
        fingerprint = fingerprint(on_disk_native or {}),
        structure = on_disk_native,
    })
    if not ok_ckpt then return false, native, ckpt_err end
    return true, native
end

-- -------------------------------------------------------------------------
-- Three-way import of external/native edits
-- -------------------------------------------------------------------------

local function findIdLocation(order_table, id)
    local menu_ids = {}
    for menu_id in pairs(order_table) do menu_ids[#menu_ids + 1] = menu_id end
    table.sort(menu_ids, function(a, b) return tostring(a) < tostring(b) end)
    for _, menu_id in ipairs(menu_ids) do
        local list = order_table[menu_id]
        if menu_id ~= DISABLED_KEY and menu_id ~= CUSTOM_SUBMENUS_KEY
                and type(list) == "table" then
            for _, listed in ipairs(list) do
                if listed == id then return menu_id end
            end
        end
    end
    return nil
end

-- Import a native file that has no recorded baseline (first contact with a
-- pre-existing dense file from this plugin's older architecture, or from
-- another tool). Deviations from the CURRENT defaults become explicit
-- intent; lists matching the defaults produce no records at all.
function NativeWriter.importAgainstDefaults(view, reg, txn, native)
    local imported = 0
    local defaults = reg.menus

    -- Tabs: reordered bar -> tab_order; hidden tabs stay in KOMenu:disabled.
    local default_tabs = {}
    for i, t in ipairs(reg.tab_list) do default_tabs[t] = i end
    if native[MENU_BUTTONS_KEY] then
        local seq = {}
        local same = #native[MENU_BUTTONS_KEY] == #reg.tab_list
        for i, t in ipairs(native[MENU_BUTTONS_KEY]) do
            table.insert(seq, t)
            if default_tabs[t] ~= i then same = false end
        end
        if not same and #seq > 0 then
            txn:setTabOrder(view, seq)
            imported = imported + 1
        end
    end

    local disabled = {}
    for _, id in ipairs(type(native[DISABLED_KEY]) == "table"
            and native[DISABLED_KEY] or {}) do disabled[id] = true end

    for menu_id, list in pairs(native) do
        if not RESERVED[menu_id] and type(list) == "table" then
            local default_list = defaults[menu_id] and defaults[menu_id].list
            if not default_list then
                -- Unknown level: a hand-created submenu without title info.
                -- Title lives on the creation record; the parent lives ONLY
                -- in parent_override (single parent authority, schema v3).
                txn:setCustomMenu(view, menu_id, { title = menu_id })
                local located_parent = findIdLocation(native, menu_id)
                if located_parent then
                    txn:setParentOverride(view, menu_id, {
                        provider = nil,
                        parent = located_parent,
                    })
                end
                local unknown_seq = (function()
                    local s = {}
                    for _, x in ipairs(list) do
                        if x ~= SEPARATOR_ID then
                            table.insert(s, x)
                        end
                    end
                    return s
                end)()
                local eras = {}
                for _, x in ipairs(unknown_seq) do
                    local node = reg.nodes[x]
                    eras[x] = node and node.provider or nil
                end
                txn:setOrderOverride(view, menu_id, unknown_seq, eras)
                imported = imported + 1
            else
                -- Sameness MUST be decided by full-fidelity element-wise
                -- comparison INCLUDING separators: a stock list that merely
                -- contains dividers is not a user arrangement, and freezing
                -- it as an order_override would block upstream reorders for
                -- every menu with a stock separator.
                local same_layout = #list == #default_list
                if same_layout then
                    for i, id in ipairs(list) do
                        if default_list[i] ~= id then
                            same_layout = false
                            break
                        end
                    end
                end
                local seq = {}
                local separators_pending = {}
                for _, id in ipairs(list) do
                    if id == "----------------------------" then
                        table.insert(separators_pending, { index = #seq })
                    else
                        table.insert(seq, id)
                    end
                end
                if same_layout then
                    -- Mirrors the current stock layout: carries no user
                    -- information, so nothing is persisted for this key.
                    -- Updates to untouched layouts must keep flowing through.
                else
                    local eras = {}
                    for _, x in ipairs(seq) do
                        local node = reg.nodes[x]
                        eras[x] = node and node.provider or nil
                    end
                    txn:setOrderOverride(view, menu_id, seq, eras)
                    for i, sep in ipairs(separators_pending) do
                        txn:setSeparator(view, string.format("%s_sep_%d", menu_id, i), {
                            parent = menu_id,
                            after = sep.index >= 1 and seq[sep.index] or false,
                        })
                    end
                    imported = imported + 1
                end
                -- Membership reconciliation against the whole file: ids listed
                -- under a non-default parent become explicit moves.
                -- Centralized placement gate: unsupported claims (tab_nesting
                -- etc.) are never recorded — the tab stays in the bar. This
                -- keeps dense legacy files that nested a tab from producing
                -- a crashing duplicate on import.
                if not same_layout then
                    for _, id in ipairs(seq) do
                        local node = reg.nodes[id]
                        local claim_parent = menu_id
                        local section_now = txn:view(view)
                        local ok_claim, claim_reason = Placement.canPlace(reg, section_now, id, claim_parent)
                        if not ok_claim and claim_reason ~= Placement.REASONS.UNKNOWN_PARENT then
                            -- Unsupported STRUCTURAL claim (tab_nesting etc.):
                            -- skip silently; the resolve-time fallback +
                            -- validator keep the world render-safe. Vanished
                            -- containers stay recordable (dormancy).
                        elseif node and node.default_parent
                                and node.default_parent ~= menu_id
                                and not disabled[id] then
                            txn:setParentOverride(view, id, {
                                provider = node.provider,
                                parent = menu_id,
                            })
                            imported = imported + 1
                        elseif not node and not disabled[id] then
                            txn:setParentOverride(view, id, {
                                parent = menu_id,
                            })
                            imported = imported + 1
                        end
                    end
                end
            end
        end
    end

    -- Visibility: everything in KOMenu:disabled becomes hidden intent.
    for _, id in ipairs(native[DISABLED_KEY] or {}) do
        local node = reg.nodes[id]
        txn:setHidden(view, id, {
            provider = node and node.provider or nil,
            origin = findIdLocation(native, id) or (node and node.default_parent),
        })
        imported = imported + 1
    end

    -- Tabs: the bar may only name live tabs. Filter legacy dense bars that
    -- list ordinary submenu ids as tabs (unrenderable as tabs).
    do
        local section = txn:view(view)
        if type(section.tab_order) == "table" then
            local filtered = Placement.filterTabBar(reg, section.tab_order)
            if #filtered ~= #section.tab_order then
                if #filtered == 0 then
                    section.tab_order = nil
                else
                    section.tab_order = filtered
                end
            end
        end
        pcall(function() return Placement.sanitizeSection(reg, section) end)
    end

    return imported
end

local function materializeValidated(reg, section)
    local graph = Materializer.resolve(reg, section)
    local _, repaired = Validator.validate(graph, reg, section)
    return repaired
end

local function regenerateView(view, reg, txn)
    local section = txn:view(view)
    -- Regeneration fires precisely when the sidecar record CANNOT be
    -- trusted to match canonical intent (interrupted commit, lagging
    -- generation, corrupt file). Projection is a pure function of
    -- (registry, canonical intent): derive from canonical alone - there is
    -- no read-path seeding to defer continuity to anymore.
    local ok, native, err = NativeWriter.writeView(view, reg, section,
        materializeValidated(reg, section))
    if not ok then
        logger.err("ReorderingMenus: failed regenerating", view,
            "native order:", err)
    end
    return ok, native, err
end

local function regenerateForStartup(view, reg, txn, success_mode)
    local ok = regenerateView(view, reg, txn)
    if not ok then return false, STATUS.REGENERATION_FAILED end
    return true, success_mode
end

local function containsOnlyEmptyReservedMaps(native)
    if next(native) == nil then return false end
    for key, value in pairs(native) do
        if not RESERVED[key] or type(value) ~= "table" or next(value) ~= nil then
            return false
        end
    end
    return true
end

local function classifyParsedNative(entry, was_clean, native_fingerprint)
    -- A file without a sidecar is legacy even when normalization repaired its
    -- shape: importAgainstDefaults is the only available baseline in that case.
    if not entry then return STATUS.LEGACY end
    if not was_clean then return STATUS.MALFORMED end
    -- Hash recognition is only valid when the record's hashes were produced
    -- by THIS writer/fingerprint algorithm: a foreign algorithm can collide
    -- on different bytes, so version-mismatched records must fall through to
    -- the structural bridge / external-import paths instead of adopting.
    local same_writer = entry.writer_version == nil
        or tonumber(entry.writer_version) == WRITER_VERSION
    if not same_writer then return STATUS.EXTERNAL end
    if entry.fingerprint == native_fingerprint then return STATUS.CURRENT end
    if entry.previous_fingerprint ~= nil
            and entry.previous_fingerprint == native_fingerprint then
        return STATUS.STALE
    end
    return STATUS.EXTERNAL
end

local importExternalChanges

-- Startup sync for one view. Returns changed(bool), mode(string).
function NativeWriter.syncView(view, reg, txn)
    -- Protected canonical storage (#1): while an unknown future schema
    -- guards the intent file, this view's DERIVED output belongs to that
    -- guarded world too. Regenerating it from the fresh in-memory state
    -- would wipe the user's live menu layout (the sidecar's generation can
    -- never agree with a frozen canonical counter), and importing foreign
    -- bytes into a transaction that can never persist would silently drop
    -- them on the next restart. Derived files are left byte-exactly alone;
    -- protection is re-derived from disk on every load, so lifting the
    -- guard (explicit reset / external replacement) resumes normal syncing.
    if IntentStore.isProtected() then
        return false, STATUS.PROTECTED_READONLY
    end
    local native = KoreaderAdapter.readNativeOrder(view)
    local entry = NativeWriter.getRecord(view)

    if not native and not KoreaderAdapter.nativeFileExists(view) then
        if entry then
            -- Suspend-for-disable resume: WE withdrew this file (stopPlugin)
            -- while keeping canonical intent for a later re-enable. The
            -- absence must regenerate from intent - never wipe it as a user
            -- revert would. The regeneration checkpoints a fresh record,
            -- which clears the flag. Checked before every other
            -- missing-file classification.
            if entry.suspended then
                return regenerateForStartup(view, reg, txn,
                    STATUS.REGENERATED_SUSPENDED)
            end
            -- Distinguish "the user deleted our file" from "we ourselves did
            -- not write one": when the last materialization was EMPTY (the
            -- derived layout equalled stock, so the sparse writer correctly
            -- removed or skipped the file), a missing file is our own doing
            -- and must never wipe canonical intent - provider-inert tombstone
            -- records routinely produce exactly this state.
            local had_content = type(entry.structure) == "table"
                and next(entry.structure) ~= nil
            -- Generation bookkeeping decides between debris and revert. The
            -- sidecar records which canonical generation the last emission
            -- was derived from; when it DISAGREES with the current canonical
            -- per-view generation, a commit sequence was interrupted (crash
            -- between the intent commit and the derived-file write, or an
            -- external rollback of one of the two files). Canonical intent is
            -- the source of truth, so the derived state is rebuilt from it.
            -- Only a generation-consistent missing file is a deliberate user
            -- deletion (full revert to stock).
            local sidecar_gen = tonumber(entry.intent_gen)
            local canonical_gen = IntentStore.generation(view)
            if sidecar_gen ~= nil and sidecar_gen ~= canonical_gen then
                logger.warn("ReorderingMenus:", view,
                    "native file missing after an interrupted commit;",
                    "regenerating from canonical intent")
                return regenerateForStartup(view, reg, txn,
                    STATUS.REGENERATED_INTERRUPTED)
            end
            if had_content then
                -- The file we generated was deleted: treat as full revert.
                txn:resetView(view)
                local ok_clear = NativeWriter.clearRecord(view)
                if not ok_clear then return false, STATUS.RECORD_CLEAR_FAILED end
                return true, STATUS.REVERTED
            end
            -- Empty-emission checkpoint (structure = nil): the absence is OUR
            -- OWN doing and the baseline must SURVIVE so a later hand edit is
            -- still classified EXTERNAL rather than legacy first contact, and
            -- so reconcile keeps treating this view as clean. Refresh the
            -- intent_gen binding instead of destroying the record.
            entry.intent_gen = canonical_gen
            local ok_keep = saveSidecar()
            if not ok_keep then return false, STATUS.CHECKPOINT_REFRESH_FAILED end
            return false, STATUS.CLEAN_EMPTY
        end
        return false, STATUS.CLEAN
    end

    if not native then
        -- The file EXISTS but is unreadable or malformed: a crashed or
        -- interrupted write, or external corruption. Stock KOReader parses
        -- this file with unprotected dofile(), so leaving it in place would
        -- break the next menu build. It must never be mistaken for a user's
        -- deliberate deletion (that is the missing-file case above): instead
        -- the derived file is regenerated from canonical intent, which keeps
        -- every customization and restores a parseable on-disk state.
        logger.warn("ReorderingMenus: native order file for", view,
            "is corrupt; regenerating from canonical intent")
        return regenerateForStartup(view, reg, txn, STATUS.REGENERATED)
    end

    -- Normalize shape before anything iterates the file: cyclic tables,
    -- scalar reserved keys, numeric keys, sparse arrays, duplicate ids and
    -- non-string rows are repaired here so no downstream code can be crashed
    -- by bizarre-but-parseable Lua. The file on disk is regenerated below
    -- from canonical intent in every changed-file path.
    local native, was_clean = NativeWriter.normalizeNativeOrder(native)
    local native_fingerprint = fingerprint(native)
    local native_state = classifyParsedNative(entry, was_clean,
        native_fingerprint)

    if native_state == STATUS.LEGACY then
        local imported = NativeWriter.importAgainstDefaults(view, reg, txn, native)
        return imported > 0, STATUS.IMPORTED_LEGACY
    end

    if native_state == STATUS.MALFORMED then
        logger.warn("ReorderingMenus:", view,
            "native order file had malformed structure; regenerating from intent")
        return regenerateForStartup(view, reg, txn, STATUS.REGENERATED_MALFORMED)
    end

    if native_state == STATUS.CURRENT then
        -- The file matches our last emission. That is only truly "unchanged"
        -- when the emission also matches canonical intent: a crash between
        -- the intent commit and writeView leaves OUR OWN OLD file on disk
        -- with a matching old sidecar while intent has moved on. The bound
        -- intent_gen exposes that lag; regenerate instead of reporting clean.
        local sidecar_gen = tonumber(entry.intent_gen)
        local canonical_gen = IntentStore.generation(view)
        if sidecar_gen ~= nil and sidecar_gen ~= canonical_gen then
            logger.info("ReorderingMenus:", view,
                "derived file lags committed intent; regenerating")
            return regenerateForStartup(view, reg, txn,
                STATUS.REGENERATED_LAGGING)
        end
        -- Generations and bytes can both agree while the world that must be
        -- projected has changed: a KOReader default moved, a provider
        -- arrived/disappeared, or a sorting hint changed. Compare the
        -- canonical+registry projection to the recorded emission before
        -- accepting CURRENT, otherwise a fresh process can retain an old
        -- sparse list indefinitely and KOReader renders the newcomer as NEW:.
        if not NativeWriter.emissionMatchesRecord(view, reg) then
            logger.info("ReorderingMenus:", view,
                "registry/defaults changed under committed intent; regenerating")
            return regenerateForStartup(view, reg, txn,
                STATUS.REGENERATED_REGISTRY_DRIFT)
        end
        -- Startup convergence: the file matches our last emission AND that
        -- emission consists solely of EMPTY reserved maps. The elements
        -- module was freshly required (no mergeAndSort overlay pollution in
        -- THIS process), so those keys override nothing - remove the file so
        -- stock rules flow untouched until real customization returns.
        if containsOnlyEmptyReservedMaps(native) then
            logger.info("ReorderingMenus:", view,
                "removing empty reserved-key-only native file at startup")
            local ok_remove = KoreaderAdapter.removeNativeOrder(view)
            if not ok_remove then return false, STATUS.REMOVE_FAILED end
            -- Keep the empty-emission baseline alive (structure = nil): this
            -- is our own convergence, not an external wipe, so the record
            -- must keep classifying later bytes as EXTERNAL vs legacy and
            -- keep reconcile clean.
            local ok_ckpt = setCheckpointRecord(view, {
                fingerprint = fingerprint({}),
                structure = nil,
            })
            if not ok_ckpt then return false, STATUS.RECORD_CLEAR_FAILED end
            return false, STATUS.CONVERGED_SPARSE
        end
        return false, STATUS.UNCHANGED
    end

    -- Generation lag alone must NOT classify the file: atomic renames mean
    -- the destination path can only ever hold COMPLETE files - either one of
    -- OUR emissions (current or previous, both fingerprinted in the sidecar)
    -- or FOREIGN bytes (a hand edit / another tool) laid on top of whichever
    -- generation existed when the user opened it. An unrelated-view commit
    -- can advance this view's per-view counter via shared bookkeeping, so
    -- trusting the counter here would destroy genuine hand edits whenever
    -- any other view was saved between our emission and the edit.
    --
    -- Our own stale generation (crash between the per-view writes of one
    -- commit, or an external rollback to our previous output): the bytes
    -- match a KNOWN fingerprint of ours -> rematerialize from canonical
    -- intent, importing nothing.
    if native_state == STATUS.STALE then
        logger.info("ReorderingMenus:", view,
            "native file is a stale generation; regenerating from intent")
        return regenerateForStartup(view, reg, txn, STATUS.REGENERATED_STALE)
    end

    -- LAST-RESORT self-recognition (writer/fingerprint algorithm changed
    -- between plugin versions): when no recorded hash matches but the bytes
    -- are structurally IDENTICAL to our last emission - same key sets, same
    -- row order, same reserved maps, merely re-serialized by a different
    -- writer version - this is our own output, not a hand edit. Re-emit from
    -- canonical intent so the on-disk fingerprint is refreshed under the new
    -- algorithm. A file that differs by even one row still goes through the
    -- external-import path below; a v1 record without writer_version only
    -- qualifies while its structure field survives.
    local last_structure = entry and entry.structure or nil
    if type(last_structure) == "table" and next(last_structure) ~= nil
            and (entry.writer_version == nil
                or tonumber(entry.writer_version) ~= WRITER_VERSION)
            and nativeStructureEquals(native, last_structure) then
        -- Belt and braces: only when canonical intent still carries at least
        -- one user record does "our own output" remain the safe reading.
        local section = txn:view(view)
        local has_intent = false
        for _, coll in ipairs({ "hidden", "parent_override",
                "position_override", "order_override", "raw_override",
                "separators", "custom_menus" }) do
            local c = section[coll]
            if type(c) == "table" and next(c) ~= nil then
                has_intent = true
                break
            end
        end
        if not has_intent and type(section.tab_order) == "table"
                and next(section.tab_order) ~= nil then
            has_intent = true
        end
        if has_intent then
            logger.info("ReorderingMenus:", view,
                "native file matches our last emission structurally",
                "(writer/fingerprint version change); re-emitting from intent")
            return regenerateForStartup(view, reg, txn,
                STATUS.REGENERATED_WRITER_UPGRADE)
        end
    end

    -- Externally edited: import every difference as explicit user intent.
    return importExternalChanges(view, reg, txn, native, entry)
end

-- Convert differences from a recognized, externally edited native file into
-- semantic intent. Startup classification stays in syncView; this helper owns
-- only the three-way import against the last emitted structure.
--
-- LOADED-BASELINE IMMUTABILITY (P1A): `entry.structure` is the loaded
-- sidecar baseline and is treated as strictly read-only here. Where an
-- absent key's meaningful baseline is the stock default list, that
-- substitution happens on a per-key LOCAL variable plus a derived shadow
-- table - never by writing back into the sidecar record. (The old code did
-- `last[menu_id] = default_menu.list`, silently mutating shared loaded
-- state during analysis; a later saveSidecar could persist stock lists as
-- if they were our emission.)
importExternalChanges = function(view, reg, txn, native, entry)
    local imported = 0
    local last = entry.structure or {}
    -- Derived analysis view over the baseline: identical content, but this
    -- copy (and only this copy) may be extended with default-baseline rows.
    local baseline = {}
    for menu_id, list in pairs(last) do baseline[menu_id] = list end
    local disabled_ids = {}
    -- The file was normalized above, but the sidecar structure is trusted
    -- less (it may predate normalization or be hand-edited itself).
    for _, id in ipairs(type(native[DISABLED_KEY]) == "table"
            and native[DISABLED_KEY] or {}) do disabled_ids[id] = true end

    local function importDisabledChanges(new_list, old_list)
        local old_disabled, new_disabled = {}, {}
        for _, id in ipairs(type(old_list) == "table" and old_list or {}) do
            old_disabled[id] = true
        end
        for _, id in ipairs(type(new_list) == "table" and new_list or {}) do
            new_disabled[id] = true
            if not old_disabled[id] then
                local node = reg.nodes[id]
                txn:setHidden(view, id, {
                    provider = node and node.provider or nil,
                    origin = findIdLocation(native, id)
                        or (node and node.default_parent),
                })
                imported = imported + 1
            end
        end
        for id in pairs(old_disabled) do
            if not new_disabled[id] then
                txn:setHidden(view, id, nil)
                imported = imported + 1
            end
        end
    end

    -- Removed keys mean the editor deleted them -> back to stock for those.
    for menu_id in pairs(last) do
        if native[menu_id] == nil and not RESERVED[menu_id] then
            txn:setOrderOverride(view, menu_id, nil)
            txn:setRawOverride(view, menu_id, nil)
            imported = imported + 1
        end
    end

    -- Membership claims gathered from every changed level. An external file
    -- is explicit user intent about MEMBERSHIP too: an id listed under a
    -- non-default parent means "the user moved it there", so the import must
    -- record that placement instead of relying on duplicate repair later.
    -- Claims are resolved after the scan with a deterministic customized-
    -- destination-wins policy, independent of pairs() order.
    local native_keys = {}
    for menu_id in pairs(native) do table.insert(native_keys, menu_id) end
    table.sort(native_keys)

    -- Pass 1: Discover and register all custom submenus and brand-new levels
    -- so that subsequent ordering passes recognize custom level IDs deterministically.
    if type(native[CUSTOM_SUBMENUS_KEY]) == "table" then
        local old_titles = type(baseline[CUSTOM_SUBMENUS_KEY]) == "table" and baseline[CUSTOM_SUBMENUS_KEY] or {}
        for id, title in pairs(native[CUSTOM_SUBMENUS_KEY]) do
            if old_titles[id] ~= title and type(title) == "string" then
                local custom = txn:getCustomMenus(view)[id]
                if custom then
                    custom.title = title
                else
                    txn:setCustomMenu(view, id, { title = title })
                    local id_parent = findIdLocation(native, id)
                    if id_parent then
                        txn:setParentOverride(view, id, {
                            provider = nil,
                            parent = id_parent,
                        })
                    end
                end
                imported = imported + 1
            end
        end
    end

    local brand_new_levels = {}
    for _, menu_id in ipairs(native_keys) do
        local new_list = native[menu_id]
        local old_list = baseline[menu_id]
        if old_list == nil and not RESERVED[menu_id] and type(new_list) == "table" then
            local default_menu = reg.menus[menu_id]
            if default_menu and type(default_menu.list) == "table" then
                if fingerprint(new_list) == fingerprint(default_menu.list) then
                    baseline[menu_id] = new_list
                else
                    baseline[menu_id] = default_menu.list
                end
            else
                brand_new_levels[menu_id] = true
                txn:setRawOverride(view, menu_id, (function()
                    local s = {}
                    for _, x in ipairs(new_list) do
                        if type(x) == "string" and x ~= SEPARATOR_ID then
                            table.insert(s, x)
                        end
                    end
                    return s
                end)())
                local parent = findIdLocation(native, menu_id)
                if parent then
                    local titles = type(native[CUSTOM_SUBMENUS_KEY]) == "table"
                        and native[CUSTOM_SUBMENUS_KEY] or {}
                    txn:setCustomMenu(view, menu_id, {
                        title = type(titles[menu_id]) == "string"
                            and titles[menu_id] or menu_id,
                    })
                    txn:setParentOverride(view, menu_id, {
                        provider = nil,
                        parent = parent,
                    })
                end
                imported = imported + 1
            end
        end
    end

    -- Pass 2: Process membership claims, reorders, and remaining reserved maps
    local membership_claims = {}
    for _, menu_id in ipairs(native_keys) do
        local new_list = native[menu_id]
        local old_list = baseline[menu_id]
        if not brand_new_levels[menu_id] and menu_id ~= CUSTOM_SUBMENUS_KEY then
            if RESERVED[menu_id] then
                if menu_id == MENU_BUTTONS_KEY then
                    if fingerprint(new_list) ~= (old_list and fingerprint(old_list)) then
                        local default_same = fingerprint(new_list) == fingerprint(reg.tab_list)
                        txn:setTabOrder(view, default_same and nil or new_list)
                        imported = imported + 1
                    end
                elseif menu_id == DISABLED_KEY then
                    importDisabledChanges(new_list, old_list)
                end
            elseif type(new_list) == "table" then
                if fingerprint(new_list) ~= (old_list and fingerprint(old_list)) then
                -- User-authored change for this level. Prefer the MINIMAL
                -- semantic action: one relocated row becomes a position
                -- anchor, so untouched neighbours keep following upstream
                -- KOReader reorders. Only genuinely unrepresentable changes
                -- (multi-swaps, arbitrary shuffles) freeze an explicit bulk
                -- sequence - and even that only for the ids the user actually
                -- rearranged, never as a whole-menu snapshot.
                -- EXCEPTION: when a frozen order_override already exists for
                -- this level, the override IS the arrangement baseline. An
                -- external edit must refresh that sequence (or clear it),
                -- never layer position anchors beside it - anchors cannot
                -- express "this row precedes another sequenced row" against
                -- an existing curated list, and the stale override would keep
                -- winning in the materializer while the projection silently
                -- disagreed with persisted intent.
                local has_frozen_override = txn:view(view).order_override[menu_id] ~= nil
                local diff = SemanticDiff.infer_list_change(
                    type(old_list) == "table" and old_list or {},
                    new_list)
                if diff == nil then
                    -- Ordering unchanged; any separator-only movement is
                    -- handled below.
                elseif diff.kind == "single_move" and not has_frozen_override then
                    txn:setPositionOverride(view, diff.id, {
                        after = diff.after,
                        provider = reg.nodes[diff.id]
                            and reg.nodes[diff.id].provider or nil,
                    })
                elseif diff.kind == "removal" then
                    -- Pure deletion: survivors keep their relative order, so
                    -- NO ordering record is created - upstream reorders of
                    -- the remaining rows must keep flowing through. If OUR
                    -- OWN frozen sequence still lists a removed id, strip it
                    -- (and its era stamp) or the stale entry would resurrect
                    -- the row on every materialization.
                    local section_now = txn:view(view)
                    if type(section_now.order_override[menu_id]) == "table" then
                        local gone = {}
                        for _, id in ipairs(diff.removed or {}) do gone[id] = true end
                        local old_record = section_now.order_override[menu_id]
                        local kept = {}
                        for _, entry in ipairs(type(old_record) == "table"
                                and old_record.entries or {}) do
                            local entry_id = MenuSchema.isSeparatorEntry(entry)
                                and MenuSchema.SEPARATOR_ID or entry.id
                            if not gone[entry_id] then table.insert(kept, entry) end
                        end
                        if #kept > 0 then
                            txn:view(view).order_override[menu_id] =
                                { entries = kept }
                        else
                            txn:setOrderOverride(view, menu_id, nil)
                        end
                    end
                elseif diff.kind == "addition" and not has_frozen_override then
                    -- Pure insertion (update arrival, hand-added row):
                    -- incumbents keep their relative order; the newcomers
                    -- slot-align against stock positions at materialization.
                    -- Record NOTHING for the ORDER of incumbents - the id set
                    -- is world state, not intent. But a hand-ADDED row's
                    -- position IS user intent: anchor each added row at its
                    -- observed slot (predecessor in the edited list) so the
                    -- materializer reproduces the hand placement instead of
                    -- appending unknown ids to the level's tail.
                    local old_set = {}
                    for _, id in ipairs(old_list or {}) do
                        old_set[id] = true
                    end
                    for new_idx, id in ipairs(new_list) do
                        if not old_set[id] and reg.nodes[id] == nil then
                            local after = false
                            for j = new_idx - 1, 1, -1 do
                                if new_list[j] ~= SEPARATOR_ID then
                                    after = new_list[j]
                                    break
                                end
                            end
                            txn:setPositionOverride(view, id, {
                                after = after,
                                provider = nil,
                            })
                        end
                    end
                else
                    -- bulk / reversal / block: explicit curated sequence for
                    -- this level, era-stamped like every bulk write.
                    local custom_menus = txn:view(view).custom_menus
                    local seq = {}
                    for _, id in ipairs(new_list) do
                        if id ~= SEPARATOR_ID and not disabled_ids[id]
                                and (reg.nodes[id] ~= nil
                                    or (custom_menus and custom_menus[id] ~= nil)) then
                            table.insert(seq, id)
                        end
                    end
                    local seq_eras = {}
                    for _, x in ipairs(seq) do
                        local node = reg.nodes[x]
                        seq_eras[x] = node and node.provider or nil
                    end
                    local default_items = {}
                    for _, id in ipairs(reg.menus[menu_id]
                            and reg.menus[menu_id].list or {}) do
                        if id ~= SEPARATOR_ID then
                            default_items[#default_items + 1] = id
                        end
                    end
                    if Materializer.listEquals(seq, default_items) then
                        txn:setOrderOverride(view, menu_id, nil)
                    elseif #seq > 0 then
                        txn:setOrderOverride(view, menu_id, seq, seq_eras)
                    else
                        txn:setOrderOverride(view, menu_id, nil)
                    end
                end

                -- Separator bookkeeping: rebuild records from the observed
                -- placement ONLY where separators actually changed relative
                -- to the last emission. Unchanged dividers are left alone so
                -- stock-position interleaving keeps flowing through updates;
                -- a full-file hand edit therefore no longer litters intent
                -- with one record per stock divider of every level.
                local function sep_anchors(list)
                    local anchors, prev = {}, false
                    for _, id in ipairs(type(list) == "table" and list or {}) do
                        if id == SEPARATOR_ID then
                            table.insert(anchors, prev)
                        else
                            prev = id
                        end
                    end
                    return anchors
                end
                local old_anchors = sep_anchors(old_list)
                local new_anchors = sep_anchors(new_list)
                local same_anchors = #old_anchors == #new_anchors
                if same_anchors then
                    for i = 1, #old_anchors do
                        if old_anchors[i] ~= new_anchors[i] then
                            same_anchors = false
                            break
                        end
                    end
                end
                if not same_anchors then
                    -- Divider records changed relative to the old emission.
                    -- Drop this level's previous ext records AND any user sep_N
                    -- records parented here (their anchors described the OLD
                    -- arrangement; deficits are removals - nothing to record,
                    -- the stock flow resumes), then re-record ONLY anchors
                    -- that are genuinely new relative to the old emission,
                    -- compared as a MULTISET of anchor values (an insertion
                    -- shifts every later index, so positional diff would
                    -- mislabel stable dividers as changed).
                    local section_now = txn:view(view)
                    for key in pairs(section_now.separators or {}) do
                        local sep = section_now.separators[key]
                        local is_ext = type(key) == "string"
                            and key:find("^" .. menu_id .. "_ext_%d+$")
                        local is_user_here = type(sep) == "table"
                            and sep.parent == menu_id
                        if is_ext or is_user_here then
                            section_now.separators[key] = nil
                        end
                    end
                    local old_counts = {}
                    for _, a in ipairs(old_anchors) do
                        local k = tostring(a)
                        old_counts[k] = (old_counts[k] or 0) + 1
                    end
                    for i, anchor in ipairs(new_anchors) do
                        local k = tostring(anchor)
                        if (old_counts[k] or 0) > 0 then
                            old_counts[k] = old_counts[k] - 1   -- unchanged
                        else
                            txn:setSeparator(view,
                                string.format("%s_ext_%d", menu_id, i), {
                                    parent = menu_id,
                                    after = anchor == false and false
                                        or anchor,
                                })
                        end
                    end
                end

                local custom_menus = txn:view(view).custom_menus
                local is_bulk = diff and diff.kind ~= "single_move" and diff.kind ~= "addition" and diff.kind ~= "removal"
                for _, id in ipairs(new_list) do
                    if id ~= SEPARATOR_ID then
                        local skip_claim = is_bulk and (reg.nodes[id] == nil and (not custom_menus or custom_menus[id] == nil))
                        if not skip_claim then
                            membership_claims[id] = membership_claims[id] or {}
                            table.insert(membership_claims[id], menu_id)
                        end
                    end
                end
                imported = imported + 1
            end
        end
    end
end

    -- Omitting a reserved key that existed in the previous emission is an
    -- explicit deletion.  In particular, deleting KOMenu:disabled means
    -- "unhide all", not "leave canonical tombstones untouched".
    if native[DISABLED_KEY] == nil and last[DISABLED_KEY] ~= nil then
        importDisabledChanges({}, last[DISABLED_KEY])
    end

    -- Resolve cross-parent claims: prefer the customized (non-default)
    -- claimant; ties break alphabetically. A claim matching the id's current
    -- effective parent records nothing (sparseness).
    local claim_ids = {}
    for id in pairs(membership_claims) do table.insert(claim_ids, id) end
    table.sort(claim_ids)
    for _, id in ipairs(claim_ids) do
        local claimants = membership_claims[id]
        table.sort(claimants)
        local node = reg.nodes[id]
        local default_parent = node and node.default_parent or nil
        local non_default = {}
        for _, m in ipairs(claimants) do
            if m ~= default_parent and m ~= id then table.insert(non_default, m) end
        end
        local valid_claimants = {}
        for _, m in ipairs(claimants) do
            if m ~= id then table.insert(valid_claimants, m) end
        end
        local chosen = non_default[1] or valid_claimants[1] or claimants[1]
        if #claimants > 1 then
            logger.warn("ReorderingMenus:", id, "listed under",
                table.concat(claimants, ", "), "in the edited", view,
                "order; keeping", chosen)
        end
        if not disabled_ids[id] and chosen ~= id then
            local section_now = txn:view(view)
            -- Centralized placement gate: never record an unsupported
            -- STRUCTURAL claim (tab_nesting etc.). Vanished containers stay
            -- recordable (dormancy); the resolve fallback + validator keep
            -- the world render-safe; the hand edit stays on disk.
            local ok_claim, claim_reason = Placement.canPlace(reg, section_now, id, chosen)
            if not ok_claim and claim_reason ~= Placement.REASONS.UNKNOWN_PARENT then
                logger.warn("ReorderingMenus: ignoring unsupported membership claim",
                    id, "->", chosen)
            else
                local current = Materializer.effectiveParent(reg, section_now, id)
                if current ~= chosen then
                    txn:setParentOverride(view, id, {
                        provider = node and node.provider or nil,
                        parent = chosen,
                    })
                end
            end
        end
    end
    pcall(function() return Placement.sanitizeSection(reg, txn:view(view)) end)

    return imported > 0, STATUS.IMPORTED_EXTERNAL
end

return NativeWriter

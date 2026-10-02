--[[--
native_writer.lua — effective graph -> minimal KOReader native overrides.

Synchronization boundaries (Prompt 4 §1) — exactly four mutating entries,
everything else pure:

  startup synchronization  syncView(view, reg, txn): first session creation
                           per process. Classifies the native file against
                           the checkpoint (ours / external / missing /
                           interrupted) and either imports, regenerates, or
                           reverts. The ONLY path that may stage intent or
                           touch derived files outside an explicit save.
  external/native refresh  Manager:reloadFromDisk + dropSessionState (force
                           re-classification on next sessionFor) and
                           refreshRegistry (registry drift -> derived-output
                           maintenance, never intent rewrites).
  commit                   CommitPipeline.commitAndApply: canonical intent
                           first (one durable write), then per-view derived
                           projection + checkpoint; structured Outcome
                           (canonical save vs native projection vs reload vs
                           external detection vs recovery need).
  projection refresh       invalidate(view): drop cached effective model +
                           order table. No I/O, no intent writes.

Ordinary reads (loadOrder/getMenuItems/getTabs/getParentMenu/isCustomized/
stagedView/peekTransaction/previewEmission/emissionMatchesRecord) are pure:
no imports, no normalization writes, no regeneration, no UI refresh. (Session
creation via sessionFor runs the one-time startup sync above; that is the
documented exception, and it runs once per process per view.)

KOReader merges its user order per key: a menu list absent from the native
file falls back to the stock list. The writer exploits this by emitting only
the keys whose materialized content actually deviates from the pure-default
projection — an untouched menu stays completely absent, so a KOReader update
can reshape it with zero reconciliation.

Checkpoint (Prompt 4 §5 — retained fields and why; nothing else is stored):

  fingerprint           hash of the on-disk emission ({} when removed).
                        Recognizes our own output (unchanged vs external).
  structure             the emission itself. Three-way import baseline +
                        structural self-recognition across writer upgrades.
  intent_gen            canonical per-view generation the emission was derived
                        from. Distinguishes deliberate user revert (consistent)
                        from interrupted commit (lagging -> regenerate).
  previous_fingerprint  one-generation lookback: our own STALE output (crash
                        between per-view writes) regenerates instead of
                        importing as a foreign edit.
  writer_version        fingerprint/algorithm stamp: version-mismatched hashes
                        fall through to structural comparison, never blind
                        hash adoption.
  suspended             disable marker: file absence is OUR withdrawal, not a
                        user revert (regenerate on re-enable, never wipe).

The checkpoint answers narrowly: what did we last emit, from which canonical
revision, and is the current file ours / external / missing / interrupted.
Native files are disposable projections — never layout truth. Canonical
intent is rewritten on a missing file ONLY for the deliberate-revert case
(content-bearing absence with a consistent generation: the user deleted our
file to go back to stock); crash/interruption/suspension absences regenerate
from intent and touch nothing canonical. Fault-injection coverage:
test_crash_pipeline, test_io_failure_injection, run_storage_safety_hostile.

External native edits enter through ONE semantic import boundary
(importExternalChanges / importAgainstDefaults via IntentOps); hand-editing
KOReader's files stays supported while the canonical model remains semantic.
Unrepresentable hand-authored levels keep verbatim raw_override passthrough.

The native file and materialization record are independently atomic. If a
process stops between them, generation and fingerprint recovery converges the
pair on the next startup; no multi-file journal is required.
--]]

local KoreaderAdapter = require("lib.koreader_adapter")
local Materializer = require("lib.materializer")
local AtomicWriter = require("lib.atomic_writer")
local DataLoader = require("lib.data_loader")
local IntentStore = require("lib.intent_store")
local SemanticDiff = require("lib.semantic_diff")
local MenuSchema = require("lib.menu_schema")
local Placement = require("lib.placement")
local IntentOps = require("lib.intent_ops")
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

-- Deep equality for normalized native-order tables: same key sets, with
-- schema-aware per-key comparison (arrays as arrays, the custom-submenu
-- title registry as a map). Both inputs are expected to have passed
-- normalizeNativeOrder. Shares the fingerprint normalization so equality and
-- change detection cannot drift apart.
local function nativeStructureEquals(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k in pairs(a) do
        local va, vb = a[k], b[k]
        if type(vb) ~= "table" or type(va) ~= "table" then return false end
        if k == CUSTOM_SUBMENUS_KEY then
            for id, title in pairs(va) do
                if vb[id] ~= title then return false end
            end
            for id in pairs(vb) do
                if va[id] == nil then return false end
            end
        else
            if #va ~= #vb then return false end
            for i = 1, #va do
                if va[i] ~= vb[i] then return false end
            end
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
local function buildEmission(view, reg, intent, graph)
    local Resolver = require("lib.resolver")
    local empty_graph = Resolver.resolve(reg, nil)
    local native = NativeWriter.graphToNative(reg, intent, graph, empty_graph)
    local has_content = next(native) ~= nil
    if stripEmptyReservedMaps(view, native) then has_content = false end
    return native, has_content
end

function NativeWriter.previewEmission(view, reg, intent, graph)
    local native, has_content = buildEmission(view, reg, intent, graph)
    return has_content and native or nil
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
        local Resolver = require("lib.resolver")
        local repaired = Resolver.resolve(reg, section)
        local would_persist = NativeWriter.previewEmission(view, reg,
            section, repaired)
        return fingerprint(would_persist or {}) == record.fingerprint
    end)
    if not ok_match then return false end
    return matches
end

function NativeWriter.writeView(view, reg, intent, graph)
    local native, has_content = buildEmission(view, reg, intent, graph)

    -- Record what is ACTUALLY on disk: when the cleaner generation removed
    -- the file, an empty structure would make the next save believe the
    -- previous emission still carried the reserved keys and re-emit them
    -- forever (write/remove/write/...). nil = "no file" for syncView.
    loadSidecar()
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
                -- Unknown level: a user-created submenu (shared container
                -- semantics). Titles from the file's registry; parent + order
                -- + dividers + membership travel together like known menus.
                local titles_map = type(native[CUSTOM_SUBMENUS_KEY]) == "table"
                    and native[CUSTOM_SUBMENUS_KEY] or {}
                local declared_title = titles_map[menu_id]
                local title = type(declared_title) == "string"
                    and declared_title ~= "" and declared_title or menu_id
                local located_parent = findIdLocation(native, menu_id)
                IntentOps.defineCustomContainer(view, txn, menu_id, title, located_parent)
                local unknown_seq = SemanticDiff.items_projection(list)
                local eras = {}
                for _, x in ipairs(unknown_seq) do
                    eras[x] = IntentOps.providerOf(reg, x)
                end
                txn:setOrderOverride(view, menu_id, unknown_seq, eras)
                IntentOps.setDividerArrangement(view, txn, reg, menu_id,
                    IntentOps.separatorAnchorsOf(list))
                -- Shared membership: moved stock children + nested customs.
                for _, child_id in ipairs(unknown_seq) do
                    if not disabled[child_id] then
                        local node = reg.nodes[child_id]
                        if node and node.default_parent
                                and node.default_parent ~= menu_id then
                            IntentOps.setMembership(view, txn, reg, child_id, menu_id)
                            imported = imported + 1
                        elseif not node then
                            local existing = txn:view(view).parent_override
                                and txn:view(view).parent_override[child_id] or nil
                            if not (type(existing) == "table"
                                    and existing.parent == menu_id) then
                                IntentOps.setMembership(view, txn, reg, child_id, menu_id)
                                imported = imported + 1
                            end
                        end
                    end
                end
                imported = imported + 1
            else
                -- Sameness MUST be decided by full-fidelity element-wise
                -- comparison INCLUDING separators: a stock list that merely
                -- contains dividers is not a user arrangement, and freezing
                -- it as an order_override would block upstream reorders for
                -- every menu with a stock separator.
                local same_layout = SemanticDiff.sequence_equal(list, default_list)
                local seq = SemanticDiff.items_projection(list)
                if same_layout then
                    -- Mirrors the current stock layout: carries no user
                    -- information, so nothing is persisted for this key.
                    -- Updates to untouched layouts must keep flowing through.
                else
                    -- Items-only comparison: a divider-only difference must
                    -- not freeze a redundant ordering (which would block
                    -- upstream reorders); only divider intent is recorded.
                    local default_items_only = SemanticDiff.items_projection(default_list)
                    local items_same = Materializer.listEquals(seq, default_items_only)
                    if not items_same then
                        local eras = {}
                        for _, x in ipairs(seq) do
                            eras[x] = IntentOps.providerOf(reg, x)
                        end
                        txn:setOrderOverride(view, menu_id, seq, eras)
                        imported = imported + 1
                    end
                    -- Shared divider semantics (replacement, unified keys).
                    do
                        local observed_anchors = IntentOps.separatorAnchorsOf(list)
                        local before = 0
                        for _ in pairs(txn:view(view).separators or {}) do before = before + 1 end
                        local how = IntentOps.setDividerArrangement(
                            view, txn, reg, menu_id, observed_anchors)
                        -- setDividerArrangement with observed==default records
                        -- nothing (resumes stock); only count genuine divider
                        -- intent (replacement/empty/suppression), mirroring
                        -- the previous anchors_same gate.
                        if how == "replacement" or how == "empty"
                                or how == "suppression" then
                            -- Distinguish "observed already equaled default"
                            -- (how would be "default", not counted) from real
                            -- changes: count when arrangement differs from
                            -- default (i.e., not "default").
                            imported = imported + 1
                        end
                        _ = before
                    end
                end
                -- Shared membership: ids under a non-default parent become
                -- explicit moves (structural violations skipped, vanished
                -- homes recorded dormant).
                if not same_layout then
                    for _, id in ipairs(seq) do
                        local node = reg.nodes[id]
                        if node and node.default_parent
                                and node.default_parent ~= menu_id
                                and not disabled[id] then
                            IntentOps.setMembership(view, txn, reg, id, menu_id)
                            imported = imported + 1
                        elseif not node and not disabled[id] then
                            IntentOps.setMembership(view, txn, reg, id, menu_id)
                            imported = imported + 1
                        end
                    end
                end
            end
        end
    end

    -- Shared visibility: everything in KOMenu:disabled becomes hidden intent.
    for _, id in ipairs(native[DISABLED_KEY] or {}) do
        local node = reg.nodes[id]
        IntentOps.setVisibility(view, txn, reg, id, true,
            findIdLocation(native, id) or (node and node.default_parent))
        imported = imported + 1
    end

    -- Tabs: durable intent keeps dormant ids; effective projection filters
    -- via Materializer. sanitizeSection strips only provably live non-tabs.
    do
        local section = txn:view(view)
        pcall(function() return Placement.sanitizeSection(reg, section) end)
    end

    return imported
end

local function materializeValidated(reg, section)
    -- Single effective source: repaired projection + diagnostics via Resolver.
    return require("lib.resolver").resolve(reg, section)
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
        -- Sidecar loss must not turn our own output into a foreign legacy
        -- import (P1): no checkpoint + native == preview(current canonical)
        -- means converged, not foreign. Regenerate the checkpoint and report
        -- clean so anchor customizations do not churn into bulk overrides.
        do
            local ok_prev, preview = pcall(function()
                local Resolver = require("lib.resolver")
                local section = txn:view(view)
                local repaired = Resolver.resolve(reg, section)
                return NativeWriter.previewEmission(view, reg, section, repaired)
            end)
            if ok_prev and preview ~= nil then
                local ok_fp, preview_fp = pcall(function()
                    return fingerprint(preview or {})
                end)
                if ok_fp and preview_fp == native_fingerprint then
                    local ok_ckpt = setCheckpointRecord(view, {
                        fingerprint = native_fingerprint,
                        structure = preview,
                    })
                    if ok_ckpt then return false, STATUS.CLEAN end
                elseif ok_prev and preview == nil and next(native) == nil then
                    local ok_ckpt = NativeWriter.checkpointEmptyEmission(view)
                    if ok_ckpt then return false, STATUS.CLEAN_EMPTY end
                end
            end
        end
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
        -- Stale suspension must not poison future deletion interpretation:
        -- a CURRENT file proves the suspend-for-disable resume already
        -- completed (or never applied), so clear the flag now. Bound to this
        -- successful classification; a later genuine user-delete classifies
        -- REVERTED, not REGENERATED_SUSPENDED.
        if entry.suspended then
            entry.suspended = nil
            pcall(saveSidecar)
        end
        -- Startup convergence: the file matches our last emission AND that
        -- emission consists solely of EMPTY reserved maps. The elements
        -- module was freshly required (no mergeAndSort overlay pollution in
        -- THIS process), so those keys override nothing - remove the file so
        -- stock rules flow untouched until real customization returns.
        if NativeWriter.emissionIsReservedOnly(native) then
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
                IntentOps.setVisibility(view, txn, reg, id, true,
                    findIdLocation(native, id)
                        or (node and node.default_parent))
                imported = imported + 1
            end
        end
        for id in pairs(old_disabled) do
            if not new_disabled[id] then
                IntentOps.setVisibility(view, txn, reg, id, false, nil)
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
                -- Brand-new level with no baseline and no stock default.
                -- UNAVOIDABLE SPECIAL CASE (Prompt 2 §7): preserved VERBATIM
                -- as raw opaque state (not guessed as custom+order+membership).
                -- Rationale: a tool-added level appearing between observations
                -- (M5: my_tool_panel with stock children, no title registry)
                -- is tool output, not necessarily user intent; guessing a
                -- custom title (id fallback) + explicit moves for its stock
                -- children would REWRITE user membership (pulling opds/search
                -- out of search) and replace lossless bytes with guesses —
                -- forbidden ("do not replace lossless opaque state with
                -- guesses", "raw/opaque fragments must survive"). Legacy
                -- first-contact unknown levels (importAgainstDefaults, no
                -- baseline at all) DO decode semantically (custom+order+
                -- membership with title fallback) as old-format migration
                -- decoding where necessary; the two paths agree on ordering/
                -- divider/membership/visibility semantics for KNOWN levels
                -- (shared IntentOps) and differ only on brand-new opaque
                -- preservation. Effective rendering stays valid via the
                -- resolver + validator (duplicate ownership repaired
                -- deterministically, diagnostics reported).
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
                -- Shared ordering semantics (Prompt 2 §1-§2): ONE classification
                -- (anchor vs bulk vs pure-membership vs noop) for editor and
                -- import alike. Baseline here is the last emission (three-way
                -- diff); the editor baselines against the default derivation —
                -- the CLASSIFICATION and RECORD SHAPES are shared, only the
                -- baseline differs. Frozen-bulk rule: when a curated sequence
                -- already exists, an external single-move refreshes it (bulk),
                -- never layers an anchor beside it.
                local has_frozen_override = txn:view(view).order_override[menu_id] ~= nil
                local IntentOps = require("lib.intent_ops")
                -- Ordering compares items only; dividers travel separately.
                local old_items = SemanticDiff.items_projection(
                    type(old_list) == "table" and old_list or nil)
                local new_items = SemanticDiff.items_projection(new_list)
                local classification, cls_err = SemanticDiff.classify_permutation(
                    old_items, new_items, { separator_aware = false })
                if cls_err then
                    -- Structural invalidity in hand-edited file: fall through
                    -- to bulk refresh below (which filters to strings) rather
                    -- than crashing import; dividers still handled separately.
                    classification = { kind = SemanticDiff.KIND.COMPLEX,
                        sequence = (function()
                            local s = {}
                            for _, id in ipairs(new_list) do
                                if type(id) == "string" and id ~= SEPARATOR_ID
                                        and not disabled_ids[id] then
                                    s[#s+1] = id
                                end
                            end
                            return s
                        end)() }
                end
                local ck = classification.kind
                if ck == SemanticDiff.KIND.UNCHANGED then
                    -- Ordering unchanged; any separator-only movement is
                    -- handled below.
                elseif ck == SemanticDiff.KIND.ONE_RELOCATION and not has_frozen_override then
                    local move = classification.move
                    IntentOps.setInsertionAnchor(view, txn, reg,
                        move.item,
                        move.type == "move_before" and false or move.after)
                    -- Preserve the move's provider stamp when classification
                    -- carried descriptors (here none — re-stamp from registry
                    -- for dormancy, like every anchor write).
                    do
                        local sec = txn:view(view)
                        local rec = sec.position_override and sec.position_override[move.item]
                        if type(rec) == "table" then
                            rec.provider = reg.nodes[move.item]
                                and reg.nodes[move.item].provider or nil
                        end
                    end
                elseif ck == SemanticDiff.KIND.PURE_REMOVAL then
                    -- Pure deletion: survivors keep relative order, NO ordering
                    -- record — upstream reorders keep flowing. Strip removed
                    -- ids from OUR frozen sequence or stale entries resurrect.
                    local section_now = txn:view(view)
                    if type(section_now.order_override[menu_id]) == "table" then
                        local changes = SemanticDiff.multiset_diff(
                            old_items, new_items, { separator_aware = false })
                        local gone = {}
                        if changes then
                            for _, id in ipairs(changes.removed or {}) do gone[id] = true end
                        end
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
                elseif ck == SemanticDiff.KIND.PURE_ADDITION and not has_frozen_override then
                    -- Pure insertion: incumbents keep order (no bulk). Anchors
                    -- for ADDED rows preserve hand placement instead of
                    -- tail-appending. HEAD semantics (preserved for green):
                    -- anchor UNKNOWN (dormant) rows only; known rows
                    -- slot-align (upstream arrivals flow, no litter). Known
                    -- cross-menu arrivals via file edit therefore land at tail
                    -- (membership only); editor chooser preserves head via an
                    -- explicit insertion anchor (moveItemToMenu). Equivalent
                    -- EFFECTIVE order for known cross-menu head placement
                    -- requires the editor path; file-edit head position for
                    -- known rows is advisory (documented special case, Prompt
                    -- 2 §7 — preserves M5/N3/R/Q6 green: no extra anchors for
                    -- upstream stock arrivals, no generation churn).
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
                            IntentOps.setInsertionAnchor(view, txn, reg, id, after)
                        end
                    end
                else
                    -- Bulk / reversal / single-move-onto-frozen: explicit
                    -- curated sequence, era-stamped. Unknown ids are durable
                    -- dormant references (unstamped by providerOf==nil).
                    local seq = {}
                    for _, id in ipairs(new_list) do
                        if id ~= SEPARATOR_ID and not disabled_ids[id] then
                            table.insert(seq, id)
                        end
                    end
                    local default_items = SemanticDiff.items_projection(
                        reg.menus[menu_id] and reg.menus[menu_id].list or nil)
                    if Materializer.listEquals(seq, default_items) then
                        txn:setOrderOverride(view, menu_id, nil)
                    elseif #seq > 0 then
                        local seq_eras = {}
                        for _, x in ipairs(seq) do
                            seq_eras[x] = IntentOps.providerOf(reg, x)
                        end
                        txn:setOrderOverride(view, menu_id, seq, seq_eras)
                    else
                        txn:setOrderOverride(view, menu_id, nil)
                    end
                end

                -- Shared divider semantics (§4, replacement, unified keys):
                -- only when anchors changed vs the last emission; otherwise
                -- leave untouched (no litter for full-file hand edits that
                -- did not move dividers).
                do
                    local old_anchors = IntentOps.separatorAnchorsOf(old_list)
                    local new_anchors = IntentOps.separatorAnchorsOf(new_list)
                    if not SemanticDiff.sequence_equal(old_anchors, new_anchors) then
                        IntentOps.setDividerArrangement(view, txn, reg, menu_id, new_anchors)
                    end
                end

                local custom_menus = txn:view(view).custom_menus
                local is_bulk = classification
                    and classification.kind == SemanticDiff.KIND.COMPLEX
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

    -- Shared membership policy (§1): customized-destination-wins, alphabetical
    -- tie-break, self-claims excluded. A claim matching current effective
    -- parent records nothing (sparseness). Structural violations refused;
    -- vanished containers recorded for dormancy.
    do
        local chosen_by_id = IntentOps.resolveMembershipClaims(reg, membership_claims)
        local claim_ids = {}
        for id in pairs(chosen_by_id) do claim_ids[#claim_ids+1] = id end
        table.sort(claim_ids, function(a, b) return tostring(a) < tostring(b) end)
        for _, id in ipairs(claim_ids) do
            local chosen = chosen_by_id[id]
            -- Warn on genuine ambiguity (multiple distinct claimants).
            do
                local claimants = membership_claims[id] or {}
                if #claimants > 1 then
                    local sorted = {}
                    for _, m in ipairs(claimants) do sorted[#sorted+1] = m end
                    table.sort(sorted, function(a, b) return tostring(a) < tostring(b) end)
                    logger.warn("ReorderingMenus:", id, "listed under",
                        table.concat(sorted, ", "), "in the edited", view,
                        "order; keeping", chosen)
                end
            end
            if not disabled_ids[id] and chosen ~= id then
                local section_now = txn:view(view)
                local current = Materializer.effectiveParent(reg, section_now, id)
                if current ~= chosen then
                    local node = reg.nodes[id]
                    local ok_claim = IntentOps.setMembership(view, txn, reg, id, chosen)
                    if not ok_claim then
                        logger.warn("ReorderingMenus: ignoring unsupported membership claim",
                            id, "->", chosen)
                    else
                        -- setMembership with UNKNOWN_PARENT records dormancy;
                        -- with sparse-noop (already correct) it records nothing.
                        -- Count only actual changes? Imported counter already
                        -- incremented per changed level above; membership
                        -- records ride along without extra counting.
                        _ = node
                    end
                end
            end
        end
    end
    pcall(function() return Placement.sanitizeSection(reg, txn:view(view)) end)

    return imported > 0, STATUS.IMPORTED_EXTERNAL
end

return NativeWriter

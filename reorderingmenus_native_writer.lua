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

local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
local Materializer = require("reorderingmenus_materializer")
local Validator = require("reorderingmenus_validator")
local AtomicWriter = require("reorderingmenus_atomic_writer")
local IntentStore = require("reorderingmenus_intent_store")
local SemanticDiff = require("reorderingmenus_semantic_diff")
local MenuSchema = require("reorderingmenus_menu_schema")
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
    local data
    local path = sidecarPath()
    if lfs.attributes(path, "mode") == "file" then
        local ok, res = pcall(dofile, path)
        if ok and type(res) == "table" then data = res end
    end
    if not data or type(data.views) ~= "table" then data = { views = {} } end
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
    for key in pairs(native) do
        if not RESERVED[key] then return false end
    end
    local record = loadSidecar().views[view]
    local previous = record and record.structure
    for _, key in ipairs({ DISABLED_KEY, CUSTOM_SUBMENUS_KEY }) do
        local value = type(previous) == "table" and previous[key] or nil
        if type(value) == "table" and next(value) ~= nil then return false end
        if type(value) == "string" then return false end
    end
    native[DISABLED_KEY] = nil
    native[CUSTOM_SUBMENUS_KEY] = nil
    return next(native) == nil
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
    local prev_record = record
    record = {
        fingerprint = fingerprint(on_disk_native or {}),
        structure = on_disk_native,
        intent_gen = IntentStore.generation(view),
        writer_version = WRITER_VERSION,
    }
    if prev_record then
        record.previous_fingerprint = prev_record.fingerprint
        record.previous_structure = prev_record.structure
    end
    loadSidecar().views[view] = record
    local ok_sidecar, sidecar_err = saveSidecar()
    if not ok_sidecar then
        loadSidecar().views[view] = prev_record
        return false, native, sidecar_err
    end
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
                txn:setCustomMenu(view, menu_id, {
                    title = menu_id,
                    parent = findIdLocation(native, menu_id),
                })
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
                if not same_layout then
                    for _, id in ipairs(seq) do
                        local node = reg.nodes[id]
                        if node and node.default_parent
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

    return imported
end

local function materializeValidated(reg, section)
    local graph = Materializer.resolve(reg, section)
    local _, repaired = Validator.validate(graph, reg, section)
    return repaired
end

local function regenerateView(view, reg, txn)
    local section = txn:view(view)
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
    if not ok then return false, "regeneration_failed" end
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
    if not entry then return "legacy" end
    if not was_clean then return "malformed" end
    if entry.fingerprint == native_fingerprint then return "current" end
    if entry.previous_fingerprint ~= nil
            and entry.previous_fingerprint == native_fingerprint then
        return "stale"
    end
    return "external"
end

local importExternalChanges

-- Startup sync for one view. Returns changed(bool), mode(string).
function NativeWriter.syncView(view, reg, txn)
    local native = KoreaderAdapter.readNativeOrder(view)
    local entry = NativeWriter.getRecord(view)

    if not native and not KoreaderAdapter.nativeFileExists(view) then
        if entry then
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
                    "regenerated_interrupted")
            end
            if had_content then
                -- The file we generated was deleted: treat as full revert.
                txn:resetView(view)
                local ok_clear = NativeWriter.clearRecord(view)
                if not ok_clear then return false, "record_clear_failed" end
                return true, "reverted"
            end
            local ok_clear = NativeWriter.clearRecord(view)
            if not ok_clear then return false, "record_clear_failed" end
            return false, "clean_empty"
        end
        return false, "clean"
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
        return regenerateForStartup(view, reg, txn, "regenerated")
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

    if native_state == "legacy" then
        local imported = NativeWriter.importAgainstDefaults(view, reg, txn, native)
        return imported > 0, "imported_legacy"
    end

    if native_state == "malformed" then
        logger.warn("ReorderingMenus:", view,
            "native order file had malformed structure; regenerating from intent")
        return regenerateForStartup(view, reg, txn, "regenerated_malformed")
    end

    if native_state == "current" then
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
                "regenerated_lagging")
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
            if not ok_remove then return false, "remove_failed" end
            local ok_clear = NativeWriter.clearRecord(view)
            if not ok_clear then return false, "record_clear_failed" end
            return false, "converged_sparse"
        end
        return false, "unchanged"
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
    if native_state == "stale" then
        logger.info("ReorderingMenus:", view,
            "native file is a stale generation; regenerating from intent")
        return regenerateForStartup(view, reg, txn, "regenerated_stale")
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
        for _, coll in ipairs({ "hidden", "hidden_order", "parent_override",
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
                "regenerated_writer_upgrade")
        end
    end

    -- Externally edited: import every difference as explicit user intent.
    return importExternalChanges(view, reg, txn, native, entry)
end

-- Convert differences from a recognized, externally edited native file into
-- semantic intent. Startup classification stays in syncView; this helper owns
-- only the three-way import against the last emitted structure.
importExternalChanges = function(view, reg, txn, native, entry)
    local imported = 0
    local last = entry.structure or {}
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
                txn:clearHiddenAnchor(view, id)
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
    local membership_claims = {}
    for menu_id, new_list in pairs(native) do
        local old_list = last[menu_id]
        if old_list == nil and not RESERVED[menu_id] then
            -- Key absent from our last emission. That does NOT mean the user
            -- authored this whole arrangement: the level was probably sparse
            -- (equal to stock) before the edit, so the meaningful baseline is
            -- the STOCK default list. Diff against it; when nothing differs,
            -- the key carries no user information at all.
            local default_menu = reg.menus[menu_id]
            if default_menu and type(default_menu.list) == "table" then
                if fingerprint(new_list) == fingerprint(default_menu.list) then
                    -- Matches stock exactly -> carries no user information.
                    -- Mark the row as unchanged so the changed-level branch
                    -- below skips it (comparing against nil would treat ANY
                    -- list as newly authored).
                    old_list = new_list
                else
                    last[menu_id] = default_menu.list
                    -- The downstream check reads the LOCAL old_list captured
                    -- before this branch; it must see the baseline too.
                    old_list = default_menu.list
                end
            else
                -- Hand-authored BRAND-NEW level: no stock default, never
                -- emitted by us. Two hazards must both be avoided:
                --   (a) silently DROPPING the level on the next sparse write
                --       (user bytes lost), and
                --   (b) treating its rows as membership claims - a hand level
                --       listing KNOWN stock ids would otherwise steal them
                --       out of their real parents (single-parent repair),
                --       then the validator would cascade the orphaned level
                --       into KOMenu:disabled: visible rows vanish.
                -- Policy: preserve the authored arrangement VERBATIM as a raw
                -- override (native_writer re-emits raw levels byte-for-byte,
                -- even unreachable ones), and mark the level "unchanged" so
                -- the generic changed-level branch below neither freezes a
                -- bulk sequence nor records claims for it. Stock ignores an
                -- unreferenced key exactly like this - fidelity without
                -- corruption.
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
                        parent = parent,
                    })
                end
                imported = imported + 1
                old_list = new_list   -- handled: skip generic branch below
            end
        end
        if RESERVED[menu_id] then
            if menu_id == MENU_BUTTONS_KEY then
                if fingerprint(new_list) ~= (old_list and fingerprint(old_list)) then
                    local default_same = fingerprint(new_list) == fingerprint(reg.tab_list)
                    txn:setTabOrder(view, default_same and nil or new_list)
                    imported = imported + 1
                end
            elseif menu_id == DISABLED_KEY then
                importDisabledChanges(new_list, old_list)
            elseif menu_id == CUSTOM_SUBMENUS_KEY then
                local old_titles = type(old_list) == "table" and old_list or {}
                for id, title in pairs(new_list) do
                    if old_titles[id] ~= title and type(title) == "string" then
                        local custom = txn:getCustomMenus(view)[id]
                        if custom then
                            custom.title = title
                        else
                            txn:setCustomMenu(view, id, {
                                title = title,
                                parent = findIdLocation(native, id),
                            })
                        end
                        imported = imported + 1
                    end
                end
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
                        local kept = {}
                        for _, id in ipairs(section_now.order_override[menu_id]) do
                            if not gone[id] then table.insert(kept, id) end
                        end
                        if #kept > 0 then
                            local kept_eras = {}
                            local old_eras = section_now.sequence_eras
                                and section_now.sequence_eras[menu_id]
                            for _, id in ipairs(kept) do
                                kept_eras[id] = old_eras and old_eras[id] or nil
                            end
                            txn:setOrderOverride(view, menu_id, kept, kept_eras)
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
                    local seq = {}
                    for _, id in ipairs(new_list) do
                        if id ~= SEPARATOR_ID then
                            table.insert(seq, id)
                        end
                    end
                    local seq_eras = {}
                    for _, x in ipairs(seq) do
                        local node = reg.nodes[x]
                        seq_eras[x] = node and node.provider or nil
                    end
                    txn:setOrderOverride(view, menu_id, seq, seq_eras)
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

                for _, id in ipairs(new_list) do
                    if id ~= SEPARATOR_ID then
                        membership_claims[id] = membership_claims[id] or {}
                        table.insert(membership_claims[id], menu_id)
                    end
                end
                imported = imported + 1
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
    for id, claimants in pairs(membership_claims) do
        table.sort(claimants)
        local node = reg.nodes[id]
        local default_parent = node and node.default_parent or nil
        local non_default = {}
        for _, m in ipairs(claimants) do
            if m ~= default_parent then table.insert(non_default, m) end
        end
        local chosen = non_default[1] or claimants[1]
        if #claimants > 1 then
            logger.warn("ReorderingMenus:", id, "listed under",
                table.concat(claimants, ", "), "in the edited", view,
                "order; keeping", chosen)
        end
        if not disabled_ids[id] then
            local current = Materializer.effectiveParent(reg, txn:view(view), id)
            if current ~= chosen then
                txn:setParentOverride(view, id, {
                    provider = node and node.provider or nil,
                    parent = chosen,
                })
            end
        end
    end


    -- Hidden-row display anchors are auxiliary UI metadata.  Drop a string
    -- target only when it no longer exists in either the live registry, a
    -- custom submenu, or the edited native structure; `false` remains the
    -- valid start-of-list anchor.
    local present = {}
    for id in pairs(reg.nodes or {}) do present[id] = true end
    for id in pairs(txn:getCustomMenus(view) or {}) do present[id] = true end
    for _, list in pairs(native) do
        if type(list) == "table" then
            for _, id in ipairs(list) do
                if type(id) == "string" then present[id] = true end
            end
        end
    end
    for id, anchor in pairs(txn:getHiddenAnchors(view) or {}) do
        if type(anchor) == "string" and not present[anchor] then
            txn:clearHiddenAnchor(view, id)
            imported = imported + 1
        end
    end

    return imported > 0, "imported_external"
end

return NativeWriter

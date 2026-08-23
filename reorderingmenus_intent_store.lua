--[[--
intent_store.lua — the ONLY canonical persistent customization state.

Persists sparse declarative user intent, never resolved runtime menus. Every
menu KOReader renders is derived at runtime from (current defaults x intent),
so only actions the user actually performed are recorded here:

    hidden[id]            = { provider, origin }      -- deliberately invisible
    parent_override[id]   = { provider, parent }      -- deliberately placed here
    position_override[id] = { provider, after }       -- deliberately slotted
    order_override[menu]  = { seq... }                -- deliberately rearranged
    sequence_eras[menu]   = { [id] = provider }       -- era stamp per seq entry
    custom_menus[id]      = { title, parent, after }  -- user-created submenu
    separators[key]       = { parent, after }         -- user-inserted separator
    tab_order             = { seq... }                -- deliberately reordered tabs
    raw_override[menu]    = { list... }               -- unrepresentable hand edit

Anything absent means "follow the current default". A KOReader or plugin
update can therefore reshape untouched menus with zero reconciliation.

Identity: records are stamped with the provider that was serving the id when
the user acted ("stock" or "plugin:<name>"). A record only applies while that
provider still serves the id, so a later plugin reusing the same menu id can
never inherit another plugin's customization. provider == nil matches any
provider (legacy data migrated from older formats).

Ordering intent is provider-aware too: bulk sequences carry per-entry era
stamps (sequence_eras), and position anchors carry a provider stamp in their
record. Sequence entries or anchors stamped for a provider that no longer
serves the id are skipped at materialization time - a reused menu id starts
at its own provider's default slot instead of inheriting another plugin's
arrangement - and the original stamp reactivates when that provider returns.
Unstamped entries (legacy data) always apply.
--]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local AtomicWriter = require("reorderingmenus_atomic_writer")
local MenuSchema = require("reorderingmenus_menu_schema")

-- SCHEMA_VERSION is the on-disk format this build reads AND writes.
-- History:
--   0 (implicit) : pre-plugin-1.0 files without any version field
--   1            : first sparse-intent format (version field present,
--                  no generation counter)
--   2            : adds meta.generation (optimistic-concurrency base),
--                  drops nothing; v0/v1 migrate losslessly
local SCHEMA_VERSION = 2

-- Per-version migrators: input is the raw loaded table (already table-typed).
-- Each returns the migrated table at schema_version + 1 semantics; running a
-- migrator on already-migrated data must be a no-op (idempotence contract).
local MIGRATIONS = {}

MIGRATIONS[0] = function(data)
    -- v0 files carry no version field but otherwise look like v1.
    return data
end

MIGRATIONS[1] = function(data)
    -- v1 -> v2: add the generation counter if absent.
    if type(data.meta) ~= "table" then data.meta = {} end
    if type(data.meta.generation) ~= "number" then
        data.meta.generation = 0
    end
    return data
end

local IntentStore = {}

IntentStore.SCHEMA_VERSION = SCHEMA_VERSION

local backup_seq = 0

-- Preserve raw source bytes without routing them through the table serializer.
-- Backups use their own atomic temp+rename and never overwrite an earlier
-- recovery artifact created in the same second.
local function writeBackupBytes(path, suffix, body)
    backup_seq = backup_seq + 1
    local backup
    if suffix == "unsupported" then
        local stable = path:gsub("%.lua$", ".unsupported.lua")
        if lfs.attributes(stable, "mode") == nil then backup = stable end
    end
    backup = backup or string.format("%s.%s-%d-%d", path, suffix,
        os.time(), backup_seq)
    local tmp = backup .. ".tmp"
    local file, open_err = io.open(tmp, "wb")
    if not file then return nil, open_err end
    local ok_write, write_err = file:write(body or "")
    local ok_close, close_err = file:close()
    if not ok_write or not ok_close then
        pcall(os.remove, tmp)
        return nil, write_err or close_err
    end
    local ok_rename, rename_err = os.rename(tmp, backup)
    if not ok_rename then
        pcall(os.remove, tmp)
        return nil, rename_err
    end
    return backup
end

local function getSettingsPath()
    return string.format("%s/reorderingmenus_intent.lua", DataStorage:getSettingsDir())
end

-- Session-sticky P0-6 guard: once detection found corruption whose verbatim
-- quarantine FAILED, the on-disk original is the last surviving copy of the
-- user's prior state. Every durable canonical write is refused until a fresh
-- process start retries the quarantine (load() runs it again). Truthful,
-- unambiguous: one boolean, one meaning - "the pre-recovery bytes survived".
local original_preserved_on_disk = true

function IntentStore.isOriginalPreserved()
    return original_preserved_on_disk
end

local newViewSection = MenuSchema.newViewSection

local function newState()
    return {
        version = SCHEMA_VERSION,
        views = {
            reader = newViewSection(),
            filemanager = newViewSection(),
        },
        meta = {
            mirror_changes = false,
            hidden_in_place = true,
            generation = 0,
            view_generations = { reader = 0, filemanager = 0 },
            ui_state = {
                hidden_anchors = { reader = {}, filemanager = {} },
            },
        },
    }
end

local function validStateShape(data)
    return type(data) == "table"
        and type(data.views) == "table"
        and type(data.meta) == "table"
        and tonumber(data.version) == SCHEMA_VERSION
end

-- Monotonic canonical generation. Every successful durable commit bumps it;
-- transactions record the base they staged from so a commit can detect that
-- another writer advanced canonical state underneath it.
--
-- Two flavours:
--   generation()       - GLOBAL counter: optimistic-concurrency base for any
--                        staging snapshot (a commit replaces BOTH views, so a
--                        snapshot of either is invalidated by any commit).
--   generation(view)   - PER-VIEW counter: records how often one view's
--                        section was durably replaced. Bound into the native
--                        sidecar so startup can tell "the derived file lags
--                        canonical intent" (crash between commit and native
--                        write -> regenerate) apart from "the file is ours
--                        and current" (-> unchanged) and "someone else wrote
--                        it" (-> import).
function IntentStore.generation(view)
    local meta = IntentStore.load().meta
    if view ~= nil then
        local generations = type(meta.view_generations) == "table"
            and meta.view_generations or {}
        return type(generations[view]) == "number"
            and generations[view] or 0
    end
    return type(meta.generation) == "number" and meta.generation or 0
end

-- -------------------------------------------------------------------------
-- Provider identity semantics
-- -------------------------------------------------------------------------

-- A persisted record governs an item only while the provider that was current
-- when the user acted still serves that id. nil stamps match anything.
function IntentStore.recordApplies(record, current_provider)
    if type(record) ~= "table" then return false end
    if record.provider == nil then return true end
    return record.provider == current_provider
end

-- Stamp helper used by every writer of intent records.
function IntentStore.stamp(record, provider)
    record = type(record) == "table" and record or {}
    if provider ~= nil then
        record.provider = provider
    else
        record.provider = nil
    end
    return record
end

-- -------------------------------------------------------------------------
-- Load / persist
-- -------------------------------------------------------------------------

local state
-- Epoch of the current in-memory canonical table. Bumped by every wholesale
-- reload of `state` (load(force_reload) after external file changes,
-- replaceState, resetView); openTransaction stamps it so commit() can refuse
-- transactions that staged from a superseded world (see Transaction above).
local store_epoch = 0

local function sanitizeSection(section)
    if type(section.hidden) ~= "table" then section.hidden = {} end
    if type(section.hidden_order) ~= "table" then section.hidden_order = {} end
    if type(section.parent_override) ~= "table" then section.parent_override = {} end
    if type(section.position_override) ~= "table" then section.position_override = {} end
    if type(section.order_override) ~= "table" then section.order_override = {} end
    if type(section.sequence_eras) ~= "table" then section.sequence_eras = {} end
    if type(section.custom_menus) ~= "table" then section.custom_menus = {} end
    if type(section.separators) ~= "table" then section.separators = {} end
    if type(section.raw_override) ~= "table" then section.raw_override = {} end
    if section.tab_order ~= nil and type(section.tab_order) ~= "table" then
        section.tab_order = nil
    end
    return section
end

-- -------------------------------------------------------------------------
-- Canonical-state validation (P0 hardening): a corrupt canonical intent
-- file must never silently become a clean empty configuration.
--
-- collectProblems returns { { kind, view, collection, key, detail }, ... }.
-- repairProblems drops ONLY offending records; healthy siblings survive.
-- -------------------------------------------------------------------------

local function isStringArray(t)
    for _, v in ipairs(t) do
        if type(v) ~= "string" then return false end
    end
    return true
end

-- Shallow scan BEFORE sanitizeSection: whole-collection type errors must be
-- REPORTED, not silently coerced away. Deep checks follow in collectProblems.
local KNOWN_COLLECTIONS = MenuSchema.VIEW_COLLECTION_SET
local function collectShapeProblems(state, problems)
    if type(state.views) ~= "table" then
        problems[#problems + 1] = { kind = "malformed_collection",
            collection = "views", detail = "views is " .. type(state.views) }
        return
    end
    for _, view in ipairs(MenuSchema.VIEWS) do
        local section = state.views and state.views[view]
        if section == nil then
            -- Absent view: not an error (single-section validation and
            -- fresh states may legitimately omit it).
        elseif type(section) ~= "table" then
            problems[#problems + 1] = { kind = "malformed_section",
                view = view, collection = "view",
                detail = "view section is " .. type(section) }
        else
            -- Only collections PRESENT with a wrong type are malformed.
            -- Absent optional collections are normal: v0/v1 legacy files
            -- predate several of them, and treating absence as corruption
            -- would quarantine healthy files and wipe user data. Missing
            -- tables are simply filled in by sanitizeSection afterwards.
            for coll in pairs(KNOWN_COLLECTIONS) do
                if rawget(section, coll) ~= nil
                        and type(section[coll]) ~= "table" then
                    problems[#problems + 1] = { kind = "malformed_collection",
                        view = view, collection = coll,
                        detail = "collection is " .. type(section[coll])
                            .. ", expected table" }
                end
            end
            if section.tab_order ~= nil and type(section.tab_order) ~= "table" then
                -- Reported by the per-view pass after sanitizeSection; not
                -- duplicated here.
            end
        end
    end
end

local function collectProblems(state, problems)
    for _, view in ipairs(MenuSchema.VIEWS) do
        local section = state.views and state.views[view]
        if type(section) == "table" then
            -- v0/v1 legacy sections legitimately omit later-era collections
            -- (they are only filled by sanitizeSection AFTER this scan).
            -- Guard every access: absence is normal historical shape, not
            -- corruption - indexing nil here would quarantine healthy files.
            local hidden = section.hidden or {}
            local hidden_order = section.hidden_order or {}
            local position_override = section.position_override or {}
            local parent_override = section.parent_override or {}
            local order_override = section.order_override or {}
            local sequence_eras = section.sequence_eras or {}
            local custom_menus = section.custom_menus or {}
            local separators = section.separators or {}
            local raw_override = section.raw_override or {}
            for id, record in pairs(hidden) do
                if type(record) ~= "table" then
                    problems[#problems + 1] = { kind = "malformed_record",
                        view = view, collection = "hidden", key = id,
                        detail = "record is not a table" }
                end
            end
            local listed = {}
            for _, id in ipairs(hidden_order) do
                listed[id] = true
                if hidden[id] == nil then
                    problems[#problems + 1] = { kind = "dangling_reference",
                        view = view, collection = "hidden_order", key = id,
                        detail = "no matching hidden record" }
                end
            end
            for id, record in pairs(hidden) do
                -- Only well-formed records can take part in the visibility
                -- order; malformed ones are reported once, above.
                if type(record) == "table" and not listed[id] then
                    problems[#problems + 1] = { kind = "inconsistent_order",
                        view = view, collection = "hidden", key = id,
                        detail = "hidden record missing from hidden_order" }
                end
            end
            for id, record in pairs(position_override) do
                if type(record) ~= "table"
                        or (record.after == nil and record.before == nil) then
                    problems[#problems + 1] = { kind = "malformed_record",
                        view = view, collection = "position_override", key = id,
                        detail = "missing after/before anchor" }
                end
            end
            for id, record in pairs(parent_override) do
                if type(record) ~= "table" or type(record.parent) ~= "string" then
                    problems[#problems + 1] = { kind = "malformed_record",
                        view = view, collection = "parent_override", key = id,
                        detail = "missing parent field" }
                elseif record.parent == id then
                    problems[#problems + 1] = { kind = "self_cycle",
                        view = view, collection = "parent_override", key = id,
                        detail = "item placed under itself" }
                end
                -- Note: a well-formed parent target that is unknown at load
                -- time (a stock submenu name) is NOT flagged: stock menus are
                -- unknowable here, the materializer already degrades invalid
                -- targets to the default placement, and flagging them would
                -- destroy healthy records on every load.
            end
            for menu_id, seq in pairs(order_override) do
                if type(seq) ~= "table" or not isStringArray(seq) then
                    problems[#problems + 1] = { kind = "malformed_sequence",
                        view = view, collection = "order_override", key = menu_id,
                        detail = "sequence is not an array of strings" }
                else
                    local seen = {}
                    for _, id in ipairs(seq) do
                        if seen[id] then
                            problems[#problems + 1] = { kind = "duplicate_entry",
                                view = view, collection = "order_override",
                                key = menu_id, detail = "duplicate id " .. id }
                        end
                        seen[id] = true
                    end
                end
            end
            for menu_id, eras in pairs(sequence_eras) do
                if type(eras) ~= "table" then
                    problems[#problems + 1] = { kind = "malformed_sequence",
                        view = view, collection = "sequence_eras", key = menu_id,
                        detail = "era map is not a table" }
                else
                    for id, era in pairs(eras) do
                        if era ~= nil and type(era) ~= "string" then
                            problems[#problems + 1] =
                                { kind = "bad_era", view = view,
                                  collection = "sequence_eras", key = menu_id,
                                  detail = "era of " .. tostring(id)
                                      .. " is not a provider string" }
                        end
                    end
                end
            end
            for id, record in pairs(custom_menus) do
                if type(record) ~= "table" or type(record.title) ~= "string"
                        or record.title == "" then
                    problems[#problems + 1] = { kind = "malformed_record",
                        view = view, collection = "custom_menus", key = id,
                        detail = "missing title" }
                elseif record.parent ~= nil and type(record.parent) ~= "string" then
                    problems[#problems + 1] = { kind = "malformed_record",
                        view = view, collection = "custom_menus", key = id,
                        detail = "parent is not a string" }
                end
                -- Unknown parent targets are not flagged (stock menus are
                -- unknowable at load time); the materializer degrades them.
            end
            for key, sep in pairs(separators) do
                if type(sep) ~= "table" or type(sep.parent) ~= "string" then
                    problems[#problems + 1] = { kind = "malformed_record",
                        view = view, collection = "separators", key = key,
                        detail = "missing parent" }
                end
            end
            for menu_id, raw in pairs(raw_override) do
                if type(raw) ~= "table" or type(raw.list) ~= "table"
                        or not isStringArray(raw.list) then
                    problems[#problems + 1] = { kind = "malformed_sequence",
                        view = view, collection = "raw_override", key = menu_id,
                        detail = "list is not an array of strings" }
                end
            end
            if section.tab_order ~= nil
                    and not isStringArray(section.tab_order) then
                problems[#problems + 1] = { kind = "malformed_sequence",
                    view = view, collection = "tab_order",
                    detail = "tab order is not an array of strings" }
            end
        end
    end
    return problems
end

local function repairProblems(state, problems)
    for _, p in ipairs(problems) do
        local section = state.views[p.view]
        if section then
            if p.collection == "hidden_order" then
                local kept = {}
                for _, id in ipairs(section.hidden_order) do
                    if id ~= p.key then kept[#kept + 1] = id end
                end
                section.hidden_order = kept
            elseif p.kind == "inconsistent_order" then
                -- The hidden record has no visibility-order entry. The
                -- visibility order is UX bookkeeping only: heal it by
                -- appending the id instead of destroying the record.
                if section.hidden[p.key] ~= nil then
                    table.insert(section.hidden_order, p.key)
                end
            elseif p.collection == "tab_order" then
                section.tab_order = nil
            elseif p.collection ~= "view" and p.key ~= nil then
                local coll = section[p.collection]
                if type(coll) == "table" then coll[p.key] = nil end
            end
            -- Whole-collection / whole-view problems are healed by
            -- sanitizeSection after validation; nothing per-record to drop.
        end
    end
end

-- Validate canonical state. Accepts either a full state ({ views = ... })
-- or a single view section; returns { { kind, view, collection, key,
-- detail }, ... }. Healthy state yields an empty list.
IntentStore.validateIntentState = function(state_or_section)
    local problems = {}
    local as_state = type(state_or_section) == "table"
        and type(state_or_section.views) == "table"
    if as_state then
        collectShapeProblems(state_or_section, problems)
        if #problems == 0 then
            collectProblems(state_or_section, problems)
        end
    else
        -- Single-section form: validate only this section. The other view
        -- is left ABSENT (not an empty table) so the shape scan does not
        -- report its collections as missing.
        local wrapper = { views = { reader = state_or_section } }
        collectShapeProblems(wrapper, problems)
        if #problems == 0 then
            collectProblems(wrapper, problems)
        end
        for _, p in ipairs(problems) do p.view = nil end
    end
    return problems
end

local function readStoredState(path)
    if lfs.attributes(path, "mode") ~= "file" then
        return newState(), nil, nil
    end

    local raw_text
    local file = io.open(path, "r")
    if file then
        raw_text = file:read("*a")
        file:close()
    end

    local chunk, load_err = loadstring(raw_text or "", "@" .. path)
    if chunk and setfenv then setfenv(chunk, {}) end
    local ok, loaded = false, load_err
    if chunk then ok, loaded = pcall(chunk) end
    if ok and type(loaded) == "table" then
        return loaded, raw_text, nil
    end
    return newState(), raw_text, tostring(loaded)
end

local function migrateState(loaded)
    local migrated = false
    while (tonumber(loaded.version) or 0) < SCHEMA_VERSION do
        local version = tonumber(loaded.version) or 0
        local step = MIGRATIONS[version]
        if not step then break end
        step(loaded)
        loaded.version = version + 1
        migrated = true
    end
    if (tonumber(loaded.version) or 0) ~= SCHEMA_VERSION then
        loaded.version = SCHEMA_VERSION
        migrated = true
    end
    return migrated
end

local function normalizeViews(loaded, problems)
    collectShapeProblems(loaded, problems)
    local changed = false
    if type(loaded.views) ~= "table" then
        loaded.views = {}
        changed = true
    end
    for _, view in ipairs(MenuSchema.VIEWS) do
        if type(loaded.views[view]) ~= "table" then
            loaded.views[view] = newViewSection()
            changed = true
        end

        -- Remember malformed values before filling absent/invalid fields.
        -- This keeps diagnostics tied to the original bytes while ensuring
        -- deep validation only ever sees collections it can safely iterate.
        local malformed = {}
        for _, collection in ipairs(MenuSchema.VIEW_COLLECTIONS) do
            local value = rawget(loaded.views[view], collection)
            if value ~= nil and type(value) ~= "table" then
                malformed[collection] = value
            elseif value == nil then
                changed = true
            end
        end
        local tab_order = loaded.views[view].tab_order
        sanitizeSection(loaded.views[view])
        for collection in pairs(malformed) do
            loaded.views[view][collection] = {}
            changed = true
        end
        if tab_order ~= nil and type(tab_order) ~= "table" then
            problems[#problems + 1] = { kind = "malformed_sequence",
                view = view, collection = "tab_order",
                detail = "tab order was " .. type(tab_order) }
            loaded.views[view].tab_order = nil
            changed = true
        end
    end
    collectProblems(loaded, problems)
    return changed
end

local function normalizeMetadata(loaded)
    local changed = false
    if type(loaded.meta) ~= "table" then loaded.meta = {}; changed = true end
    if type(loaded.meta.ui_state) ~= "table" then
        loaded.meta.ui_state = {}
        changed = true
    end
    if type(loaded.meta.generation) ~= "number" then
        loaded.meta.generation = 0
        changed = true
    end
    if type(loaded.meta.view_generations) ~= "table" then
        loaded.meta.view_generations = {}
        changed = true
    end
    if type(loaded.meta.ui_state.hidden_anchors) ~= "table" then
        loaded.meta.ui_state.hidden_anchors = {}
        changed = true
    end
    for _, view in ipairs(MenuSchema.VIEWS) do
        if type(loaded.meta.view_generations[view]) ~= "number" then
            loaded.meta.view_generations[view] = 0
            changed = true
        end
        if type(loaded.meta.ui_state.hidden_anchors[view]) ~= "table" then
            loaded.meta.ui_state.hidden_anchors[view] = {}
            changed = true
        end
    end
    return changed
end

function IntentStore.load(force_reload)
    if state and not force_reload then return state end

    local path = getSettingsPath()
    local loaded, raw_text, parse_error = readStoredState(path)
    local problems = {}
    local backup_path
    -- P0-6 invariant: while the ORIGINAL canonical bytes are the only
    -- surviving copy of user state, they must never be overwritten merely
    -- because automatic recovery could not preserve them elsewhere. Starts
    -- true (nothing destroyed yet); flips false the moment corruption is
    -- detected AND its verbatim quarantine fails.
    local original_preserved = true
    local preservation_err

    -- Reject future schemas before normalizing, repairing, or writing them.
    -- A downgraded build must never reinterpret newer data as its own format.
    local on_disk_version = tonumber(loaded.version) or 0
    if not parse_error and on_disk_version > SCHEMA_VERSION then
        local unsupported_path, backup_err = writeBackupBytes(
            path, "unsupported", raw_text)
        if unsupported_path then
            logger.warn("ReorderingMenus: intent schema", tostring(on_disk_version),
                "is not supported by this build (max",
                tostring(SCHEMA_VERSION) .. "); quarantined to", unsupported_path)
        else
            -- Quarantine failed: the original is the only surviving copy of
            -- whatever state it held; it must stay untouched on disk.
            logger.warn("ReorderingMenus: failed to preserve unsupported intent:",
                backup_err, "- refusing to overwrite the original")
            original_preserved_on_disk = false
            state = newState()
            store_epoch = store_epoch + 1
            return state, { { kind = "unsupported_future_schema",
                detail = "version " .. tostring(on_disk_version),
                preserved = false } }, nil
        end
        logger.warn("ReorderingMenus: intent file schema", on_disk_version,
            "> supported", SCHEMA_VERSION, "- ignoring file (quarantined)")
        state = newState()
        store_epoch = store_epoch + 1
        return state, { { kind = "unsupported_future_schema",
            detail = "version " .. tostring(on_disk_version) } }, nil
    end

    if parse_error then
        backup_path = writeBackupBytes(path, "corrupt", raw_text)
        if not backup_path then
            original_preserved = false
            preservation_err = "quarantine failed"
        end
        problems[#problems + 1] = { kind = "unparsable", collection = "file",
            detail = parse_error }
        logger.warn("ReorderingMenus: canonical intent file was corrupt;",
            backup_path and ("preserved as " .. backup_path) or "backup FAILED",
            "- starting from a clean configuration")
    end

    local migrated = migrateState(loaded)
    local normalized_views = normalizeViews(loaded, problems)
    -- Some problems are healed WITHOUT losing any user record (the repair
    -- only adds missing bookkeeping). Quarantining a file our own writer or
    -- migration just produced would treat healthy state as corruption and
    -- cascade into data loss; reserve backups for destructive repairs.
    local BENIGN_HEALS = { inconsistent_order = true }
    local destructive = {}
    for _, p in ipairs(problems) do
        if not BENIGN_HEALS[p.kind] then destructive[#destructive + 1] = p end
    end
    if not parse_error and #problems > 0 then
        repairProblems(loaded, problems)
    end
    if not parse_error and #destructive > 0 then
        backup_path = writeBackupBytes(path, "corrupt", raw_text)
        if not backup_path then
            original_preserved = false
            preservation_err = "quarantine failed"
        end
        logger.warn("ReorderingMenus: canonical intent problem(s):",
            #destructive,
            backup_path and ("- original preserved as " .. backup_path)
                or "- original could NOT be preserved")
    elseif not parse_error and #problems > 0 then
        logger.info("ReorderingMenus: healed", #problems,
            "benign canonical intent inconsistency without quarantine")
    end
    local normalized_meta = normalizeMetadata(loaded)

    -- Migration and repair converge through one durable write. This avoids
    -- persisting an intermediate, only-partly-normalized representation.
    --
    -- P0-6: that write REPLACES the original file. When the quarantine of
    -- the corrupt bytes FAILED, the original is the only surviving
    -- representation of user state, so the in-place repair save is refused:
    -- the corrupt bytes stay on disk untouched, this session continues with
    -- the repaired IN-MEMORY state, and the condition is reported via a
    -- preservation_failed problem (and to any caller inspecting problems).
    local must_rewrite = parse_error or migrated or normalized_views
        or normalized_meta or #problems > 0
    if must_rewrite and not original_preserved then
        original_preserved_on_disk = false
        problems[#problems + 1] = { kind = "preservation_failed",
            collection = "file", detail = tostring(preservation_err) }
        logger.err("ReorderingMenus: canonical intent recovery could not",
            "preserve the original; refusing to overwrite it. The corrupt",
            "file stays untouched; this session runs on repaired in-memory",
            "state.")
    elseif must_rewrite then
        local ok, err = AtomicWriter.writeTable(path, loaded, validStateShape)
        if not ok then
            logger.warn("ReorderingMenus: failed persisting normalized intent", err)
        elseif migrated then
            logger.info("ReorderingMenus: migrated intent store to schema",
                SCHEMA_VERSION)
        end
    end

    state = loaded
    -- Wholesale reload: transactions staged from the previous in-memory
    -- world are superseded (their base_generation describes a counter that
    -- no longer exists after an external rollback of the intent file).
    store_epoch = store_epoch + 1
    return state, problems, backup_path
end

function IntentStore.hasPersistedState()
    return lfs.attributes(getSettingsPath(), "mode") == "file"
end

function IntentStore.save()
    -- P0-6: never destroy the only surviving representation of user state.
    -- While the pre-recovery original sits unpreserved on disk, durable
    -- canonical writes stay refused (in-session work continues in memory).
    if not original_preserved_on_disk then
        return false, "unpreserved corrupt canonical original on disk;"
            .. " refusing to overwrite it"
    end
    local path = getSettingsPath()
    -- The canonical state is the single source of truth for every menu this
    -- plugin derives; a truncated write here would be indistinguishable from
    -- "user reset everything" on the next load. Persist atomically.
    local ok, err = AtomicWriter.writeTable(path, state, validStateShape)
    if not ok then
        logger.err("ReorderingMenus: failed to write intent state:", err)
        return false, err
    end
    return true, path
end

-- Replace the entire in-memory state (migration, preset import, tests).
-- Callers decide whether to persist.
function IntentStore.replaceState(new_state)
    state = new_state or newState()
    -- The in-memory canonical world was swapped wholesale: any transaction
    -- staged from the PREVIOUS table is now describing a superseded world
    -- (migration, preset import, test harness). Bump the epoch so commit()
    -- refuses them; callers restage exactly like after a generation race.
    store_epoch = store_epoch + 1
    return state
end

-- Monotonic counter of wholesale in-memory canonical swaps. openTransaction
-- stamps the current value; commit() compares. Deliberately NOT persisted:
-- it only orders operations within one process.
function IntentStore.storeEpoch()
    return store_epoch
end

function IntentStore.view(view)
    local s = IntentStore.load()
    if type(s.views[view]) ~= "table" then
        s.views[view] = newViewSection()
    end
    return s.views[view]
end

function IntentStore.meta()
    return IntentStore.load().meta
end

-- Operational preferences (mirroring, editor display modes, hidden-row
-- anchors) are not menu intent: they persist immediately instead of riding
-- through staged transactions, matching their historical instant-persist
-- behavior.
function IntentStore.setMeta(key, value)
    local meta = IntentStore.meta()
    meta[key] = value
    return IntentStore.save()
end

function IntentStore.getHiddenAnchor(view, item_id)
    local anchors = IntentStore.meta().ui_state.hidden_anchors[view]
    return anchors and anchors[item_id] or nil
end

function IntentStore.setHiddenAnchor(view, item_id, anchor)
    local ui_state = IntentStore.meta().ui_state
    ui_state.hidden_anchors[view][item_id] = anchor
    return IntentStore.save()
end

function IntentStore.clearHiddenAnchor(view, item_id)
    local anchors = IntentStore.meta().ui_state.hidden_anchors[view]
    if anchors then
        anchors[item_id] = nil
        return IntentStore.save()
    end
    return true
end

function IntentStore.resetView(view)
    IntentStore.load().views[view] = newViewSection()
    IntentStore.meta().ui_state.hidden_anchors[view] = {}
    -- A reset erases a whole view's records in place: staged sections from
    -- before the reset describe the arrangement that was just discarded.
    store_epoch = store_epoch + 1
end

function IntentStore.isCustomized(view)
    local section = IntentStore.view(view)
    for _, collection in pairs(section) do
        if type(collection) == "table" and next(collection) ~= nil then return true end
        if collection ~= nil and type(collection) ~= "table" then return true end
    end
    return false
end

-- -------------------------------------------------------------------------
-- Transactions
-- -------------------------------------------------------------------------

-- Editors and bulk operations mutate a staged copy of the state through an
-- IntentTransaction; commit makes the staging canonical (and persists), while
-- discard throws it away. View intent and hidden-anchor changes made through
-- the transaction are committed together; standalone preferences persist
-- immediately through IntentStore.setMeta.

local Transaction = {}
Transaction.__index = Transaction

function IntentStore.openTransaction()
    local txn = setmetatable({
        staged = util.tableDeepCopy(IntentStore.load().views),
        staged_ui_state = util.tableDeepCopy(IntentStore.meta().ui_state),
        committed = false,
        discarded = false,
        -- Optimistic-concurrency base: the canonical generation this staging
        -- snapshot was taken at. commit() refuses to persist when canonical
        -- has advanced past it (no silent lost updates).
        base_generation = IntentStore.generation(),
        -- Epoch of the in-memory canonical table this staging was taken
        -- from. Every WHOLESALE reload of that table (a fresh load(true)
        -- after an external rollback, replaceState for migration/presets,
        -- or a view reset) bumps store_epoch; a transaction staged before
        -- the swap then holds records and a projection derived from the
        -- PREVIOUS world. Its base_generation check cannot catch this (the
        -- restored file may carry any counter value), so commit() refuses
        -- via the epoch instead - the caller must restage, exactly like the
        -- stale-generation case. Without this guard a consistent whole-file
        -- rollback gets fused with pre-rollback staging on the first
        -- restart and only converges after a second one.
        store_epoch = IntentStore.storeEpoch(),
    }, Transaction)
    -- Deep copy of the staged-from state for three-way merges on conflict.
    txn.base_sections = util.tableDeepCopy(txn.staged)
    txn.base_ui_state = util.tableDeepCopy(txn.staged_ui_state)
    if type(txn.staged) ~= "table" then txn.staged = {} end
    for _, view in ipairs(MenuSchema.VIEWS) do
        if type(txn.staged[view]) ~= "table" then
            txn.staged[view] = newViewSection()
        end
        sanitizeSection(txn.staged[view])
    end
    return txn
end

function Transaction:view(view)
    if self.discarded then return IntentStore.view(view) end
    if type(self.staged[view]) ~= "table" then
        self.staged[view] = newViewSection()
    end
    return self.staged[view]
end

function Transaction:meta()
    return { ui_state = self.staged_ui_state }
end

function Transaction:section(view, name)
    local v = self:view(view)
    if type(v[name]) ~= "table" then v[name] = {} end
    return v[name]
end

function Transaction:setHiddenAnchor(view, item_id, anchor)
    local ui_state = self.staged_ui_state
    ui_state.hidden_anchors[view][item_id] = anchor
end

function Transaction:clearHiddenAnchor(view, item_id)
    local anchors = self.staged_ui_state.hidden_anchors[view]
    if anchors then anchors[item_id] = nil end
end

function Transaction:setHiddenAnchors(view, anchors)
    self.staged_ui_state.hidden_anchors[view] =
        util.tableDeepCopy(type(anchors) == "table" and anchors or {})
end

function Transaction:getHiddenAnchors(view)
    return self.staged_ui_state.hidden_anchors[view]
end

-- Sparse bookkeeping: an override equal to the current default carries no
-- information and is dropped instead of persisted.
function Transaction:setHidden(view, item_id, record)
    if record == nil then
        self:section(view, "hidden")[item_id] = nil
        self:removeHiddenOrder(view, item_id)
    else
        self:section(view, "hidden")[item_id] = record
        self:appendHiddenOrder(view, item_id)
    end
end

-- Visibility ordering is part of the user experience (editors list hidden
-- rows in the order they were hidden), so it is recorded explicitly.
function Transaction:appendHiddenOrder(view, item_id)
    local order = self:view(view).hidden_order
    for _, id in ipairs(order) do
        if id == item_id then return end
    end
    table.insert(order, item_id)
end

function Transaction:removeHiddenOrder(view, item_id)
    local order = self:view(view).hidden_order or {}
    for i, id in ipairs(order) do
        if id == item_id then
            table.remove(order, i)
            return
        end
    end
end

function Transaction:getHidden(view, item_id)
    return self:section(view, "hidden")[item_id]
end

function Transaction:setParentOverride(view, item_id, record)
    self:section(view, "parent_override")[item_id] = record
end

function Transaction:getParentOverride(view, item_id)
    return self:section(view, "parent_override")[item_id]
end

function Transaction:setPositionOverride(view, item_id, record)
    self:section(view, "position_override")[item_id] = record
end

function Transaction:setOrderOverride(view, menu_id, sequence, eras)
    if sequence == nil or #sequence == 0 then
        self:section(view, "order_override")[menu_id] = nil
        self:view(view).sequence_eras[menu_id] = nil
    else
        -- Canonical sequences are id-unique per menu (the loader treats a
        -- duplicate as corruption and would quarantine a file we wrote
        -- ourselves). Every writer funnels through here, so enforce the
        -- invariant at the door: keep the FIRST occurrence - the position
        -- already arranged - and drop later copies. Presets and the editor
        -- staging path dedupe upstream; this is the last-line defense for
        -- native-import merges and any future writer.
        local deduped, dropped = {}, nil
        local seen = {}
        for _, id in ipairs(sequence) do
            if seen[id] then
                dropped = dropped or id
            else
                seen[id] = true
                deduped[#deduped + 1] = id
            end
        end
        if dropped then
            logger.warn("ReorderingMenus: order_override sequence for",
                tostring(view) .. "/" .. tostring(menu_id),
                "carried duplicate entries (first:", dropped,
                ") - keeping first occurrence")
        end

        self:section(view, "order_override")[menu_id] = deduped
        -- Era stamps travel with their sequence; an override written without
        -- stamps (legacy/imported shape) applies unconditionally.
        if type(eras) == "table" and next(eras) ~= nil then
            self:view(view).sequence_eras[menu_id] = eras
        else
            self:view(view).sequence_eras[menu_id] = nil
        end
    end
end

-- Drop one id's era stamp everywhere it is sequenced (companion to removing
-- that id from order_override arrays).
function Transaction:clearSequenceEra(view, item_id)
    local eras = self:view(view).sequence_eras
    for menu_id, map in pairs(eras or {}) do
        if type(map) == "table" then
            map[item_id] = nil
            if not next(map) then eras[menu_id] = nil end
        end
    end
end

function Transaction:getSequenceEras(view, menu_id)
    local eras = self:view(view).sequence_eras
    return type(eras) == "table" and eras[menu_id] or nil
end

function Transaction:getOrderOverride(view, menu_id)
    return self:section(view, "order_override")[menu_id]
end

function Transaction:setCustomMenu(view, submenu_id, record)
    self:section(view, "custom_menus")[submenu_id] = record
end

function Transaction:getCustomMenus(view)
    return self:section(view, "custom_menus")
end

function Transaction:setSeparator(view, key, record)
    self:section(view, "separators")[key] = record
end

function Transaction:setRawOverride(view, menu_id, list)
    if list == nil or #list == 0 then
        self:section(view, "raw_override")[menu_id] = nil
    else
        self:section(view, "raw_override")[menu_id] = { list = list }
    end
end

function Transaction:setTabOrder(view, tabs)
    self:view(view).tab_order = tabs
end

function Transaction:clearItem(view, item_id)
    -- Remove every trace of user action for one id: the definition of
    -- "restore to whatever the current default says".
    self:section(view, "hidden")[item_id] = nil
    self:removeHiddenOrder(view, item_id)
    self:section(view, "parent_override")[item_id] = nil
    self:section(view, "position_override")[item_id] = nil
    local touched = {}
    for menu_id in pairs(self:section(view, "order_override")) do
        table.insert(touched, menu_id)
    end
    for _, menu_id in ipairs(touched) do
        local cleaned = {}
        for _, id in ipairs(self:view(view).order_override[menu_id]) do
            if id ~= item_id then table.insert(cleaned, id) end
        end
        self.staged[view].order_override[menu_id] = #cleaned > 0 and cleaned or nil
        if not self.staged[view].order_override[menu_id] then
            self.staged[view].sequence_eras[menu_id] = nil
        end
    end
    self:clearSequenceEra(view, item_id)
    self:clearHiddenAnchor(view, item_id)
end

function Transaction:setViewSection(view, section)
    self.staged[view] = section
end

-- Record collections compared per id/key by Transaction:mergeSection.
local MERGED_COLLECTIONS = {
    "hidden", "parent_override", "position_override",
    "order_override", "sequence_eras", "custom_menus",
    "separators", "raw_override",
}

local function valuesEqual(a, b)
    if type(a) == "table" and type(b) == "table" then
        return util.tableEquals(a, b)
    end
    return a == b
end

-- Merge a record-keyed map using the transaction snapshot as the common
-- ancestor.  An untouched staged key adopts canonical; an explicitly changed
-- staged key wins.  This handles additions, changes, and deletions uniformly.
local function mergeRecordMap(base, staged, canonical)
    base = type(base) == "table" and base or {}
    staged = type(staged) == "table" and staged or {}
    canonical = type(canonical) == "table" and canonical or {}
    local merged, keys = {}, {}
    for key in pairs(base) do keys[key] = true end
    for key in pairs(staged) do keys[key] = true end
    for key in pairs(canonical) do keys[key] = true end
    for key in pairs(keys) do
        local chosen
        if valuesEqual(staged[key], base[key]) then
            chosen = canonical[key]
        else
            chosen = staged[key]
        end
        if chosen ~= nil then merged[key] = util.tableDeepCopy(chosen) end
    end
    return merged
end

-- Three-way merge of ONE view's staged section against the transaction's
-- base snapshot and the CURRENT canonical section (which another writer has
-- advanced). Per record:
--
--   staged == base, canonical changed  -> take canonical   (they moved it)
--   staged != base                     -> keep staged      (user's explicit save
--                                          wins for this view's records)
--   both changed identically           -> either (staged kept)
--
-- Non-record state (hidden_order list, tab_order) is taken from the staged
-- section when the user touched this view at all, since these are whole-view
-- orderings without a per-record diff. Returns the merged section.
function Transaction:mergeSection(view)
    local base_section = self.base_sections
        and self.base_sections[view] or nil
    local staged = self.staged[view] or {}
    local canonical = IntentStore.view(view)

    -- Untouched view: adopt canonical wholesale.
    if base_section == nil or util.tableEquals(base_section, staged) then
        return util.tableDeepCopy(canonical)
    end

    local merged = util.tableDeepCopy(staged)
    for _, coll_name in ipairs(MERGED_COLLECTIONS) do
        merged[coll_name] = mergeRecordMap(base_section[coll_name],
            staged[coll_name], canonical[coll_name])
    end
    for _, field in ipairs({ "hidden_order", "tab_order" }) do
        if valuesEqual(staged[field], base_section[field]) then
            merged[field] = util.tableDeepCopy(canonical[field])
        end
    end
    return merged
end

function Transaction:mergeHiddenAnchors(view)
    local function anchors(ui_state)
        local all = type(ui_state) == "table" and ui_state.hidden_anchors or nil
        return type(all) == "table" and all[view] or {}
    end
    return mergeRecordMap(anchors(self.base_ui_state),
        anchors(self.staged_ui_state),
        anchors(IntentStore.meta().ui_state))
end

function Transaction:resetView(view)
    self.staged[view] = newViewSection()
    self:meta().ui_state.hidden_anchors[view] = {}
end

--- Which views' staged sections differ from the canonical sections this
--- transaction would replace. THE source of "what must be materialized"
--- after a commit: callers never re-derive or remember this themselves
--- (P0-1). Computed on demand so it reflects the staging that actually
--- commits, including any post-staging edits.
function Transaction:changedViews()
    if self.discarded then return { reader = false, filemanager = false } end
    local changed = {}
    local previous_views = state.views
    for _, v in ipairs(MenuSchema.VIEWS) do
        changed[v] = not util.tableEquals(self.staged[v] or {},
            previous_views[v] or {})
    end
    return changed
end

-- Remove references to a deleted custom submenu everywhere.
function Transaction:deleteCustomMenu(view, submenu_id)
    self:view(view).custom_menus[submenu_id] = nil
    self:view(view).order_override[submenu_id] = nil
    if self:view(view).sequence_eras then
        self:view(view).sequence_eras[submenu_id] = nil
    end
    local touched = {}
    for menu_id in pairs(self:view(view).order_override or {}) do
        table.insert(touched, menu_id)
    end
    for _, menu_id in ipairs(touched) do
        local cleaned = {}
        for _, id in ipairs(self:view(view).order_override[menu_id]) do
            if id ~= submenu_id then table.insert(cleaned, id) end
        end
        self.staged[view].order_override[menu_id] = #cleaned > 0 and cleaned or nil
        if not self.staged[view].order_override[menu_id] then
            self.staged[view].sequence_eras[menu_id] = nil
        end
    end
    self:clearSequenceEra(view, submenu_id)
end

function Transaction:commit(persist)
    if self.discarded then return false, "transaction discarded" end
    -- Roll back the in-memory swap when the durable write fails: the saved
    -- baseline must never claim success it does not have.
    local previous_views = state.views
    local meta = IntentStore.meta()
    local previous_generation = type(meta.generation) == "number"
        and meta.generation or 0
    local previous_view_generations = util.tableDeepCopy(
        type(meta.view_generations) == "table" and meta.view_generations or {})
    local previous_ui_state = meta.ui_state
    local changed_views = {}
    local view_changed = false
    for _, v in ipairs(MenuSchema.VIEWS) do
        changed_views[v] = not util.tableEquals(self.staged[v] or {},
            previous_views[v] or {})
        view_changed = view_changed or changed_views[v]
    end
    local ui_state_changed = not util.tableEquals(
        self.staged_ui_state or {}, previous_ui_state or {})
    state.views = self.staged
    meta.ui_state = self.staged_ui_state
    if persist ~= false then
        -- Optimistic concurrency: the transaction remembers which canonical
        -- generation it staged from. If canonical advanced since (another
        -- writer committed), this commit would silently drop that work, so it
        -- refuses and reports the conflict. Callers re-open a fresh
        -- transaction (which stages the newer canonical) and re-apply.
        if self.base_generation ~= nil
                and self.base_generation ~= IntentStore.generation() then
            state.views = previous_views
            meta.ui_state = previous_ui_state
            return false, "stale_transaction"
        end
        -- Epoch guard: the in-memory canonical table was swapped wholesale
        -- after this transaction staged (load(true) absorbing a rollback,
        -- replaceState, resetView). The generation check above cannot see
        -- that - a restored file may carry ANY counter value - so compare
        -- epochs: staging from a superseded world would fuse the old world
        -- into the restored one on this very commit.
        if self.store_epoch ~= nil
                and self.store_epoch ~= IntentStore.storeEpoch() then
            state.views = previous_views
            meta.ui_state = previous_ui_state
            return false, "stale_transaction"
        end
        -- Semantic no-op commits (staged sections equal canonical in both
        -- views) carry no information: they must not advance any generation
        -- counter nor rewrite the durable file. Generation counters are the
        -- optimistic-concurrency currency; idle saves inflating them would
        -- force every later legitimate commit to look stale, and would make
        -- syncView believe derived files lag after a pure no-op.
        local changed = view_changed or ui_state_changed
        if changed then
            if view_changed then
                meta.generation = previous_generation + 1
            end
            -- Per-view counters advance for every view whose section this
            -- commit actually replaced (staged ~= canonical at swap time).
            if type(meta.view_generations) ~= "table" then
                meta.view_generations = {}
            end
            for _, v in ipairs(MenuSchema.VIEWS) do
                if changed_views[v] then
                    meta.view_generations[v] =
                        (type(meta.view_generations[v]) == "number"
                            and meta.view_generations[v] or 0) + 1
                end
            end
            local ok, err = IntentStore.save()
            if not ok then
                -- Undo the generation bump together with the view swap.
                meta.generation = previous_generation
                meta.view_generations = previous_view_generations
                meta.ui_state = previous_ui_state
                state.views = previous_views
                return false, err
            end
        end
        -- unchanged: nothing durable to write; the swap is identity anyway.
    end
    self.committed = true
    return true
end

function Transaction:discard()
    self.discarded = true
    self.staged = nil
end

IntentStore.newViewSection = newViewSection
IntentStore.INTENT_VERSION = SCHEMA_VERSION
return IntentStore

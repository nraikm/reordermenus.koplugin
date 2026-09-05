--[[--
intent_store.lua — the ONLY canonical persistent customization state.

Persists sparse declarative user intent, never resolved runtime menus. Every
menu KOReader renders is derived at runtime from (current defaults x intent),
so only actions the user actually performed are recorded here:

    hidden[id]            = { provider, origin?, ordinal } -- deliberately invisible
    parent_override[id]   = { provider, parent }      -- deliberately placed here
    position_override[id] = { provider, after/before }-- deliberately slotted
    order_override[menu]  = { entries = {...} }       -- deliberately rearranged
                                                      -- (entries carry provider)
    custom_menus[id]      = { title, after? }         -- user-created submenu
    separators[key]       = { provider, parent, after } -- user-inserted separator
    tab_order             = { seq... }                -- deliberately reordered tabs
    raw_override[menu]    = { list... }               -- unrepresentable hand edit

Anything absent means "follow the current default". A KOReader or plugin
update can therefore reshape untouched menus with zero reconciliation.

Identity: records are stamped with the provider that was serving the id when
the user acted ("stock" or "plugin:<name>"). A record only applies while that
provider still serves the id, so a later plugin reusing the same menu id can
never inherit another plugin's customization. provider == nil matches any
provider (legacy data migrated from older formats).

Ordering intent is provider-aware too: every bulk sequence entry carries its
own era stamp (entries[i].provider), and position anchors carry a provider
stamp in their record. Entries or anchors stamped for a provider that no
longer serves the id are skipped at materialization time - a reused menu id
starts at its own provider's default slot instead of inheriting another
plugin's arrangement - and the original stamp reactivates when that provider
returns. Unstamped entries (legacy data) always apply.

Schema v3 consolidation (P1A): hidden_order, sequence_eras, the custom-menu
creation-time parent and the ui_state.hidden_anchors side map no longer
exist. Hide sequence lives in hidden[id].ordinal, sequence eras live on the
sequence entries themselves, a custom menu's parent lives ONLY in
parent_override[id].parent, and the hide-position display anchor was UI
bookkeeping that never belonged in canonical state.
--]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local AtomicWriter = require("lib.atomic_writer")
local DataLoader = require("lib.data_loader")
local MenuSchema = require("lib.menu_schema")

-- SCHEMA_VERSION is the on-disk format this build reads AND writes.
-- History:
--   0 (implicit) : pre-plugin-1.0 files without any version field
--   1            : first sparse-intent format (version field present,
--                  no generation counter)
--   2            : adds meta.generation (optimistic-concurrency base),
--                  drops nothing; v0/v1 migrate losslessly
--   3            : P1A canonical-state consolidation. Folds parallel
--                  structures into single-authority records:
--                    hidden_order        -> hidden[id].ordinal
--                    meta.ui_state.hidden_anchors -> DROPPED (UI bookkeeping)
--                    sequence_eras       -> order_override[menu].entries[i].provider
--                    custom_menus.parent -> parent_override[id].parent
--                  Also drops reconciliation lifecycle anchor pins
--                  (parent_override.anchor) and clears raw/semantic mode
--                  conflicts per menu. v2 and earlier migrate losslessly;
--                  the only discarded bytes are bookkeeping that never was
--                  user intent.
local SCHEMA_VERSION = 3

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

MIGRATIONS[2] = function(data)
    -- v2 -> v3: fold parallel representations into their canonical records.

    -- Deterministic migration rule for historical parent contradictions:
    -- an EXPLICIT move (provider-stamped override, anchor absent) outranks
    -- the creation-time home; among contradicting overrides for one id the
    -- lexicographically smallest parent wins so migration never depends on
    -- pairs() order. After this step custom_menus carries no parent field.
    local function normalize_view(section)
        if type(section) ~= "table" then return end

        -- (1) hidden_order + hidden_anchors -> hidden records.
        -- Ordinal = position in the historical hide-order list (the list was
        -- append-only, so its index IS the user's hide sequence).
        if type(section.hidden_order) == "table" then
            for index, id in ipairs(section.hidden_order) do
                local record = type(section.hidden[id]) == "table"
                    and section.hidden[id] or nil
                if record ~= nil and record.ordinal == nil then
                    record.ordinal = index
                end
            end
            section.hidden_order = nil
        end
        -- Records without any ordinal (hidden before ordering existed):
        -- assign ordinals deterministically by sorted id AFTER listed ids.
        local unnumbered = {}
        local max_ordinal = 0
        for id, record in pairs(type(section.hidden) == "table"
                and section.hidden or {}) do
            if type(record) == "table" then
                if type(record.ordinal) == "number" then
                    if record.ordinal > max_ordinal then
                        max_ordinal = record.ordinal
                    end
                else
                    table.insert(unnumbered, id)
                end
            end
        end
        if #unnumbered > 0 then
            table.sort(unnumbered)
            for _, id in ipairs(unnumbered) do
                max_ordinal = max_ordinal + 1
                section.hidden[id].ordinal = max_ordinal
            end
        end

        -- (2) sequence_eras -> order_override entries; dedupe sequences.
        local eras = type(section.sequence_eras) == "table"
            and section.sequence_eras or nil
        if type(section.order_override) == "table" then
            for menu_id, seq in pairs(section.order_override) do
                if type(seq) == "table" then
                    local menu_eras = eras and type(eras[menu_id]) == "table"
                        and eras[menu_id] or nil
                    local entries, seen = {}, {}
                    for _, id in ipairs(seq) do
                        if id == MenuSchema.SEPARATOR_ID then
                            table.insert(entries, { separator = true })
                        elseif not seen[id] then
                            seen[id] = true
                            local era = menu_eras and menu_eras[id] or nil
                            table.insert(entries,
                                { id = id, provider = era })
                        end
                    end
                    section.order_override[menu_id] = { entries = entries }
                end
            end
        end
        section.sequence_eras = nil

        -- (3) custom-menu parent authority: custom_menus.parent folds into
        -- parent_override. An explicit override wins over the creation-time
        -- parent; contradictions resolve to the explicit record above.
        if type(section.custom_menus) == "table" then
            for id, record in pairs(section.custom_menus) do
                if type(record) == "table" then
                    if type(record.parent) == "string" then
                        if type(section.parent_override) ~= "table" then
                            section.parent_override = {}
                        end
                        if section.parent_override[id] == nil then
                            section.parent_override[id] = {
                                provider = nil,
                                parent = record.parent,
                            }
                        end
                        record.parent = nil
                    end
                    if record.after == nil then record.after = false end
                end
            end
        end

        -- (4) Lifecycle anchor pins were reconciliation bookkeeping, never
        -- user intent: the RECORD is dropped outright (task §4 - a generated
        -- lifecycle pin must never be mistakable for an explicit user move,
        -- and keeping it while only stripping the marker would do exactly
        -- that). Nothing is lost: the materializer re-derives the same home
        -- live from the provider's registration on every resolve. A stray
        -- non-true anchor field on an otherwise explicit record is just
        -- removed bytes.
        for _, coll_name in ipairs({ "parent_override", "position_override" }) do
            local coll = section[coll_name]
            if type(coll) == "table" then
                for id, record in pairs(coll) do
                    if type(record) == "table" then
                        if record.anchor == true then
                            coll[id] = nil
                        else
                            record.anchor = nil
                        end
                    end
                end
            end
        end

        -- (5) mode exclusivity per menu: a raw passthrough owns the level.
        -- Semantic ordering records beside it are unrepresentable together
        -- and are cleared (raw wins: it is the verbatim user bytes).
        if type(section.raw_override) == "table" then
            for menu_id in pairs(section.raw_override) do
                if type(menu_id) == "string" then
                    if type(section.order_override) == "table" then
                        section.order_override[menu_id] = nil
                    end
                    if type(section.separators) == "table" then
                        for key, sep in pairs(section.separators) do
                            if type(sep) == "table" and sep.parent == menu_id then
                                section.separators[key] = nil
                            end
                        end
                    end
                end
            end
        end
    end

    if type(data.views) == "table" then
        for _, view in ipairs(MenuSchema.VIEWS) do
            normalize_view(data.views[view])
        end
    end
    -- The whole ui_state area was hidden-anchor bookkeeping.
    if type(data.meta) == "table" then
        data.meta.ui_state = nil
    end
    return data
end

local IntentStore = {}

IntentStore.SCHEMA_VERSION = SCHEMA_VERSION

local backup_seq = 0
local MAX_BACKUPS_PER_TYPE = 5

-- Prune older quarantine backups of the given suffix type to prevent unlimited
-- disk accumulation. Retains newest N backups deterministically.
local function pruneOldBackups(settings_dir, suffix)
    if not lfs or type(settings_dir) ~= "string" or type(suffix) ~= "string" then return end
    if lfs.attributes(settings_dir, "mode") ~= "directory" then return end
    local matching = {}
    local pattern = "^reorderingmenus_intent%.lua%." .. suffix .. "%-(%d+)%-(%d+)$"
    for file in lfs.dir(settings_dir) do
        local ts_str, seq_str = file:match(pattern)
        if ts_str and seq_str then
            table.insert(matching, {
                filename = file,
                path = string.format("%s/%s", settings_dir, file),
                ts = tonumber(ts_str) or 0,
                seq = tonumber(seq_str) or 0,
            })
        end
    end
    if #matching <= MAX_BACKUPS_PER_TYPE then return end
    table.sort(matching, function(a, b)
        if a.ts ~= b.ts then return a.ts > b.ts end
        return a.seq > b.seq
    end)
    for i = MAX_BACKUPS_PER_TYPE + 1, #matching do
        pcall(os.remove, matching[i].path)
    end
end

-- Preserve raw source bytes without routing them through the table serializer.
-- Backups use their own atomic temp+rename, prune older backups to stay within
-- the retention limit, and never overwrite an earlier recovery artifact.
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
    local settings_dir = DataStorage:getSettingsDir()
    pruneOldBackups(settings_dir, suffix)
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

-- Test hook: simulates a fresh process start (the real retry path for the
-- quarantine). Production code never calls this.
function IntentStore._resetPreservationForTests()
    original_preserved_on_disk = true
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
-- Load / persist
-- -------------------------------------------------------------------------

local state
-- Protected/read-only canonical storage (#1). Set when load() encounters an
-- unknown NEWER schema version: every durable write is refused until the
-- user explicitly resets/imports/downgrades (clearProtectedState). The
-- on-disk future-version file is the persisted guard - no extra metadata.
local protected_state = false
-- Epoch of the current in-memory canonical table. Bumped by every wholesale
-- reload of `state` (load(force_reload) after external file changes,
-- replaceState, resetView); openTransaction stamps it so commit() can refuse
-- transactions that staged from a superseded world (see Transaction above).
local store_epoch = 0

local function sanitizeSection(section)
    if type(section.hidden) ~= "table" then section.hidden = {} end
    if type(section.parent_override) ~= "table" then section.parent_override = {} end
    if type(section.position_override) ~= "table" then section.position_override = {} end
    if type(section.order_override) ~= "table" then section.order_override = {} end
    if type(section.custom_menus) ~= "table" then section.custom_menus = {} end
    if type(section.separators) ~= "table" then section.separators = {} end
    if type(section.raw_override) ~= "table" then section.raw_override = {} end
    if section.tab_order ~= nil and type(section.tab_order) ~= "table" then
        section.tab_order = nil
    end
    return section
end

-- Converge historical/current-but-contradictory shapes onto one canonical
-- authority model. This is lossless normalization, not corruption recovery:
-- dividers become anchored `separators` records, and a raw passthrough owns
-- its menu level exclusively.
local function normalizeCanonicalModes(section)
    local changed = false
    local separators = section.separators
    local order_override = section.order_override

    local menu_ids = {}
    for menu_id in pairs(order_override) do menu_ids[#menu_ids + 1] = menu_id end
    table.sort(menu_ids, function(a, b) return tostring(a) < tostring(b) end)
    for _, menu_id in ipairs(menu_ids) do
        local record = order_override[menu_id]
        if type(record) == "table" and type(record.entries) == "table" then
            local kept, previous, found_inline = {}, false, false
            for index, entry in ipairs(record.entries) do
                if MenuSchema.isSeparatorEntry(entry) then
                    found_inline = true
                    local base = "legacy_inline:" .. tostring(menu_id)
                        .. ":" .. tostring(index)
                    local key, suffix = base, 1
                    while separators[key] ~= nil do
                        suffix = suffix + 1
                        key = base .. ":" .. tostring(suffix)
                    end
                    separators[key] = { parent = menu_id, after = previous }
                else
                    kept[#kept + 1] = entry
                    if type(entry) == "table" and type(entry.id) == "string" then
                        previous = entry.id
                    end
                end
            end
            if found_inline then
                record.entries = kept
                changed = true
            end
        end
    end

    for menu_id in pairs(section.raw_override) do
        if order_override[menu_id] ~= nil then
            order_override[menu_id] = nil
            changed = true
        end
        for key, sep in pairs(separators) do
            if type(sep) == "table" and sep.parent == menu_id then
                separators[key] = nil
                changed = true
            end
        end
    end
    return changed
end

-- -------------------------------------------------------------------------
-- Canonical-state validation (P0 hardening): a corrupt canonical intent
-- file must never silently become a clean empty configuration.
--
-- collectProblems returns { { kind, view, collection, key, detail }, ... }.
-- repairProblems drops ONLY offending records; healthy siblings survive.
-- -------------------------------------------------------------------------

local function isStringArray(t)
    if type(t) ~= "table" then return false end
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
            local position_override = section.position_override or {}
            local parent_override = section.parent_override or {}
            local order_override = section.order_override or {}
            local custom_menus = section.custom_menus or {}
            local separators = section.separators or {}
            local raw_override = section.raw_override or {}
            for id, record in pairs(hidden) do
                if type(record) ~= "table" then
                    problems[#problems + 1] = { kind = "malformed_record",
                        view = view, collection = "hidden", key = id,
                        detail = "record is not a table" }
                elseif type(record.ordinal) ~= "number" then
                    -- Invariant: every hidden member carries its ordering
                    -- metadata. Missing ordinal is healed deterministically
                    -- (never destroyed) - see repairProblems.
                    problems[#problems + 1] = { kind = "missing_ordinal",
                        view = view, collection = "hidden", key = id,
                        detail = "hidden record carries no ordinal" }
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
            for menu_id, override in pairs(order_override) do
                if type(override) ~= "table" or type(override.entries) ~= "table" then
                    problems[#problems + 1] = { kind = "malformed_sequence",
                        view = view, collection = "order_override", key = menu_id,
                        detail = "sequence record has no entries array" }
                else
                    local seen = {}
                    for index, entry in ipairs(override.entries) do
                        local entry_id = MenuSchema.isSeparatorEntry(entry)
                            and MenuSchema.SEPARATOR_ID or type(entry) == "table"
                            and entry.id or nil
                        if type(entry_id) ~= "string" then
                            problems[#problems + 1] = { kind = "malformed_sequence",
                                view = view, collection = "order_override",
                                key = menu_id,
                                detail = "entry " .. tostring(index)
                                    .. " is not an id/separator token" }
                        elseif seen[entry_id] then
                            problems[#problems + 1] = { kind = "duplicate_entry",
                                view = view, collection = "order_override",
                                key = menu_id, detail = "duplicate id " .. entry_id }
                        end
                        if entry_id ~= nil then seen[entry_id] = true end
                    end
                end
            end
            for id, record in pairs(custom_menus) do
                if type(record) ~= "table" or type(record.title) ~= "string"
                        or record.title == "" then
                    problems[#problems + 1] = { kind = "malformed_record",
                        view = view, collection = "custom_menus", key = id,
                        detail = "missing title" }
                end
                -- Parent lives ONLY in parent_override now; a stray .parent
                -- field on a v3 record is ignored by the materializer and
                -- stripped at the next save - not corruption.
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
            if p.collection == "tab_order" then
                section.tab_order = nil
            elseif p.kind == "missing_ordinal" then
                -- Healed by the structural normalization pass below (which
                -- assigns a deterministic ordinal); nothing to do here.
            elseif p.collection == "order_override"
                    and p.kind == "duplicate_entry" then
                -- Keep the FIRST occurrence of a duplicated id; drop later
                -- copies (same policy the transactional writer applies).
                local override = section.order_override and section.order_override[p.key]
                if type(override) == "table" and type(override.entries) == "table" then
                    local seen, kept = {}, {}
                    for _, entry in ipairs(override.entries) do
                        local entry_id = MenuSchema.isSeparatorEntry(entry)
                            and MenuSchema.SEPARATOR_ID or entry.id
                        if not seen[entry_id] then
                            seen[entry_id] = true
                            table.insert(kept, entry)
                        end
                    end
                    override.entries = kept
                end
            elseif p.collection ~= "view" and p.key ~= nil then
                local coll = section[p.collection]
                if type(coll) == "table" then coll[p.key] = nil end
            end
            -- Whole-collection / whole-view problems are healed by
            -- sanitizeSection after validation; nothing per-record to drop.
        end
    end
    -- Structural normalization that needs no quarantine: hidden records must
    -- all carry an ordinal. Missing ordinals are assigned deterministically
    -- after the highest existing one (sorted id order).
    for _, view in ipairs(MenuSchema.VIEWS) do
        local section = state.views[view]
        if type(section) == "table" and type(section.hidden) == "table" then
            local unnumbered, max_ordinal = {}, 0
            for id, record in pairs(section.hidden) do
                if type(record) == "table" then
                    if type(record.ordinal) == "number" then
                        if record.ordinal > max_ordinal then
                            max_ordinal = record.ordinal
                        end
                    else
                        table.insert(unnumbered, id)
                    end
                end
            end
            if #unnumbered > 0 then
                table.sort(unnumbered)
                for _, id in ipairs(unnumbered) do
                    max_ordinal = max_ordinal + 1
                    section.hidden[id].ordinal = max_ordinal
                end
            end
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

local function readLegacySidecarState()
    local legacy_path = string.format("%s/reorderingmenus_state.lua", DataStorage:getSettingsDir())
    if lfs.attributes(legacy_path, "mode") ~= "file" then
        return nil
    end
    local loaded, err = DataLoader.loadTable(legacy_path, "legacy sidecar state")
    if not loaded or type(loaded) ~= "table" then return nil end
    local legacy_state = newState()
    for _, view in ipairs(MenuSchema.VIEWS) do
        local origins = type(loaded.hidden_origins) == "table"
            and loaded.hidden_origins[view] or nil
        if type(origins) == "table" then
            local unnumbered = {}
            for id in pairs(origins) do
                table.insert(unnumbered, id)
            end
            table.sort(unnumbered)
            for idx, id in ipairs(unnumbered) do
                local parent = origins[id]
                legacy_state.views[view].hidden[id] = {
                    provider = nil,
                    origin = type(parent) == "string" and parent or nil,
                    ordinal = idx,
                }
            end
        end
    end
    if loaded.mirror_changes ~= nil then
        legacy_state.meta.mirror_changes = loaded.mirror_changes == true
    end
    if loaded.hidden_in_place ~= nil then
        legacy_state.meta.hidden_in_place = loaded.hidden_in_place ~= false
    end
    return legacy_state
end

local function readStoredState(path)
    -- P0-7: canonical intent is DATA. One restricted loader for every
    -- serialized-state file; the raw text is still returned separately so
    -- corruption recovery can quarantine the ORIGINAL bytes verbatim.
    if lfs.attributes(path, "mode") ~= "file" then
        local legacy = readLegacySidecarState()
        if legacy then
            return legacy, nil, nil, true
        end
        return newState(), nil, nil, false
    end
    local raw_text, read_err = DataLoader.readBounded(path)
    if not raw_text then
        return newState(), nil, tostring(read_err or "unreadable"), false
    end

    local loaded, load_err = DataLoader.loadTable(path)
    if loaded then
        return loaded, raw_text, nil, false
    end
    return newState(), raw_text, tostring(load_err), false
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
        if normalizeCanonicalModes(loaded.views[view]) then changed = true end
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
    if type(loaded.meta.generation) ~= "number" then
        loaded.meta.generation = 0
        changed = true
    end
    if type(loaded.meta.view_generations) ~= "table" then
        loaded.meta.view_generations = {}
        changed = true
    end
    for _, view in ipairs(MenuSchema.VIEWS) do
        if type(loaded.meta.view_generations[view]) ~= "number" then
            loaded.meta.view_generations[view] = 0
            changed = true
        end
    end
    -- meta.ui_state (hidden anchors) was removed in schema v3: it was UI
    -- bookkeeping, not user intent. Strip any residue from pre-migration
    -- in-memory shapes.
    if loaded.meta.ui_state ~= nil then
        loaded.meta.ui_state = nil
        changed = true
    end
    return changed
end

function IntentStore.load(force_reload)
    if state and not force_reload then return state end

    local path = getSettingsPath()
    local loaded, raw_text, parse_error, is_legacy_migration = readStoredState(path)
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
    -- Protection is RE-DERIVED from the current disk contents on every full
    -- load: replacing or removing the guarded file externally lifts it.
    protected_state = false
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
        -- Protected/read-only storage (#1): an unknown NEWER schema keeps
        -- canonical storage frozen until the user explicitly resets,
        -- imports or downgrades. The future bytes stay at the canonical
        -- path untouched; every durable write is refused for as long as
        -- that file sits there (the on-disk file IS the persisted guard -
        -- it survives restarts without extra bookkeeping). The quarantine
        -- copy above remains as a second, redundant safety net.
        protected_state = true
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

    local migrated = migrateState(loaded) or (is_legacy_migration == true)
    local normalized_views = normalizeViews(loaded, problems)
    -- Some problems are healed WITHOUT losing any user record (the repair
    -- only adds missing bookkeeping). Quarantining a file our own writer or
    -- migration just produced would treat healthy state as corruption and
    -- cascade into data loss; reserve backups for destructive repairs.
    local BENIGN_HEALS = { duplicate_entry = true, missing_ordinal = true }
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
        elseif is_legacy_migration then
            logger.info("ReorderingMenus: migrated legacy sidecar state into intent store schema",
                SCHEMA_VERSION)
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
    -- Protected storage (#1): an unknown newer schema owns this file until
    -- the user explicitly authorizes replacement. Unrelated preference
    -- writes, saves and restart normalization must not touch it.
    if protected_state then
        logger.err("ReorderingMenus: refusing to write intent file:",
            "storage is protected by an unsupported future schema")
        return false, "protected_state"
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

-- -------------------------------------------------------------------------
-- Protected-state recovery (#1): the ONLY way durable writes resume while
-- an unknown future schema guards canonical storage. Callers must gate
-- this behind an EXPLICIT user action (reset / import / downgrade flow) -
-- it is what authorizes replacing the guarded original bytes.
--
--   clearProtectedState(new_bytes?)  - user chose a replacement: remove the
--                                      guarded file (optionally staging
--                                      new content), lift protection, and
--                                      reload from disk.
--   isProtected()                    - UI query: show the read-only notice
--                                      and offer the recovery actions.
--
-- The in-memory state stays whatever load() produced (fresh/empty); nothing
-- from the guarded file is ever interpreted as current-format data.
-- -------------------------------------------------------------------------
function IntentStore.isProtected()
    return protected_state
end

function IntentStore.clearProtectedState(replacement_bytes)
    local path = getSettingsPath()
    if lfs.attributes(path, "mode") == "file" then
        local ok, err = os.remove(path)
        if not ok and replacement_bytes == nil then
            return false, tostring(err or "remove failed")
        end
    end
    if replacement_bytes ~= nil then
        local fh = io.open(path, "wb")
        if not fh then return false, "cannot stage replacement" end
        fh:write(replacement_bytes)
        fh:close()
    end
    protected_state = false
    state = nil
    -- Full reload re-derives everything (including protection state) from
    -- what is now on disk; transactions staged against the frozen world
    -- are superseded exactly like any other wholesale swap.
    IntentStore.load(true)
    store_epoch = store_epoch + 1
    return true
end

function IntentStore.isCustomized(view)
    -- Customized == applicable canonical USER intent exists. Deliberately
    -- NOT derived from the native file, the sidecar, or any cache: a stale
    -- derived file, a missing native module, or an unregenerated checkpoint
    -- says nothing about what the user asked for. The predicate is typed in
    -- MenuSchema: lifecycle pins (record.anchor) and display bookkeeping are
    -- excluded, so registration-time reconciliation can never make a stock
    -- menu look customized.
    return MenuSchema.sectionHasUserIntent(IntentStore.view(view))
end

-- -------------------------------------------------------------------------
-- Transactions
-- -------------------------------------------------------------------------

-- Editors and bulk operations mutate a staged copy of the state through an
-- IntentTransaction; commit makes the staging canonical (and persists), while
-- discard throws it away. View intent and hidden-anchor changes made through
-- the transaction are committed together; standalone preferences persist
-- immediately through IntentStore.setMeta.
--
-- EXPLICIT STATE MACHINE (Bug-1 hardening):
--
--     OPEN --> COMMITTED
--     OPEN --> DISCARDED
--
-- Spent (COMMITTED/DISCARDED) transactions are DEAD OBJECTS:
--   * every mutation method refuses (canonical can never be modified through
--     a dead transaction);
--   * commit() again refuses ("transaction_spent");
--   * discard() of an already-discarded transaction is a harmless no-op,
--     while discard() of a COMMITTED one refuses;
--   * read paths (view/section/meta/anchors) hand out COPIES once spent -
--     a dead object cannot alias mutable canonical or staging state;
--   * commit installs DEEP COPIES into canonical: canonical and the
--     transaction's staging are separate tables from the moment of commit.
-- A transaction whose DURABLE WRITE failed is force-discarded: its abandoned
-- staging must never ride a later unrelated save.

local TXN_PHASE_OPEN = "OPEN"
local TXN_PHASE_COMMITTED = "COMMITTED"
local TXN_PHASE_DISCARDED = "DISCARDED"

local Transaction = {}
Transaction.__index = Transaction

function Transaction:phase()
    return self.txn_phase or TXN_PHASE_OPEN
end

function Transaction:isOpen()
    return self:phase() == TXN_PHASE_OPEN
end

-- One-shot warn per operation kind: repeated refusals of the same op on the
-- same dead transaction carry no new information.
local warned_ops = setmetatable({}, { __mode = "k" })
local function refuse_spent(txn, op)
    if not warned_ops[txn] then
        warned_ops[txn] = {}
    end
    if not warned_ops[txn][op] then
        warned_ops[txn][op] = true
        logger.warn("ReorderingMenus: refused", op, "on",
            tostring(txn:phase()), "transaction")
    end
end

-- Guard for MUTATING methods: spent transactions are dead objects; a call
-- into one must never reach staging or canonical state. Returns true when
-- the caller should proceed (transaction OPEN).
local function mutator_gate(txn)
    if txn:isOpen() then return true end
    local name = "mutation"
    local info = debug and debug.getinfo and debug.getinfo(3, "n") or nil
    if info and info.name then name = tostring(info.name) end
    refuse_spent(txn, name)
    return false
end

function IntentStore.openTransaction()
    local txn = setmetatable({
        staged = util.tableDeepCopy(IntentStore.load().views),
        committed = false,
        discarded = false,
        -- Bug-1 state machine: OPEN -> COMMITTED | DISCARDED. The legacy
        -- boolean flags stay in sync for any reader still consulting them.
        txn_phase = TXN_PHASE_OPEN,
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
    if not self:isOpen() then
        -- Spent transactions hand out SNAPSHOTS. A discarded transaction
        -- must not expose live canonical state (it did before: mutating the
        -- returned table wrote straight into canonical); a committed one
        -- must not expose its own (now detached) staging either.
        local source = self.discarded and IntentStore.view(view) or self.staged[view]
        return util.tableDeepCopy(source or {})
    end
    if type(self.staged[view]) ~= "table" then
        self.staged[view] = newViewSection()
    end
    return self.staged[view]
end

function Transaction:section(view, name)
    if not self:isOpen() then
        local v = self:view(view)
        return type(v[name]) == "table" and v[name] or {}
    end
    local v = self:view(view)
    if type(v[name]) ~= "table" then v[name] = {} end
    return v[name]
end

-- P0-11: preference flips while a transaction is open land in BOTH the
-- staged metadata and in-memory canonical meta, but durable persistence is
-- DEFERRED to this transaction's commit - IntentStore.save() must never
-- freeze canonical views together with a mid-transaction toggle (mixed
-- ownership). The staged value wins on commit; Discard restores the exact
-- pre-flip canonical values in memory along with dropping staged sections.
function Transaction:setMetaValue(key, value)
    if not mutator_gate(self) then return false end
    self.staged_meta = self.staged_meta or {}
    if self.staged_meta[key] == nil and self.meta_base == nil then
        self.meta_base = {}
    end
    if self.staged_meta[key] == nil then
        -- First flip of this key in this transaction: remember the value
        -- Discard must restore.
        local meta = IntentStore.meta()
        self.meta_base[key] = type(meta) == "table" and meta[key] or nil
    end
    self.staged_meta[key] = value
    local meta = IntentStore.meta()
    if type(meta) == "table" then meta[key] = value end
end

-- Sparse bookkeeping: an override equal to the current default carries no
-- information and is dropped instead of persisted.
--
-- Hidden records are the SINGLE representation of a hide: membership,
-- restore origin, and hide sequence (ordinal) live on one record. There is
-- no side list that could fall out of sync - an id cannot be hidden without
-- its ordering metadata, because that metadata IS the record. The ordinal
-- counter is per-view staging state so successive setHidden calls append.
function Transaction:setHidden(view, item_id, record)
    if not mutator_gate(self) then return end
    local hidden = self:section(view, "hidden")
    if record == nil then
        hidden[item_id] = nil
    else
        -- Idempotent re-hide (Y3 byte-stability): re-hiding an id that is
        -- ALREADY hidden preserves its existing ordinal and origin - the
        -- user's hide sequence must not shift just because a save/reload
        -- cycle or a mirror re-applied the same hide. Only a genuinely NEW
        -- hide appends to the sequence.
        local existing = hidden[item_id]
        if type(existing) == "table" then
            if record.ordinal ~= nil then
                existing.ordinal = record.ordinal
            end
            if record.provider ~= nil then
                existing.provider = record.provider
            end
            if type(record.origin) == "string" and existing.origin == nil then
                existing.origin = record.origin
            end
            return
        end
        -- The accessor expects a SECTION wrapper, not the bare map.
        local next_ordinal = MenuSchema.nextHiddenOrdinal({ hidden = hidden })
        hidden[item_id] = {
            provider = record.provider,
            origin = type(record.origin) == "string" and record.origin or nil,
            ordinal = record.ordinal ~= nil and record.ordinal or next_ordinal,
        }
    end
end

function Transaction:getHidden(view, item_id)
    return self:section(view, "hidden")[item_id]
end

function Transaction:setParentOverride(view, item_id, record)
    if not mutator_gate(self) then return end
    self:section(view, "parent_override")[item_id] = record
end

-- Typed placement writer for LIFECYCLE bookkeeping (registration-time pins).
-- The anchor marker is explicit so isCustomized can exclude it: a pin is not
-- user intent and must never make a stock menu look customized.
function Transaction:setLifecyclePin(view, item_id, kind, record)
    if not mutator_gate(self) then return end
    record = type(record) == "table" and record or {}
    if MenuSchema.LIFECYCLE_PIN_KINDS[kind] then
        record.anchor = kind
        self:section(view, "parent_override")[item_id] = record
    end
end

function Transaction:getParentOverride(view, item_id)
    return self:section(view, "parent_override")[item_id]
end

function Transaction:setPositionOverride(view, item_id, record)
    if not mutator_gate(self) then return end
    self:section(view, "position_override")[item_id] = record
end

-- One authoritative sequence record per menu: entries carry their own
-- provider era, so no parallel era map can desynchronize. Canonical
-- sequences are id-unique per menu (the loader treats a duplicate as
-- corruption); every writer funnels through here, so the invariant is
-- enforced at the door: keep the FIRST occurrence - the position already
-- arranged - and drop later copies. Dividers are converted immediately into
-- anchored records in the sole canonical `separators` collection.
function Transaction:setOrderOverride(view, menu_id, sequence, eras)
    if not mutator_gate(self) then return end
    if sequence == nil or #sequence == 0 then
        self:section(view, "order_override")[menu_id] = nil
        return
    end
    self:section(view, "raw_override")[menu_id] = nil
    local pos_overrides = self:section(view, "position_override")
    local separators = self:section(view, "separators")
    local sequence_has_separators = false
    for _, id in ipairs(sequence) do
        if id == MenuSchema.SEPARATOR_ID then
            sequence_has_separators = true
            break
        end
    end
    -- A plain item sequence and separator anchors are independent canonical
    -- authorities. Preserve existing anchors unless this call explicitly
    -- supplies divider tokens, in which case it is replacing both facets.
    if sequence_has_separators then
        for key, sep in pairs(separators) do
            if type(sep) == "table" and sep.parent == menu_id then
                separators[key] = nil
            end
        end
    end
    local deduped, dropped = {}, nil
    local seen = {}
    local previous = false
    for index, id in ipairs(sequence) do
        if id == MenuSchema.SEPARATOR_ID then
            local base = "sequence:" .. tostring(menu_id) .. ":" .. tostring(index)
            local key, suffix = base, 1
            while separators[key] ~= nil do
                suffix = suffix + 1
                key = base .. ":" .. tostring(suffix)
            end
            separators[key] = { parent = menu_id, after = previous }
        elseif seen[id] then
            dropped = dropped or id
        else
            seen[id] = true
            if pos_overrides[id] ~= nil then
                pos_overrides[id] = nil
            end
            local era = type(eras) == "table" and eras[id] or nil
            -- Era stamps travel with their entry; an override written
            -- without stamps (legacy/imported shape) applies unconditionally.
            table.insert(deduped, { id = id, provider = era })
            previous = id
        end
    end
    if dropped then
        logger.warn("ReorderingMenus: order_override sequence for",
            tostring(view) .. "/" .. tostring(menu_id),
            "carried duplicate entries (first:", dropped,
            ") - keeping first occurrence")
    end
    self:section(view, "order_override")[menu_id] = { entries = deduped }
end

-- Custom-menu creation record: title (+ optional arrival anchor) only. The
-- menu's parent lives EXCLUSIVELY in parent_override[id] - there is exactly
-- one canonical answer to "what is this custom menu's explicit parent".
function Transaction:setCustomMenu(view, submenu_id, record)
    if not mutator_gate(self) then return end
    if record == nil or record == false then
        self:section(view, "custom_menus")[submenu_id] = nil
    else
        self:section(view, "custom_menus")[submenu_id] = {
            title = type(record) == "table" and record.title or nil,
            after = type(record) == "table" and record.after or nil,
        }
    end
end

function Transaction:getCustomMenus(view)
    return self:section(view, "custom_menus")
end

function Transaction:setSeparator(view, key, record)
    if not mutator_gate(self) then return end
    self:section(view, "separators")[key] = record
end

-- Raw passthrough: OPAQUE mode for one menu level. Installing a raw level
-- clears that level's semantic ordering records - the two authorities are
-- mutually exclusive by construction (the raw bytes ARE the arrangement).
function Transaction:setRawOverride(view, menu_id, list)
    if not mutator_gate(self) then return end
    if list == nil or #list == 0 then
        self:section(view, "raw_override")[menu_id] = nil
    else
        self:section(view, "raw_override")[menu_id] = { list = list }
        self:view(view).order_override[menu_id] = nil
        local pos_overrides = self:section(view, "position_override")
        for _, id in ipairs(list) do
            if type(id) == "string" and pos_overrides[id] ~= nil then
                pos_overrides[id] = nil
            end
        end
        local separators = self:view(view).separators
        for key, sep in pairs(type(separators) == "table" and separators or {}) do
            if type(sep) == "table" and sep.parent == menu_id then
                separators[key] = nil
            end
        end
    end
end

function Transaction:setTabOrder(view, tabs)
    if not mutator_gate(self) then return end
    self:view(view).tab_order = tabs
end

function Transaction:clearItem(view, item_id)
    -- Remove every trace of user action for one id: the definition of
    -- "restore to whatever the current default says".
    if not mutator_gate(self) then return end
    self:section(view, "hidden")[item_id] = nil
    self:section(view, "parent_override")[item_id] = nil
    self:section(view, "position_override")[item_id] = nil
    local touched = {}
    for menu_id in pairs(self:section(view, "order_override")) do
        table.insert(touched, menu_id)
    end
    local overrides = self:view(view).order_override
    for _, menu_id in ipairs(touched) do
        local override = overrides[menu_id]
        if type(override) == "table" and type(override.entries) == "table" then
            local kept = {}
            for _, entry in ipairs(override.entries) do
                if not MenuSchema.isSeparatorEntry(entry) and entry.id ~= item_id then
                    table.insert(kept, entry)
                end
            end
            overrides[menu_id] = #kept > 0 and { entries = kept } or nil
        end
    end
end

function Transaction:setViewSection(view, section)
    if not mutator_gate(self) then return end
    self.staged[view] = section
end

-- Record collections compared per id/key by Transaction:mergeSection.
local MERGED_COLLECTIONS = {
    "hidden", "parent_override", "position_override",
    "order_override", "custom_menus",
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
-- Every remaining field is a per-record map or whole-view ordering (tab_order),
-- so no special-casing of parallel bookkeeping lists remains. Returns the
-- merged section.
function Transaction:mergeSection(view)
    local base_section = self.base_sections
        and self.base_sections[view] or nil
    -- Bug-1: staging may be nil on a force-discarded (failed IO) transaction;
    -- the merge then simply adopts canonical for this view.
    local staged = (self.staged and self.staged[view]) or {}
    local canonical = IntentStore.view(view)

    -- Untouched view: adopt canonical wholesale.
    if base_section == nil then
        return util.tableDeepCopy(canonical)
    end
    if util.tableEquals(base_section, staged) then
        return util.tableDeepCopy(canonical)
    end

    local merged = util.tableDeepCopy(staged)
    for _, coll_name in ipairs(MERGED_COLLECTIONS) do
        merged[coll_name] = mergeRecordMap(base_section[coll_name],
            staged[coll_name], canonical[coll_name])
    end
    for _, field in ipairs({ "tab_order" }) do
        if valuesEqual(staged[field], base_section[field]) then
            merged[field] = util.tableDeepCopy(canonical[field])
        end
    end
    return merged
end

function Transaction:resetView(view)
    if not mutator_gate(self) then return end
    self.staged[view] = newViewSection()
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
        changed[v] = not util.tableEquals(self.staged and self.staged[v] or {},
            previous_views[v] or {})
    end
    return changed
end

function Transaction:hasMetaChanges()
    if type(self.staged_meta) ~= "table" or type(self.meta_base) ~= "table" then
        return false
    end
    for key, value in pairs(self.staged_meta) do
        if not util.tableEquals(value, self.meta_base[key]) then return true end
    end
    return false
end

-- Remove references to a deleted custom submenu everywhere.
function Transaction:deleteCustomMenu(view, submenu_id)
    if not mutator_gate(self) then return end
    self:view(view).custom_menus[submenu_id] = nil
    -- The parent record IS the placement authority; deleting the menu
    -- removes it (and everything that placed items inside the level).
    self:view(view).parent_override[submenu_id] = nil
    self:view(view).position_override[submenu_id] = nil
    self:view(view).hidden[submenu_id] = nil
    self:view(view).raw_override[submenu_id] = nil
    self:view(view).order_override[submenu_id] = nil
    for key, sep in pairs(self:view(view).separators or {}) do
        if type(sep) == "table"
                and (sep.parent == submenu_id or sep.after == submenu_id) then
            self:view(view).separators[key] = nil
        end
    end
    -- Defensive direct-API semantics: bypassing the manager's non-empty
    -- refusal still cannot leave children aimed at a deleted level.
    for id, record in pairs(self:view(view).parent_override or {}) do
        if type(record) == "table" and record.parent == submenu_id then
            self:view(view).parent_override[id] = nil
        end
    end
    for _, record in pairs(self:view(view).hidden or {}) do
        if type(record) == "table" and record.origin == submenu_id then
            record.origin = nil
        end
    end
    for id, record in pairs(self:view(view).position_override or {}) do
        if type(record) == "table"
                and (record.after == submenu_id or record.before == submenu_id) then
            self:view(view).position_override[id] = nil
        end
    end
    for _, raw in pairs(self:view(view).raw_override or {}) do
        if type(raw) == "table" and type(raw.list) == "table" then
            local kept = {}
            for _, id in ipairs(raw.list) do
                if id ~= submenu_id then kept[#kept + 1] = id end
            end
            raw.list = kept
        end
    end
    if type(self:view(view).tab_order) == "table" then
        local kept = {}
        for _, id in ipairs(self:view(view).tab_order) do
            if id ~= submenu_id then kept[#kept + 1] = id end
        end
        self:view(view).tab_order = #kept > 0 and kept or nil
    end
    local touched = {}
    for menu_id in pairs(self:view(view).order_override or {}) do
        table.insert(touched, menu_id)
    end
    local overrides = self.staged[view].order_override
    for _, menu_id in ipairs(touched) do
        local override = overrides and overrides[menu_id]
        if type(override) == "table" and type(override.entries) == "table" then
            local kept = {}
            for _, entry in ipairs(override.entries) do
                if not MenuSchema.isSeparatorEntry(entry)
                        and entry.id ~= submenu_id then
                    table.insert(kept, entry)
                end
            end
            overrides[menu_id] = #kept > 0 and { entries = kept } or nil
        end
    end
end

function Transaction:commit(persist)
    if not self:isOpen() then
        refuse_spent(self, "commit")
        return false, "transaction_spent"
    end
    -- Roll back the in-memory swap when the durable write fails: the saved
    -- baseline must never claim success it does not have.
    local previous_views = state.views
    local meta = IntentStore.meta()
    local previous_generation = type(meta.generation) == "number"
        and meta.generation or 0
    local previous_view_generations = util.tableDeepCopy(
        type(meta.view_generations) == "table" and meta.view_generations or {})
    local changed_views = {}
    local view_changed = false
    for _, v in ipairs(MenuSchema.VIEWS) do
        changed_views[v] = not util.tableEquals(self.staged[v] or {},
            previous_views[v] or {})
        view_changed = view_changed or changed_views[v]
    end
    -- P0-11: staged preference flips (setMetaValue) commit with the layout.
    -- setMetaValue already wrote the new value into in-memory canonical meta
    -- (so reads stay coherent mid-transaction); whether this is a REAL flip
    -- is therefore decided against the BASE snapshot taken at first flip,
    -- never against the current canonical value.
    local meta_flip_only = false
    if type(self.staged_meta) == "table" and type(self.meta_base) == "table" then
        for key, value in pairs(self.staged_meta) do
            local base = self.meta_base[key]
            if not util.tableEquals(value, base) then
                meta_flip_only = true
                break
            end
        end
        for key, value in pairs(self.staged_meta) do
            meta[key] = value
        end
    end
    -- Bug-1: install DEEP COPIES into canonical. Canonical must never alias
    -- the transaction's staging - otherwise a stale handle grabbed from the
    -- transaction keeps a live write path into committed state, and the next
    -- openTransaction's staging would be a copy of an object someone else
    -- still mutates. The staging tables stay frozen snapshots after commit.
    state.views = util.tableDeepCopy(self.staged)
    -- Optimistic concurrency: the transaction remembers which canonical
    -- generation it staged from. If canonical advanced since (another
    -- writer committed), this commit would silently drop that work, so it
    -- refuses and reports the conflict. Callers re-open a fresh
    -- transaction (which stages the newer canonical) and re-apply.
    if self.base_generation ~= nil
            and self.base_generation ~= IntentStore.generation() then
        state.views = previous_views
        return false, "stale_transaction"
    end
    -- Epoch guard: the in-memory canonical table was swapped wholesale
    -- after this transaction staged (load(true) absorbing a rollback).
    -- The generation check above cannot see that - a restored file may
    -- carry ANY counter value - so compare epochs: staging from a
    -- superseded world would fuse the old world into the restored one.
    if self.store_epoch ~= nil
            and self.store_epoch ~= IntentStore.storeEpoch() then
        state.views = previous_views
        return false, "stale_transaction"
    end
    -- Semantic no-op commits (staged sections equal canonical in both
    -- views) carry no information: they must not advance any generation
    -- counter nor rewrite the durable file. Generation counters are the
    -- optimistic-concurrency currency; idle saves inflating them would
    -- force every later legitimate commit to look stale, and would make
    -- syncView believe derived files lag after a pure no-op.
    -- EXCEPTION (P0-11): a staged PREFERENCE flip is real user state -
    -- it must persist even when no view section moved (without this,
    -- a mid-transaction toggle dies on the next no-op save).
    local changed = view_changed or meta_flip_only
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
            state.views = previous_views
            -- Bug-1: the durable write failed, so this staging is DEAD.
            -- Force-discard it: an abandoned transaction whose staged
            -- table used to alias canonical could otherwise ride a later
            -- unrelated save and commit half its edits. Callers treat
            -- commit failure as terminal and restage from canonical.
            self.committed = false
            self.discarded = true
            self.txn_phase = TXN_PHASE_DISCARDED
            -- Supersede the in-memory world: staging snapshots taken
            -- before the failed write describe a state that never became
            -- canonical, and ensureTxn() must open fresh staging.
            store_epoch = store_epoch + 1
            return false, err
        end
    end
    -- unchanged: nothing durable to write; the swap is identity anyway.
    self.committed = true
    self.discarded = false
    self.txn_phase = TXN_PHASE_COMMITTED
    return true
end

function Transaction:discard()
    if self.committed or self:phase() == TXN_PHASE_COMMITTED then
        -- A committed transaction has no unsaved work to throw away; its
        -- lifecycle ended at commit. Refuse rather than silently re-brand
        -- it as discarded (callers must not read "discard()==true" as
        -- "there was something to discard").
        refuse_spent(self, "discard-after-commit")
        return false, "transaction_spent"
    end
    if not self:isOpen() then
        -- Discarding an already-discarded transaction is a harmless no-op:
        -- idempotent teardown, exactly like closing a closed file.
        return true
    end
    -- P0-11: preference flips made via setMetaValue are INDEPENDENT user
    -- state - they survive the abandoned layout edit. They were applied to
    -- in-memory canonical meta at flip time and never touched staging, so
    -- Discard has nothing to revert; the flip becomes durable here via a
    -- plain save() (which writes canonical views - never staging - so no
    -- half-staged layout can leak to disk with it).
    if type(self.meta_base) == "table" and next(self.meta_base) ~= nil then
        IntentStore.save()
    end
    self.discarded = true
    self.committed = false
    self.txn_phase = TXN_PHASE_DISCARDED
    self.staged = nil
end

IntentStore.newViewSection = newViewSection
return IntentStore

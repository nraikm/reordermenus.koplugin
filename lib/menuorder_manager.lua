--[[--
menuorder_manager.lua — orchestrator facade for the sparse intent pipeline.

Wiring (see README "Architecture"):

    KOReader defaults + live plugin contributions      (koreader_adapter)
                        |
                  BASE REGISTRY                          (registry)
                        |
    User Intent ------------------------------------>  MATERIALIZER   (materializer)
                        |                             pure resolve()
                        v
             validated resolved menu graph               (validator)
                        v
           minimal KOReader native overrides           (native_writer)
                        v
                   stock MenuSorter

The ONLY canonical persistent state is the sparse intent store. Everything a
menu shows is derived from (current defaults x intent) on demand, so:

  - untouched menus are never written to disk at all (sparse native files),
    letting KOReader updates flow through with zero reconciliation
  - identity is (id, provider): records stop applying when another provider
    serves the same id, so plugins can never inherit each other's customization
  - external edits of the native files are detected against the last
    materialized structure and imported back as explicit intent

This module keeps the historical imperative API used by the editors and the
tests; every mutating verb translates into intent operations on an
IntentTransaction, and every read is served by a freshly materialized
projection.
--]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local KoreaderAdapter = require("lib.koreader_adapter")
local MenuSchema = require("lib.menu_schema")
local Registry = require("lib.registry")
local IntentStore = require("lib.intent_store")
local Materializer = require("lib.materializer")
local Validator = require("lib.validator")
local NativeWriter = require("lib.native_writer")
local SemanticDiff = require("lib.semantic_diff")
local Random = require("random")
local Presets = require("lib.presets")
local PluginPrefs = require("lib.plugin_prefs")
local GhostGC = require("lib.ghost_gc")
local CommitPipeline = require("lib.commit_pipeline")
local DataLoader = require("lib.data_loader")
local Placement = require("lib.placement")
local Visibility = require("lib.visibility")

local SEPARATOR_ID = MenuSchema.SEPARATOR_ID
local MENU_BUTTONS_KEY = MenuSchema.MENU_BUTTONS_KEY
local DISABLED_KEY = MenuSchema.DISABLED_KEY
local CUSTOM_SUBMENUS_KEY = MenuSchema.CUSTOM_SUBMENUS_KEY

local MenuOrderManager = {
    SEPARATOR_ID = SEPARATOR_ID,
    CUSTOM_SUBMENUS_KEY = CUSTOM_SUBMENUS_KEY,
    -- Compatibility alias: holds the latest materialized projection per view.
    orders = {
        reader = nil,
        filemanager = nil,
    },
    -- Test/override hook: when set, replaces the stock defaults everywhere
    -- (simulating KOReader updates).
    default_orders = {
        reader = nil,
        filemanager = nil,
    },
    -- Session-scoped move records used by open editors to heal stale rows.
    recent_moves = {
        reader = {},
        filemanager = {},
    },
}

local function getDefaultOrder(view)
    local injected = MenuOrderManager.default_orders[view]
    if injected then return util.tableDeepCopy(injected) end
    return KoreaderAdapter.getDefaultOrder(view)
end

-- Identity of the effective defaults: injected stock is fingerprinted by
-- CONTENT (an in-place mutation is a simulated update too — reference
-- comparison silently ignored those), stock defaults by the adapter's load
-- revision, so a simulated update transparently rebuilds the ephemeral
-- registry. Fingerprinting a few dozen menu rows per session touch is cheap
-- next to a resolve.
local function defaultsIdentity(view)
    local injected = MenuOrderManager.default_orders[view]
    if injected ~= nil then
        local ok_fp, fp = pcall(NativeWriter.fingerprint, injected)
        if ok_fp and type(fp) == "string" then return "injected:" .. fp end
        return injected
    end
    return KoreaderAdapter.getDefaultsRevision(view)
end

local sessions = {}            -- [view] = { reg = registry, graph, order }
local active_txn               -- long-lived IntentTransaction (staged intent)
local synced_views = {}        -- [view] = true after three-way startup sync
local last_sync_result = {}    -- [view] = last structured sync result (observability)
local live_registrations = {}  -- [view] = { items, providers } last collected
local backups = {}             -- [view] = staged section snapshot
local in_commit = false        -- reentrancy guard for CommitPipeline
local registry_dirty = {}      -- registry-only changes needing new emission

-- Exception-safe boundary around THE save funnel. CommitPipeline normally
-- contains operation failures in its structured Outcome, but this guard also
-- covers programming errors and test/future adapters that raise before an
-- Outcome exists. The previous guard state is restored on every path.
local function commitWithGuard(txn, options)
    options = options or {}
    options.force_views = util.tableDeepCopy(registry_dirty)
    local previous = in_commit
    in_commit = true
    local ok, outcome = xpcall(function()
        return CommitPipeline.commitAndApply(txn, options)
    end, function(err)
        return tostring(err)
    end)
    in_commit = previous
    if not ok then
        logger.err("ReorderingMenus: commit pipeline raised:", outcome)
        return CommitPipeline.failureOutcome(outcome)
    end
    if type(outcome) ~= "table" or outcome.status == nil
            or type(outcome.failed_views) ~= "table"
            or type(outcome.changed_views) ~= "table" then
        logger.err("ReorderingMenus: commit pipeline returned an invalid outcome")
        return CommitPipeline.failureOutcome("invalid commit outcome")
    end
    if outcome.committed then
        for view in pairs(registry_dirty) do
            if outcome.changed_views[view] and not outcome.failed_views[view] then
                registry_dirty[view] = nil
            end
        end
    end
    return outcome
end

-- Drop derived caches for a view. There is deliberately NO healing-history
-- snapshot here: the projection is a pure function of (registry, canonical
-- intent), so a cache rebuild can never change semantic output - resets,
-- presets, and reloads need no special history handling.
local function invalidate(view)
    local s = sessions[view]
    if s then
        s.graph = nil
        s.order = nil
        s.effective = nil
    end
    MenuOrderManager.orders[view] = nil
end

local function ensureTxn()
    -- A committed transaction's staged table ALIASES state.views (commit
    -- swaps them). Reusing it would let later edits silently mutate the
    -- canonical in-memory state without any durable write - so a committed
    -- transaction is spent and must be replaced. The same applies to a
    -- FAILED commit: its rollback swapped state.views back, but staged still
    -- aliases the rolled-back table; reusing it would re-apply discarded
    -- records on the next commit and make rollback meaningless.
    --
    -- A transaction staged BEFORE a wholesale canonical reload (load(true)
    -- absorbing an external rollback of the intent file, replaceState,
    -- resetView) describes that superseded world: commit() refuses it via
    -- the store-epoch guard. Reuse here would also serve PROJECTIONS from
    -- its stale staged section (getGraph resolves through ensureTxn), so
    -- the first post-rollback session would show pre-rollback menus fused
    -- with restored canonical intent and only converge after a second
    -- restart. Discard it instead; staging starts over from the reloaded
    -- canonical state - exactly what a real process restart would do.
    if active_txn and active_txn.store_epoch ~= nil
            and active_txn.store_epoch ~= IntentStore.storeEpoch() then
        active_txn:discard()
        active_txn = nil
    end
    if not active_txn or not active_txn:isOpen() then
        active_txn = IntentStore.openTransaction()
    end
    return active_txn
end

-- Resetting or reloading one view must not throw away unsaved work staged for
-- the other view.  The manager intentionally uses one transaction so mirrored
-- edits can commit together; preserve the unaffected section across a
-- view-local discard and rebase it onto the latest canonical snapshot.
local function discardViewStaging(view)
    if active_txn and active_txn.store_epoch ~= nil
            and active_txn.store_epoch ~= IntentStore.storeEpoch() then
        -- Staged from a superseded in-memory world (see ensureTxn): there is
        -- nothing meaningful to preserve across the reload.
        active_txn:discard()
        active_txn = nil
        return
    end
    if not active_txn or not active_txn:isOpen() then
        active_txn = nil
        return
    end
    local preserved = {}
    for _, other_view in ipairs(MenuSchema.VIEWS) do
        if other_view ~= view then
            preserved[other_view] = {
                section = active_txn:mergeSection(other_view),
            }
        end
    end
    active_txn:discard()
    active_txn = nil
    if next(preserved) then
        local fresh = ensureTxn()
        for other_view, snapshot in pairs(preserved) do
            fresh:setViewSection(other_view, snapshot.section)
        end
    end
end

-- -------------------------------------------------------------------------
-- Session management
-- -------------------------------------------------------------------------

local function buildRegistry(view, ui)
    local registrations, providers, collisions
    local injected = live_registrations[view]
    -- An injected table is authoritative even when EMPTY: an empty set
    -- means "no plugins installed right now", not "go scan the real
    -- system" (a live scan would pick up unrelated plugins registered in
    -- shared settings and resurrect ghost rows).
    if injected then
        registrations = injected.items
        providers = injected.providers
        collisions = injected.collisions
    else
        registrations, providers, collisions =
            KoreaderAdapter.collectLiveRegistrations(ui)
    end
    local defaults
    local default_providers
    if MenuOrderManager.default_orders[view] then
        -- TEST-ONLY injection with production shape: injected stock flows
        -- through the same adoption pipeline as shipped stock (live tabs and
        -- menu trees filtered by live registrations, third-party insertions
        -- at live slots, per-row provider stamps) instead of being used raw.
        -- Injected tabs/menus are structural stock (always kept); only
        -- genuinely live extras adopt on top, so injected fixtures stay
        -- hermetic against the real live module table. Own-emission echo
        -- exclusion does not apply here (see refreshLivePluginOrder): test
        -- baselines are replaced wholesale per assignment, never overlaid.
        local live_mod = package.loaded[string.format(
            "ui/elements/%s_menu_order", view)]
        defaults, default_providers =
            KoreaderAdapter.captureNativeSnapshot(
                MenuOrderManager.default_orders[view], live_mod,
                registrations, providers)
    else
        -- Our last emission per menu (checkpoint structure), so live_mod rows
        -- that merely echo it are not re-adopted as defaults (feedback would
        -- shift default_parent underneath intent and prune it on save).
        local own_rows
        do
            local ok_rec, record = pcall(NativeWriter.getRecord, view)
            local structure = ok_rec and type(record) == "table"
                and record.structure or nil
            if type(structure) == "table" then
                own_rows = {}
                for menu_id, list in pairs(structure) do
                    if type(list) == "table" then
                        local set = {}
                        for _, id in ipairs(list) do
                            if type(id) == "string" then set[id] = true end
                        end
                        own_rows[menu_id] = set
                    end
                end
            end
        end
        defaults = KoreaderAdapter.refreshLivePluginOrder(view,
            registrations, providers, own_rows)
        default_providers = KoreaderAdapter.getExternalDefaultProviders(view)
    end
    return Registry.buildFromData(defaults, registrations, providers, collisions,
        default_providers)
end

-- Startup synchronization boundary (Prompt 4 §1): exactly one import /
-- regenerate / revert decision per process per view, with a structured
-- result. Runs lazily on first session touch (sessionFor) so KOReader's own
-- startup needs no extra hook, and explicitly via Manager:startupSync (same
-- function — plugin init, tests, and diagnostics call it directly instead of
-- relying on the lazy trigger). After it reports synced, all reads are pure
-- (cached effective model, no I/O, no intent writes) until an explicit
-- external refresh (reloadFromDisk/refreshRegistry/dropSessionState),
-- commit (saveOrder/commitStaged), or projection refresh (invalidate).
--
-- Returns { changed=bool, mode=string, committed=bool|nil, error=string|nil,
-- failed_views={...} }. changed=false means the native file already matches
-- our last emission (or was converged without new user data); changed=true
-- with committed=true means an external edit/revert was imported AND
-- durably committed through the normal funnel (exactly ONE canonical commit
-- + ONE derived emission — never a sidecar guess).
local function startupSyncView(view)
    ensureTxn()
    local changed, mode = NativeWriter.syncView(view, sessions[view].reg, active_txn)
    local result = { changed = changed, mode = mode,
        committed = nil, error = nil, failed_views = {} }
    if mode == "regeneration_failed" or mode == "remove_failed"
            or mode == "record_clear_failed" then
        synced_views[view] = nil
        result.error = mode
        logger.err("ReorderingMenus: startup synchronization failed for",
            view, "(" .. mode .. ")")
        return result
    end
    if changed then
        logger.info(string.format(
            "ReorderingMenus: synchronized %s configuration for %s",
            tostring(mode), view))
        invalidate(view)
        -- The import is durable user data discovered at startup. Commit it
        -- immediately: leaving it staged in the shared active transaction
        -- loses the external edit if the session ends without an unrelated
        -- save (or if another writer's stale commit refuses first).
        --
        -- P0-2/P0-3: exactly ONE canonical commit, then ONE derived
        -- emission through the same funnel as every other save. The old
        -- flow ran adoptObservedNative() first - a sidecar write that
        -- GUESSED intent_gen = generation()+1 for a commit that had not
        -- happened yet - and then wrote the sidecar AGAIN inside
        -- writeView. Now the sidecar is written once, bound to the
        -- generation that actually persisted; a crash before the derived
        -- write leaves the lagging (intent_gen mismatch) pair, which the
        -- next startup regenerates from canonical intent alone.
        if active_txn and active_txn:isOpen() then
            local outcome = commitWithGuard(active_txn,
                { get_session = function(v)
                    return v == view and sessions[v] or nil end,
                  prepare = minimizeIntent })
            result.failed_views = outcome.failed_views or {}
            if not outcome.committed then
                synced_views[view] = nil
                active_txn:discard()
                active_txn = nil
                result.error = outcome.error
                logger.err("ReorderingMenus: failed persisting startup",
                    "synchronization for", view, outcome.error)
            else
                result.committed = true
                ensureTxn() -- fresh staging for UI edits
                for failed_view, write_err in pairs(outcome.failed_views) do
                    synced_views[failed_view] = nil
                    logger.err("ReorderingMenus: imported intent was",
                        "saved, but its derived checkpoint failed for",
                        failed_view, write_err)
                end
            end
        end
    end
    return result
end

local function sessionFor(view, ui)
    local s = sessions[view]
    if not s then
        s = { reg = buildRegistry(view, ui), defaults_identity = defaultsIdentity(view) }
        sessions[view] = s
    end
    if not s.reg then
        s.reg = buildRegistry(view, ui)
    end
    -- Rebuild the ephemeral registry whenever the effective defaults change
    -- (KOReader update, or a test injecting a new defaults table).
    if s.defaults_identity ~= nil and s.defaults_identity ~= defaultsIdentity(view) then
        s.reg = buildRegistry(view, ui)
        s.defaults_identity = defaultsIdentity(view)
        registry_dirty[view] = true
        synced_views[view] = nil
        last_sync_result[view] = nil
        -- No healing history to drop: the projection is derived from the
        -- NEW registry + unchanged canonical intent, exactly as a fresh
        -- process would.
        invalidate(view)
        sessions[view] = s
    end
    if not synced_views[view] and not in_commit then
        synced_views[view] = true
        last_sync_result[view] = startupSyncView(view)
    end
    return s
end

-- Explicit startup-synchronization entry point (Prompt 4 §1): same boundary
-- the lazy session trigger uses. Returns the structured sync result; when
-- already synced, returns the stored result of the sync that ran (pure —
-- no re-classification, no writes).
function MenuOrderManager:startupSync(view)
    local s = sessionFor(view)
    if synced_views[view] then
        local last = last_sync_result[view]
        if type(last) == "table" then return last end
        return { changed = false, mode = "already_synced",
            committed = nil, error = nil, failed_views = {} }
    end
    synced_views[view] = true
    last_sync_result[view] = startupSyncView(view)
    return last_sync_result[view]
end

-- Query: has the one-time startup synchronization completed for this view?
-- Pure (never triggers the sync itself); session touches still run the lazy
-- boundary on first access by design.
function MenuOrderManager:isSynced(view)
    return synced_views[view] == true
end

function MenuOrderManager:refreshRegistry(view, ui)
    local s = sessionFor(view, ui)
    local refreshed = buildRegistry(view, ui)
    if not util.tableEquals(s.reg, refreshed) then
        registry_dirty[view] = true
        synced_views[view] = nil
        last_sync_result[view] = nil
    end
    s.reg = refreshed
    s.defaults_identity = defaultsIdentity(view)
    invalidate(view)
    return true
end

-- Called by the UI layer with freshly collected live menu contributions so
function MenuOrderManager:setLiveRegistrations(view, menu_items, providers, collisions)
    live_registrations[view] = {
        items = menu_items,
        providers = providers,
        collisions = collisions,
    }
end

-- -------------------------------------------------------------------------
-- Materialization / projection
-- -------------------------------------------------------------------------

local function getGraph(view)
    local s = sessionFor(view)
    if not s.graph then
        local txn = ensureTxn()
        -- Single effective source (Prompt 3 Part B): every projection is
        -- Resolver.resolve(registry, draft_or_saved intent). History-
        -- independence (P0) holds by construction: pure function of current
        -- inputs, no previous projection or sidecar seeding.
        local Resolver = require("lib.resolver")
        local effective = Resolver.resolve(s.reg, txn:view(view))
        s.graph = {
            tabs = effective.tabs,
            lists = effective.lists,
            disabled = effective.disabled,
            custom_titles = effective.custom_titles,
            unplaced = effective.unplaced,
        }
        -- Cache the full effective model alongside for visibility/diagnostics
        -- without re-deriving (single source, not separate truths).
        s.effective = effective
    end
    return s.graph
end

-- Full effective model (Prompt 3): ordered lists + owner/indexes + visibility
-- reasons + diagnostics, resolved once. Editors, native projection,
-- visibility explanations, and validation diagnostics share this (not
-- separate placement/materializer/validator/visibility reconstructions).
local function getEffective(view)
    local s = sessionFor(view)
    if not s.effective then
        getGraph(view)
    end
    return s.effective
end

local function getOrderTable(view)
    local s = sessionFor(view)
    if not s.order then
        local graph = getGraph(view)
        local order = {}
        order[MENU_BUTTONS_KEY] = graph.tabs
        order[DISABLED_KEY] = graph.disabled
        if next(graph.custom_titles) then
            order[CUSTOM_SUBMENUS_KEY] =
                util.tableDeepCopy(graph.custom_titles)
        end
        for menu_id, list in pairs(graph.lists) do
            order[menu_id] = list
        end
        s.order = order
        MenuOrderManager.orders[view] = order
    end
    return s.order
end

function MenuOrderManager:getDefaultOrder(view)
    return getDefaultOrder(view)
end

function MenuOrderManager:loadOrder(view, force_reload)
    if force_reload then invalidate(view) end
    return util.tableDeepCopy(getOrderTable(view))
end

function MenuOrderManager:isCustomized(view)
    -- Customized == applicable canonical USER intent exists. Deliberately
    -- NOT derived from the native file, the sidecar, or any cache: a stale
    -- derived file, a missing native module, or an unregenerated checkpoint
    -- says nothing about what the user asked for. The predicate is typed in
    -- MenuSchema (lifecycle pins excluded), so registration-time
    -- reconciliation can never make a stock menu look customized.
    return MenuSchema.sectionHasUserIntent(ensureTxn():view(view))
end

-- Read-only access to the CURRENT (staged) intent section for a view.
-- Editors and verbs mutate a transaction that only becomes canonical on
-- commit; diagnostics and tests must inspect the same state the
-- projection is derived from, not the last committed one.
function MenuOrderManager:stagedView(view)
    local txn = ensureTxn()
    return txn:view(view)
end

-- -------------------------------------------------------------------------
-- Commit pipeline: minimize -> validate -> sparse write -> persist intent
-- -------------------------------------------------------------------------

-- Sparse bookkeeping: a record that provably does not change the derived
-- graph carries no information and is dropped before persisting.
local function minimizeIntent(view, txn, reg)
    local section = txn:view(view)
    if not section then return end

    local has_parents = section.parent_override and next(section.parent_override) ~= nil
    local has_pos = section.position_override and next(section.position_override) ~= nil
    local has_orders = section.order_override and next(section.order_override) ~= nil
    local has_seps = section.separators and next(section.separators) ~= nil

    if not (has_parents or has_pos or has_orders or has_seps) then
        return
    end

    local function dormantReason(id, record)
        local node = reg.nodes and reg.nodes[id] or nil
        local live = node and node.provider or nil
        return live ~= record.provider
    end

    -- 1. Local pruning for parent_override
    if has_parents then
        for id, record in pairs(section.parent_override) do
            if type(record) == "table" and record.provider ~= nil and dormantReason(id, record) then
                -- Dormant intent: keep
            else
                local target = type(record) == "table" and record.parent or record
                local default_p = Registry.getDefaultParent(reg, id)
                if target == default_p and (type(record) ~= "table" or record.provider == nil or record.provider == Registry.getProvider(reg, id)) then
                    section.parent_override[id] = nil
                end
            end
        end
    end

    -- 2. Local pruning for position_override
    -- A destination order_override never invalidates a position anchor by
    -- itself: anchors for ids omitted from that sequence are the supported
    -- insertion mechanism into an already-reordered level (preview = saved =
    -- restarted). Only provably default-redundant anchors are dropped.
    if has_pos then
        for id, record in pairs(section.position_override) do
            if type(record) == "table" and record.provider ~= nil and dormantReason(id, record) then
                -- Dormant intent: keep
            else
                local target_parent = Materializer.effectiveParent(reg, section, id)
                do
                    local menu_def = reg.menus and reg.menus[target_parent]
                    local def_list = menu_def and menu_def.list
                    if def_list and #def_list > 0 then
                        local anchor = type(record) == "table" and record.after
                        local idx = nil
                        for i, mid in ipairs(def_list) do
                            if mid == id then idx = i break end
                        end
                        if idx then
                            local natural_anchor = idx > 1 and def_list[idx - 1] or false
                            if anchor == natural_anchor then
                                section.position_override[id] = nil
                            end
                        end
                    end
                end
            end
        end
    end

    -- 3. Local pruning for order_override
    -- Durable ordering survives hiding: a sequence whose every entry is
    -- currently hidden still governs the restored order on unhide, so the
    -- all-hidden shape is never pruned here (only default-equality is).
    if has_orders then
        for menu_id, override in pairs(section.order_override) do
            local def_menu = reg.menus and reg.menus[menu_id]
            if type(override) == "table" and type(override.entries) == "table" then
                local seq = {}
                for _, ent in ipairs(override.entries) do
                    if MenuSchema.isSeparatorEntry(ent) then
                        seq[#seq + 1] = MenuSchema.SEPARATOR_ID
                    else
                        seq[#seq + 1] = ent.id
                    end
                end
                local default_items = {}
                for _, id in ipairs(def_menu and def_menu.list or {}) do
                    if id ~= MenuSchema.SEPARATOR_ID then
                        default_items[#default_items + 1] = id
                    end
                end
                if def_menu and def_menu.list
                            and Materializer.listEquals(seq, default_items) then
                    section.order_override[menu_id] = nil
                end
            end
        end
    end

    -- If any manual ordering remains, check if full group is redundant with baseline.
    -- The visible-graph comparison cannot prove future equivalence while any
    -- ordering record is currently inapplicable-but-durable (hidden member or
    -- provider-dormant stamp): unhide / provider return would diverge. Skip
    -- the whole-group prune in that case rather than deleting revivable intent.
    if (section.order_override and next(section.order_override) ~= nil)
            or (section.position_override and next(section.position_override) ~= nil)
            or (section.separators and next(section.separators) ~= nil) then
        local has_hidden = section.hidden and next(section.hidden) ~= nil
        local has_future_intent = has_hidden and true or false
        if not has_future_intent then
            for _, override in pairs(section.order_override or {}) do
                if type(override) == "table" and type(override.entries) == "table" then
                    for _, entry in ipairs(override.entries) do
                        if not MenuSchema.isSeparatorEntry(entry) then
                            local eid = entry.id
                            if section.hidden and section.hidden[eid] then
                                has_future_intent = true break
                            end
                            local stamp = type(entry) == "table" and entry.provider or nil
                            if stamp ~= nil then
                                local live = reg.nodes and reg.nodes[eid]
                                    and reg.nodes[eid].provider or nil
                                if live ~= stamp then
                                    has_future_intent = true break
                                end
                            elseif reg.nodes and reg.nodes[eid] == nil then
                                -- Unstamped unknown id: dormant-capable reference
                                -- that a later provider registration applies.
                                -- Its ordering must survive unrelated saves.
                                has_future_intent = true break
                            end
                        end
                    end
                    if has_future_intent then break end
                end
            end
        end
        if not has_future_intent then
            for pid, prec in pairs(section.position_override or {}) do
                if section.hidden and section.hidden[pid] then
                    has_future_intent = true break
                end
                if type(prec) == "table" and prec.provider ~= nil then
                    local live = reg.nodes and reg.nodes[pid]
                        and reg.nodes[pid].provider or nil
                    if live ~= prec.provider then
                        has_future_intent = true break
                    end
                end
            end
        end
        if has_future_intent then
            return
        end
        -- Proven-no-op check on projections (HEAD semantics preserved green:
        -- unresolved Materializer graphs, not repaired effective models.
        -- Rationale: minimization compares what ordering intent ALONE
        -- contributes (placement/ordering/dividers), before validator repairs
        -- (duplicate ownership, cycles, cascades, protected, empty-bar) which
        -- are render-safety concerns, not ordering-intent concerns. Comparing
        -- effective (repaired) graphs here made no-op saves look dirty when
        -- repairs apply (N3 generation churn) and dropped hint-home restores
        -- (R) by conflating repair with intent. Resolver remains the single
        -- source for DISPLAY/effective/visibility/diagnostics; minimization
        -- stays a pure intent-level proven-no-op gate.
        local current_graph = Materializer.resolve(reg, section)
        local without_manual = util.tableDeepCopy(section)
        without_manual.order_override = {}
        without_manual.separators = {}
        without_manual.position_override = {}
        local baseline_graph = Materializer.resolve(reg, without_manual)
        local identical = true
        for menu_id in pairs(current_graph.lists) do
            if not Materializer.listEquals(current_graph.lists[menu_id], baseline_graph.lists[menu_id]) then
                identical = false
                break
            end
        end
        if identical then
            for menu_id in pairs(baseline_graph.lists) do
                if not Materializer.listEquals(current_graph.lists[menu_id], baseline_graph.lists[menu_id]) then
                    identical = false
                    break
                end
            end
        end
        if identical then
            section.order_override = {}
            section.separators = {}
            section.position_override = {}
        end
    end
end

-- Save (truthful contract): validates + commits the shared draft through
-- the funnel (minimize -> ONE canonical commit -> derived native files +
-- checkpoint), then reports whether the change is fully applied, needs
-- regeneration, or requires a restart (see CommitPipeline.STATUS). What the
-- user previewed is what commits: staging and projection share the draft.
-- On failure NOTHING durable is half-written and the draft is restaged into
-- a fresh transaction below, so the work stays recoverable in-session.
-- Preferences independent of layout (mirroring toggle with no open txn,
-- hidden-row presentation) persist outside this path and never ride along.
function MenuOrderManager:saveOrder(view)
    sessionFor(view)

    local txn = ensureTxn()
    -- Common immediate no-op: no staged semantic/meta change and no derived
    -- checkpoint needs materialization. sessionFor(view) above has already
    -- reconciled supported external edits for the requested view. Avoid
    -- running minimization and commit-time
    -- graph work merely to rediscover that nothing happened.
    local staged_changed = txn:changedViews()
    local fast_noop = not IntentStore.isProtected()
        and not txn:hasMetaChanges()
        and not next(registry_dirty)
        and not staged_changed.reader and not staged_changed.filemanager
    if fast_noop then
        for _, v in ipairs(MenuSchema.VIEWS) do
            if NativeWriter.recordNeedsMaterialization(v) then
                fast_noop = false
                break
            end
        end
    end
    local outcome
    if fast_noop then
        -- Spend the transaction just like the full funnel does. changedViews
        -- and hasMetaChanges proved this is an in-memory identity swap, so
        -- Transaction:commit performs no durable write. If its concurrency
        -- generation is stale, fall through to the normal one-rebase path.
        local closed = txn:commit(false)
        if closed then
            outcome = CommitPipeline.unchangedOutcome()
            outcome.committed = true
        end
    end
    if not outcome then
        outcome = commitWithGuard(txn, {
        get_session = function(v) return sessionFor(v) end,
        prepare = minimizeIntent,
        invalidate = invalidate,
        })
    end
    ensureTxn() -- committed transaction is spent; fresh staging either way

    outcome.path = KoreaderAdapter.getNativePath(view)

    if not outcome.committed then
        logger.err("ReorderingMenus: failed to persist intent:", outcome.error)
        local spent_staged = txn and txn.staged
        local fresh = IntentStore.openTransaction()
        if type(spent_staged) == "table" then
            for _, v in ipairs(MenuSchema.VIEWS) do
                if type(spent_staged[v]) == "table" then
                    fresh:setViewSection(v, util.tableDeepCopy(spent_staged[v]))
                end
            end
        end
        active_txn = fresh
        for _, v in ipairs(MenuSchema.VIEWS) do
            invalidate(v)
        end
        return false, outcome.error or outcome.path, outcome
    end

    for failed_view, write_err in pairs(outcome.failed_views) do
        logger.err("ReorderingMenus: intent was saved, but the derived menu",
            "file for", failed_view, "could not be written:", write_err)
        synced_views[failed_view] = nil
    end
    for _, v in ipairs(MenuSchema.VIEWS) do
        if outcome.changed_views[v] and not outcome.failed_views[v] then
            invalidate(v)
            local record = NativeWriter.getRecord(v)
            backups[v] = nil
            logger.info("ReorderingMenus: materialized", v, "configuration;",
                (record and record.structure) and "sparse overrides written"
                    or "stock layout restored")
        end
    end

    local is_ok = outcome.status ~= CommitPipeline.STATUS.NOT_SAVED
        and outcome.status ~= CommitPipeline.STATUS.NEEDS_REGENERATION
    local second_arg = is_ok and (outcome.path or outcome.error) or (outcome.error or outcome.path)
    return is_ok, second_arg, outcome
end

--- P0-4/P0-10: commit whatever is staged (both views) through the funnel,
--- without naming a view. Used by semantic multi-view operations (plugin-
--- removal preparation) that stage first and persist once.
function MenuOrderManager:commitStaged()
    local outcome = commitWithGuard(ensureTxn(), {
        get_session = function(v) return sessionFor(v) end,
        prepare = minimizeIntent,
        invalidate = invalidate,
    })
    ensureTxn()
    if outcome.committed then
        for _, v in ipairs(MenuSchema.VIEWS) do
            if outcome.changed_views[v] and not outcome.failed_views[v] then
                invalidate(v)
                backups[v] = nil
            end
        end
    end
    return outcome
end

function MenuOrderManager:resetOrder(view)
    local txn = ensureTxn()
    txn:resetView(view)
    -- Commit the emptied intent FIRST (source of truth); the funnel then
    -- removes the derived file + clears the checkpoint as part of
    -- materializing this view's emptied section. The historical order
    -- (remove, then commit) crashed into a window where both files were gone
    -- but canonical intent still held every customization: a restart would
    -- resurrect it out of nowhere.
    local outcome = commitWithGuard(txn, {
        get_session = function(v) return sessionFor(v) end,
        invalidate = invalidate,
    })
    ensureTxn() -- spent transaction replaced by fresh staging

    if not outcome.committed then
        logger.err("ReorderingMenus: failed to persist reset:", outcome.error)
        return false, outcome.error, outcome
    end
    if outcome.failed_views[view] then
        logger.err("ReorderingMenus: reset intent was saved, but the derived",
            "menu file could not be removed:", outcome.failed_views[view])
        return false, outcome.failed_views[view], outcome
    end
    KoreaderAdapter.invalidateNativeModuleCache()
    -- Reset erases canonical intent; the next projection derives from the
    -- emptied state alone. No cached history to drop.
    invalidate(view)
    MenuOrderManager.recent_moves[view] = {}
    backups[view] = nil
    return true, nil, outcome
end

--- P0-9: Reset All as ONE semantic operation. Both views' intents are
--- emptied inside ONE transaction and committed ONCE - canonical state can
--- never represent "Reader reset but FileManager not reset". Derived output
--- may still fail per view; that is reported truthfully per view while the
--- canonical layer stays atomic. Returns ok(bool), err|nil, Outcome.
function MenuOrderManager:resetAllOrders()
    local txn = ensureTxn()
    for _, view in ipairs(MenuSchema.VIEWS) do
        txn:resetView(view)
    end
    local outcome = commitWithGuard(txn, {
        get_session = function(v) return sessionFor(v) end,
        invalidate = invalidate,
    })
    ensureTxn()

    if not outcome.committed then
        logger.err("ReorderingMenus: failed to persist Reset All:", outcome.error)
        return false, outcome.error, outcome
    end
    for failed_view, write_err in pairs(outcome.failed_views) do
        logger.err("ReorderingMenus: Reset All was saved canonically, but",
            "the derived cleanup failed for", failed_view, ":", write_err)
    end
    KoreaderAdapter.invalidateNativeModuleCache()
    for _, view in ipairs(MenuSchema.VIEWS) do
        invalidate(view)
        MenuOrderManager.recent_moves[view] = {}
        backups[view] = nil
    end
    if next(outcome.failed_views) then
        for failed_view in pairs(outcome.failed_views) do
            synced_views[failed_view] = nil
        end
        return false, CommitPipeline.STATUS.NEEDS_REGENERATION, outcome
    end
    return true, nil, outcome
end

function MenuOrderManager:reloadFromDisk(view)
    discardViewStaging(view)
    -- The native file may have changed externally while we were not looking;
    -- force a fresh three-way comparison against the last materialization.
    synced_views[view] = nil
    last_sync_result[view] = nil
    invalidate(view)
    return true
end

-- Drop every cached session artefact for a view (registry, projection,
-- staged transaction, sync marker). Phase-boundary helper for tests that
-- mutate the underlying environment underneath the running manager.
function MenuOrderManager:dropSessionState(view)
    discardViewStaging(view)
    sessions[view] = nil
    synced_views[view] = nil
    last_sync_result[view] = nil
    live_registrations[view] = nil
    registry_dirty[view] = nil
    backups[view] = nil
    invalidate(view)
    return true
end

-- Read-only view of the shared in-session transaction, for dirty gates.
-- Returns nil when nothing is staged (no txn, or a spent one): a gate must
-- never CREATE staging as a side effect of asking "is anything staged?", and
-- a spent transaction can never ride a later save (commit refuses it), so it
-- is not unsaved work. Mutating through this handle is refused by the store's
-- mutator gate; callers treat the result strictly as a snapshot signature.
function MenuOrderManager:peekTransaction()
    if active_txn and active_txn:isOpen() then
        return active_txn
    end
    return nil
end

-- -------------------------------------------------------------------------
-- Single draft ownership (Prompt 3 Part A).
-- -------------------------------------------------------------------------
-- One editing session owns: base_revision (canonical generation + store epoch
-- at staging time), one draft_intent (active_txn staged sections for both
-- views), minimal lifecycle (open/dirty/conflicted). Widgets own only
-- interaction state (selection/scroll/drag/search/filter); authoritative
-- layout truth lives here, observed by nested and top-level editors alike
-- (single active_txn). Cross-menu moves stage into the shared draft
-- immediately (moveItemToMenu); save validates+commits, discard drops,
-- failure leaves the draft recoverable (saveOrder restages spent work).
-- Provider refresh (refreshRegistry) marks registry_dirty for re-emission
-- without rewriting the draft (applicability, not persistence).
--
-- Backups (backupOrder/restoreOrder) are per-editor Cancel snapshots (copies
-- of draft sections), not separate layout truths. recent_moves are
-- stale-widget healing hints (interaction state), not authoritative
-- membership (draft parent_override is). Manager.orders is a deprecated
-- alias mirroring sessions order (invalidated together).
--
-- Returns { base_generation, store_epoch, generation, view_generations } or
-- nil when no draft is open (no txn). Never creates staging as a side effect.
function MenuOrderManager:draftBaseRevision()
    local txn = self:peekTransaction()
    if not txn then return nil end
    return {
        base_generation = txn.base_generation,
        store_epoch = txn.store_epoch,
        generation = IntentStore.generation(),
        view_generations = {
            reader = IntentStore.generation("reader"),
            filemanager = IntentStore.generation("filemanager"),
        },
    }
end

-- Dirty: staged draft differs from canonical (per view or any). Pure read,
-- never creates staging.
function MenuOrderManager:draftDirty(view)
    local txn = self:peekTransaction()
    if not txn then return false end
    local ok, changed = pcall(function() return txn:changedViews() end)
    if not ok or type(changed) ~= "table" then return false end
    if view ~= nil then return changed[view] == true end
    return changed.reader == true or changed.filemanager == true
end

-- Conflicted: draft staged from a superseded world (wholesale reload swapped
-- canonical underneath: store_epoch mismatch) or another writer advanced
-- canonical generation past the draft base (optimistic-concurrency stale).
-- A conflicted draft cannot commit (commit refuses stale_transaction);
-- callers must rebase (discard + restage) like a restart would.
function MenuOrderManager:draftConflicted()
    local txn = self:peekTransaction()
    if not txn then return false end
    if txn.store_epoch ~= nil and txn.store_epoch ~= IntentStore.storeEpoch() then
        return true
    end
    if txn.base_generation ~= nil and txn.base_generation ~= IntentStore.generation() then
        return true
    end
    return false
end

-- Discard draft staging for one view (per-editor Cancel), preserving the
-- other view's staged work (rebase onto latest canonical). Thin wrapper over
-- the view-local discard; invalidates the view's effective model.
function MenuOrderManager:discardDraft(view)
    discardViewStaging(view)
    invalidate(view)
    return true
end

-- -------------------------------------------------------------------------
-- Queries over the projection
-- -------------------------------------------------------------------------

local function findParentInProjection(order, item_id)
    for menu_id, items in pairs(order or {}) do
        if menu_id ~= DISABLED_KEY and menu_id ~= CUSTOM_SUBMENUS_KEY
                and type(items) == "table" then
            for idx, id in ipairs(items) do
                if id == item_id then return menu_id, idx end
            end
        end
    end
end

function MenuOrderManager:getTabs(view)
    return util.tableDeepCopy(getOrderTable(view)[MENU_BUTTONS_KEY] or {})
end

function MenuOrderManager:getAllKnownTabs(view)
    local tabs, seen = {}, {}
    for _, t in ipairs(getOrderTable(view)[MENU_BUTTONS_KEY] or {}) do
        if not seen[t] then
            seen[t] = true
            table.insert(tabs, t)
        end
    end
    for _, t in ipairs(getDefaultOrder(view)[MENU_BUTTONS_KEY] or {}) do
        if not seen[t] then
            seen[t] = true
            table.insert(tabs, t)
        end
    end
    return tabs
end

function MenuOrderManager:getMenuItems(view, menu_id)
    local list = getOrderTable(view)[menu_id]
    if type(list) == "table" then
        return util.tableDeepCopy(list)
    end
    return {}
end

function MenuOrderManager:isSubmenu(view, id)
    local order = getOrderTable(view)
    return order[id] ~= nil and not NativeWriter.RESERVED[id]
end

function MenuOrderManager:getAllSubmenuIds(view)
    local order = getOrderTable(view)
    local submenus = {}
    for k, v in pairs(order) do
        if not NativeWriter.RESERVED[k] and type(v) == "table" then
            local is_tab = false
            for __, tab in ipairs(order[MENU_BUTTONS_KEY] or {}) do
                if tab == k then is_tab = true break end
            end
            if not is_tab then table.insert(submenus, k) end
        end
    end
    table.sort(submenus)
    return submenus
end

function MenuOrderManager:getAllMenusAndSubmenus(view)
    local order = getOrderTable(view)
    local list, seen = {}, {}
    for __, tab in ipairs(order[MENU_BUTTONS_KEY] or {}) do
        if not seen[tab] then
            seen[tab] = true
            table.insert(list, { id = tab, is_tab = true })
        end
    end
    for k, v in pairs(order) do
        if not NativeWriter.RESERVED[k] and type(v) == "table" and not seen[k] then
            seen[k] = true
            table.insert(list, { id = k, is_tab = false })
        end
    end
    return list
end

function MenuOrderManager:getParentMenu(view, item_id)
    local parent, idx = findParentInProjection(getOrderTable(view), item_id)
    if parent then return parent, idx end
    -- Hidden items report no configured parent: "where is it?" is answered
    -- by getHiddenItemParent, and a truthy parent here would make callers
    -- treat an invisible row as placed.
    local txn = ensureTxn()
    if txn:getHidden(view, item_id) then return nil end
    -- The row may be invisible because its CONTAINER cascaded (a hidden tab
    -- drags its whole subtree into KOMenu:disabled). That is a projection
    -- limitation, not the item's placement: fall back to the intent-resolved
    -- parent so queries stay truthful about where the user put it.
    local s = sessionFor(view)
    if s then
        return Materializer.effectiveParent(s.reg, txn:view(view), item_id)
    end
    return nil
end

function MenuOrderManager:isItemHidden(view, item_id)
    local txn = ensureTxn()
    local section = txn:view(view)
    return Materializer.hiddenApplies(sessionFor(view).reg, section, item_id)
end

--- Explicit vs inherited visibility (single authority for the UI).
--- Returns { state, ancestor?, path?, ... } where state is one of
--- visibility.STATES: visible | explicitly_hidden | hidden_by_ancestor |
--- unplaced | provider_absent. Never raises: unknown ids report
--- provider_absent/unplaced rather than erroring.
function MenuOrderManager:getVisibilityStatus(view, item_id)
    -- Single source (Prompt 3 Part D): visibility reasons come from the
    -- resolver's effective model, never reconstructed downstream. The queried
    -- id is forced into the visibility map so cross-view absent ids (no
    -- references in this view) correctly report provider_absent rather than
    -- falling back to unplaced.
    local s = sessionFor(view)
    local txn = ensureTxn()
    local ok, eff = pcall(function()
        local Resolver = require("lib.resolver")
        return Resolver.resolve(s.reg, txn:view(view), { include_ids = { item_id } })
    end)
    if ok and type(eff) == "table" then
        local Resolver = require("lib.resolver")
        local st = Resolver.visibilityOf(eff, item_id)
        if type(st) == "table" and st.state then return st end
    end
    return { state = Visibility.STATES.UNPLACED, id = item_id }
end

-- Effective-model accessor for editors/diagnostics (Prompt 3): ordered
-- lists + owner/indexes + visibility + diagnostics, resolved once per
-- (registry, draft) pair. Prefer this over separate getGraph/getOrderTable
-- + ad-hoc Visibility.status reconstructions for new code.
function MenuOrderManager:getEffectiveModel(view)
    return getEffective(view)
end

--- Deliberate reveal-path for an item hidden by an ancestor: unhides ONLY
--- the ancestors on that item's path (nearest first), leaving unrelated
--- hidden content untouched. Returns true when something staged, false when
--- there was no hidden ancestor to reveal. Callers still commit via
--- saveOrder; this stages into the open transaction like any other verb.
function MenuOrderManager:revealHiddenPath(view, item_id)
    local st = self:getVisibilityStatus(view, item_id)
    if not st or st.state ~= Visibility.STATES.HIDDEN_BY_ANCESTOR then
        return false
    end
    local txn = ensureTxn()
    local staged_any = false
    -- Path is nearest-first ending at the bar; unhide every explicitly
    -- hidden ancestor on it. Deterministic order keeps intent bytes stable.
    local path = type(st.path) == "table" and st.path or {}
    local ordered = {}
    for _, anc in ipairs(path) do
        if anc ~= MENU_BUTTONS_KEY then ordered[#ordered + 1] = anc end
    end
    table.sort(ordered, function(a, b) return tostring(a) < tostring(b) end)
    for _, anc in ipairs(ordered) do
        if txn:getHidden(view, anc) ~= nil then
            txn:setHidden(view, anc, nil)
            staged_any = true
        end
    end
    -- The blocker itself may have been pruned as unreachable without an
    -- explicit record (stale intermediate container). Nothing more to clear
    -- there; the child's own explicit record is already gone (otherwise the
    -- status would be explicitly_hidden). Report staged work truthfully.
    if staged_any then invalidate(view) end
    return staged_any
end

function MenuOrderManager:getDisabledItems(view)
    return util.tableDeepCopy(getOrderTable(view)[DISABLED_KEY] or {})
end

--- Explicitly hidden ids only (applicable hidden records), excluding
--- cascade/unplaced/provider-absent rows that merely sit in disabled.
function MenuOrderManager:getExplicitHiddenIds(view)
    local txn = ensureTxn()
    local section = txn:view(view)
    local reg = sessionFor(view).reg
    local out = {}
    for id in pairs(section.hidden or {}) do
        if Materializer.hiddenApplies(reg, section, id) then
            out[#out + 1] = id
        end
    end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

function MenuOrderManager:getHiddenItemParent(view, item_id)
    local txn = ensureTxn()
    local record = txn:view(view).hidden[item_id]
    return type(record) == "table" and record.origin or nil
end

function MenuOrderManager:getRecentMoves(view)
    return util.tableDeepCopy(MenuOrderManager.recent_moves[view] or {})
end

function MenuOrderManager:isMenuDescendant(view, ancestor_menu_id, candidate_menu_id)
    if ancestor_menu_id == candidate_menu_id then return false end
    local order = getOrderTable(view)
    if not order[ancestor_menu_id] then return false end
    local visited = {}
    local function contains(menu_id)
        if visited[menu_id] then return false end
        visited[menu_id] = true
        for _, child_id in ipairs(order[menu_id] or {}) do
            if child_id == candidate_menu_id then return true end
            if type(order[child_id]) == "table" and contains(child_id) then
                return true
            end
        end
        return false
    end
    return contains(ancestor_menu_id)
end

function MenuOrderManager:canMoveItemToMenu(view, item_id, from_menu_id, to_menu_id)
    local order = getOrderTable(view)
    if item_id == SEPARATOR_ID then
        return false, _("Separators cannot be moved between menus.")
    end
    if not from_menu_id or type(order[from_menu_id]) ~= "table" then
        return false, _("The source menu is unavailable.")
    end
    if not to_menu_id or type(order[to_menu_id]) ~= "table" then
        return false, _("The destination menu is unavailable.")
    end
    if from_menu_id == to_menu_id then
        return false, _("The item is already in this menu.")
    end
    -- Centralized placement/capability gate (single authority with preset
    -- ingestion and resolve-time migration): top-level tabs cannot be nested
    -- inside ordinary submenus and non-tabs cannot occupy the tab bar.
    do
        local s = sessionFor(view)
        local txn = ensureTxn()
        local section = txn and txn:view(view) or nil
        local ok_place, reason = Placement.canPlace(s and s.reg, section, item_id, to_menu_id)
        if not ok_place then
            if reason == Placement.REASONS.TAB_NESTING then
                return false, _("Tabs stay in the tab bar and cannot be moved into a submenu. Move individual items instead.")
            elseif reason == Placement.REASONS.NON_TAB_IN_BAR then
                return false, _("Only tabs can live in the tab bar. Reorder tabs from the top-level editor.")
            elseif reason == Placement.REASONS.UNKNOWN_PARENT then
                return false, _("The destination menu is unavailable.")
            elseif reason == Placement.REASONS.SELF then
                return false, _("A submenu cannot be moved into itself.")
            else
                return false, _("This item cannot be moved to that menu.")
            end
        end
        -- The bar itself is not a regular menu list: tabs are reordered via
        -- reorderTabs, never via cross-menu moves. Reject tab-bar sources
        -- here so editor and preset paths agree (presets sanitize the same
        -- shape at ingest).
        if from_menu_id == MENU_BUTTONS_KEY or to_menu_id == MENU_BUTTONS_KEY then
            return false, _("Tabs stay in the tab bar and cannot be moved into a submenu. Move individual items instead.")
        end
    end

    local found_in_source = false
    for _, id in ipairs(order[from_menu_id]) do
        if id == item_id then
            found_in_source = true
            break
        end
    end
    if not found_in_source then
        -- Newly registered items may acquire their first configured parent,
        -- but a stale/wrong source is rejected when already configured.
        if self:getParentMenu(view, item_id) then
            return false, _("The item is no longer in the source menu.")
        end
    end

    if type(order[item_id]) == "table" then
        if to_menu_id == item_id then
            return false, _("A submenu cannot be moved into itself.")
        end
        if self:isMenuDescendant(view, item_id, to_menu_id) then
            return false, _("A submenu cannot be moved into one of its own submenus.")
        end
    end
    return true
end

-- -------------------------------------------------------------------------
-- Editor staging: translate a desired list into minimal intent operations
-- -------------------------------------------------------------------------
-- NOTE: divider key generation (sep_N) and the full replaceSeparatorIntent
-- below were deleted in the Prompt 2 unification: editor, import, and preset
-- dividers now share IntentOps.setDividerArrangement (replacement, unified
-- __sep_ keys, default-equality prune + zero sentinel). The local
-- separatorAnchors helper below is kept ONLY for the baseline-change check
-- (observed vs last emission); the canonical anchor computation lives in
-- IntentOps.separatorAnchorsOf.

local function collectStagedRows(staged_items)
    local sequence, separator_anchors = {}, {}
    local previous = false
    -- Editor rows are unique per parent by definition. A duplicated id in
    -- staged rows is stale-snapshot residue (e.g. the row was live when the
    -- snapshot listed it AND a reconciliation anchor re-added it): keep the
    -- FIRST occurrence - the position the user actually arranged - and drop
    -- later copies. Freezing a duplicate would persist an invariant-violating
    -- order_override that our own loader then quarantines as corrupt.
    local seen = {}
    for _, id in ipairs(staged_items or {}) do
        if id == SEPARATOR_ID then
            table.insert(separator_anchors, previous)
        elseif not seen[id] then
            seen[id] = true
            table.insert(sequence, id)
            previous = id
        end
    end
    return sequence, separator_anchors
end

local function separatorAnchors(list)
    -- Thin alias for the shared helper (kept for call-site stability;
    -- canonical implementation is IntentOps.separatorAnchorsOf).
    local IntentOps = require("lib.intent_ops")
    return IntentOps.separatorAnchorsOf(list)
end


local function reconcileMembership(view, menu_id, sequence, session, txn, section)
    local stale_rows = false
    for i = #sequence, 1, -1 do
        local id = sequence[i]
        local current_parent = Materializer.effectiveParent(session.reg, section, id)
        if current_parent ~= menu_id then
            if session.reg.nodes[id] == nil and not section.custom_menus[id] then
                -- (a) the CURRENT registry cannot account for this row at
                -- all: stale-snapshot residue; it drops out of the save.
                table.remove(sequence, i)
                stale_rows = true
                goto continue_row
            end
            local existing = section.parent_override[id]
            if type(existing) == "table" and MenuSchema.isLifecyclePin(existing) then
                -- A lifecycle pin is registration bookkeeping, not user
                -- placement: a STALE EDITOR save must never convert it into
                -- an explicit move record (D1b/D2). The pin keeps steering
                -- the row to its provider-derived home; the editor's old
                -- snapshot carries no authority over it.
                table.remove(sequence, i)
                stale_rows = true
                goto continue_row
            end
            if existing == nil and session.reg.nodes[id] ~= nil
                    and Materializer.effectiveParent(session.reg,
                        Materializer.emptyIntent(), id) ~= menu_id
                    and not section.custom_menus[menu_id] then
                -- (b/c) a row with NO user record whose provider/hint home
                -- resolves elsewhere follows that home instead of being
                -- converted into an explicit move back by an editor whose
                -- snapshot predates the move.
                --
    -- EXCEPTION: a CREATED SUBMENU is never anyone's default
    -- home (it starts empty and stock ids cannot resolve to
    -- it), so a row staged into one is there by deliberate user
    -- action only - record the placement instead of dropping it.
    -- Returns true when any staged row was dropped as stale residue, so
    -- callers know the snapshot is untrustworthy for divider authorship.
                table.remove(sequence, i)
                stale_rows = true
                goto continue_row
            end
            txn:setParentOverride(view, id, {
                provider = Registry.getProvider(session.reg, id),
                parent = menu_id,
            })
        else
            local record = section.parent_override[id]
            if record then
                local trial = util.tableDeepCopy(section)
                trial.parent_override[id] = nil
                if Materializer.effectiveParent(session.reg, trial, id) == menu_id then
                    txn:setParentOverride(view, id, nil)
                end
            end
        end
        ::continue_row::
    end
    return stale_rows
end

-- The single funnel through which editors persist a whole-menu arrangement.
-- Differences against the freshly materialized baseline become explicit
-- intent: parent overrides for relocated rows, one order override for the
-- sequence, separator records for user dividers. Everything matching the
-- current default behavior is dropped instead of stored.
function MenuOrderManager:stageList(view, menu_id, staged_items)
    local s = sessionFor(view)
    local txn = ensureTxn()
    local section = txn:view(view)
    local baseline = getGraph(view).lists[menu_id] or {}

    local seq, sep_anchors = collectStagedRows(staged_items)

    -- Membership: rows living somewhere else than this menu say so now.
    -- Stale-editor guards: (a) rows the CURRENT registry cannot account for
    -- at all are dropped - saving a stale view must never resurrect ids
    -- nothing serves; (b) an auto-anchored pin whose provider still serves
    -- the id but resolves elsewhere follows its provider's new home instead
    -- of being converted into an explicit move back; (c) a row with no user
    -- record whose default moved is likewise a stale snapshot and drops out.
    -- The return tells the divider gate below whether this snapshot is
    -- trustworthy for divider authorship (stale residue must never author).
    local stale_rows = reconcileMembership(view, menu_id, seq, s, txn, section)

    -- Ordering intent takes one of two deliberate, mutually exclusive forms
    -- (never a snapshot pretending to be both):
    --
    --   manual anchor  - a single relocated row is stored as
    --                    position_override[id] = { after = predecessor }, so
    --                    untouched neighbours keep following upstream changes
    --                    (a KOReader reorder of other rows still flows through)
    --   explicit bulk  - anything beyond that single relocation (A-Z sorts,
    --                    multi-item drags) stores the whole curated sequence
    --                    as an entries-carrying order_override, and later
    --                    arrivals merge around it
    --
    -- Writing one form clears the other for this level: the schema makes the
    -- exclusivity explicit instead of relying on precedence rules.
    local trial = util.tableDeepCopy(section)
    trial.order_override[menu_id] = nil
    -- Anchors on rows whose home is THIS menu are rewritten by this call
    -- (the single-relocation branch replaces them; the equality branch
    -- drops them). For branch selection the baseline must therefore be the
    -- DEFAULT derivation of this level, not the staged state carrying the
    -- previous anchor - otherwise an away-then-back drag would compare
    -- against the away pin and freeze a bulk sequence for a no-op.
    trial.position_override = {}
    -- Ordering baseline is the DEFAULT derivation (HEAD semantics preserved
    -- green): unresolved Materializer graph, not repaired effective model.
    -- Inference asks "what would this level look like with no manual ordering
    -- for it?" — a placement/ordering question, before render-safety repairs.
    -- Using effective (repaired) here made no-op saves freeze bulk when
    -- repairs apply (N3) by comparing displayed (repaired) rows against a
    -- repaired baseline that already reflects the manual move.
    local expected_full = Materializer.resolve(s.reg, trial).lists[menu_id]
    -- seq is separator-stripped (dividers travel as sep_anchors); the
    -- comparison baseline must be stripped identically, otherwise menus with
    -- stock dividers can never match the default derivation and every drag
    -- degrades into a whole-menu bulk freeze.
    local expected = {}
    if expected_full then
        for _, id in ipairs(expected_full) do
            if id ~= SEPARATOR_ID then table.insert(expected, id) end
        end
    end

    -- Shared ordering semantics (Prompt 2 §1-§2): ONE classification decides
    -- the staged form (anchor vs bulk vs noop vs pure-membership), independent
    -- of divider arrangement. Ordering and dividers are separate operations;
    -- a single item move across stock dividers stays an anchor (minimal) with
    -- dividers recorded separately below — dividers never force a bulk freeze.
    -- Same-menu anchor replacement (dropping earlier anchors for the final
    -- arrangement, while preserving inapplicable-but-durable ones per
    -- Prompt 2 §3) lives inside setOrderingFromSequence — the single owner
    -- of the ordering-ownership rule.
    do
        local IntentOps = require("lib.intent_ops")
        local res, res_err = IntentOps.setOrderingFromSequence(
            view, txn, s.reg, menu_id, expected, seq)
        if res == nil then
            logger.warn("ReorderingMenus: stageList refused for", view, "/",
                tostring(menu_id), "-", tostring(res_err and res_err.code or res_err))
            invalidate(view)
            return false
        end
    end

    -- Divider statements vs ordering statements (Prompt 2 §4): divider
    -- records are written ONLY when the staged list carries divider rows.
    -- Rationale: an items-only staged list (bulk A-Z sorts, reversals) says
    -- nothing about dividers — its missing dividers are stripped transport,
    -- not a removal (recording explicit-empty there would freeze every bulk
    -- sort divider-free and break era-tracking: Q6). Conversely an
    -- items-only list whose items match the current arrangement IS a divider
    -- statement about an empty arrangement (B7 explicit clear -> zero).
    -- Concretely:
    --   staged has divider rows + anchors differ from baseline -> record the
    --     complete observed arrangement (insert/remove/SEP-row drags; also
    --     item drags whose sep-inclusive indices shifted dividers as a side
    --     effect — recorded, matching import).
    --   staged divider-free + items match current AND default items ->
    --     explicit clear (B7 -> zero sentinel when stock had dividers). The
    --     default-equality half matters: re-freezing an identical bulk order
    --     via an items-only list must not wipe that menu's dividers as a
    --     side effect.
    --   staged divider-free otherwise -> ordering statement only; dividers
    --     stay env-governed (Q6 bulk reversal keeps tracking stock).
    -- Stale snapshots never author dividers: when membership reconciliation
    -- dropped rows as stale residue, divider anchors from that snapshot are
    -- untrustworthy and left untouched.
    -- (Import keeps recording both halves when a hand file changes both —
    -- a file has no verb channel, so dropping either half would destroy user
    -- bytes. Documented asymmetry, Prompt 2 §4.)
    local baseline_anchors = separatorAnchors(baseline)
    if #sep_anchors > 0 then
        if not stale_rows
                and not Materializer.listEquals(sep_anchors, baseline_anchors) then
            local IntentOps = require("lib.intent_ops")
            IntentOps.setDividerArrangement(view, txn, s.reg, menu_id, sep_anchors)
        end
    else
        local current_items = {}
        for _, id in ipairs(baseline) do
            if id ~= SEPARATOR_ID then current_items[#current_items + 1] = id end
        end
        local def_menu = s.reg.menus and s.reg.menus[menu_id]
        local default_items = {}
        for _, id in ipairs(def_menu and def_menu.list or {}) do
            if id ~= SEPARATOR_ID then default_items[#default_items + 1] = id end
        end
        if #baseline_anchors > 0
                and Materializer.listEquals(seq, current_items)
                and Materializer.listEquals(seq, default_items) then
            local IntentOps = require("lib.intent_ops")
            IntentOps.setDividerArrangement(view, txn, s.reg, menu_id, sep_anchors)
        end
    end

    invalidate(view)
    return true
end

-- -------------------------------------------------------------------------
-- Mutating verbs
-- -------------------------------------------------------------------------

local function providerStamp(reg, id)
    return Registry.getProvider(reg, id)
end

function MenuOrderManager:setItemHidden(view, item_id, is_hidden, current_menu_id, _mirrored)
    if is_hidden and Validator.isItemProtected(item_id) then
        return false
    end
    local s = sessionFor(view)
    local txn = ensureTxn()
    local order = getOrderTable(view)

    if is_hidden then
        local source_menu = current_menu_id
            or findParentInProjection(order, item_id)
            or Materializer.effectiveParent(s.reg, txn:view(view), item_id)
        local IntentOps = require("lib.intent_ops")
        IntentOps.setVisibility(view, txn, s.reg, item_id, true, source_menu)
    else
        local hidden_record = txn:getHidden(view, item_id)
        txn:setHidden(view, item_id, nil)
        -- Unhide removes the explicit suppression record idempotently.
        -- When the item still has no VALID home (nil or an unsupported /
        -- vanished container from a legacy preset), migrate deterministically
        -- to a renderable home instead of leaving it unplaced-disabled with
        -- a misleading "Shown" report. Preference: recorded origin when it
        -- is a supported placement, else the provider default / hint home,
        -- else the first live tab. Invalid overrides are dropped so a later
        -- save/rebuild/restart cannot resurrect the stale suppression.
        do
            local section = txn:view(view)
            local home = Materializer.effectiveParent(s.reg, section, item_id)
            local home_valid = home ~= nil
                and Placement.canPlace(s.reg, section, item_id, home)
            if not home_valid then
                local candidate = hidden_record and hidden_record.origin or nil
                local candidate_valid = type(candidate) == "string"
                    and Placement.canPlace(s.reg, section, item_id, candidate)
                if candidate_valid then
                    txn:setParentOverride(view, item_id, {
                        provider = providerStamp(s.reg, item_id),
                        parent = candidate,
                    })
                else
                    -- Drop the stale override outright so defaults flow
                    -- through; an invalid parent must never pin an unhidden
                    -- row into unplaced-disabled.
                    if section.parent_override and section.parent_override[item_id] ~= nil then
                        txn:setParentOverride(view, item_id, nil)
                    end
                    local fallback = Registry.getDefaultParent(s.reg, item_id)
                    if type(fallback) == "string"
                            and Placement.canPlace(s.reg, section, item_id, fallback) then
                        -- Defaults apply without a record; nothing to stage.
                    else
                        -- Last resort: park under the first live tab so the
                        -- restored row is reachable. Tabs themselves live in
                        -- the bar and need no parking.
                        if not Placement.isTab(s.reg, item_id) then
                            local tabs = s.reg and s.reg.tab_list or {}
                            local park = tabs[1]
                            if type(park) == "string"
                                    and Placement.canPlace(s.reg, section, item_id, park) then
                                txn:setParentOverride(view, item_id, {
                                    provider = providerStamp(s.reg, item_id),
                                    parent = park,
                                })
                            end
                        end
                    end
                end
            end
        end
    end

    if not _mirrored then
        self:_mirrorVisibility(view, item_id, is_hidden)
    end
    invalidate(view)
    return true
end

function MenuOrderManager:setTabHidden(view, tab_id, is_hidden)
    if is_hidden and Validator.isTabProtected(tab_id) then
        return false
    end
    -- Tabs are ordinary items under the single-parent model: hiding removes
    -- them from the bar, unhiding restores the intended slot.
    return self:setItemHidden(view, tab_id, is_hidden, MENU_BUTTONS_KEY)
end

function MenuOrderManager:moveItem(view, menu_id, from_idx, to_idx)
    local items = self:getMenuItems(view, menu_id)
    if #items == 0 then return false end
    if from_idx < 1 or from_idx > #items or to_idx < 1 or to_idx > #items then
        return false
    end
    local item = table.remove(items, from_idx)
    table.insert(items, to_idx, item)
    self:stageList(view, menu_id, items)
    return true
end

function MenuOrderManager:moveItemToMenu(view, item_id, from_menu_id, to_menu_id,
                                         target_idx, _mirrored)
    local can_move, err = self:canMoveItemToMenu(view, item_id, from_menu_id, to_menu_id)
    if not can_move then return false, err end

    local s = sessionFor(view)
    local txn = ensureTxn()
    local dest_list = self:getMenuItems(view, to_menu_id)

    do
        local IntentOps = require("lib.intent_ops")
        IntentOps.setVisibility(view, txn, s.reg, item_id, false, nil)
        IntentOps.setMembership(view, txn, s.reg, item_id, to_menu_id)
        -- Single-parent discipline: the row leaves every recorded bulk
        -- arrangement; destination membership comes from the override plus an
        -- optional insertion anchor below.
        IntentOps.stripItemFromSequences(view, txn, item_id)
    end

    if target_idx and target_idx >= 1 and target_idx <= #dest_list + 1 then
        local IntentOps = require("lib.intent_ops")
        if target_idx == 1 then
            IntentOps.setInsertionAnchor(view, txn, s.reg, item_id, false)
        else
            local anchor = dest_list[target_idx - 1]
            if anchor == SEPARATOR_ID then
                anchor = dest_list[target_idx - 2]
            end
            IntentOps.setInsertionAnchor(view, txn, s.reg, item_id,
                anchor == nil and false or anchor)
        end
    else
        -- Appended at the end: no slot constraint needed.
        txn:setPositionOverride(view, item_id, nil)
    end

    MenuOrderManager.recent_moves[view] = MenuOrderManager.recent_moves[view] or {}
    MenuOrderManager.recent_moves[view][item_id] = { from = from_menu_id, to = to_menu_id }

    if not _mirrored then
        self:_mirrorMove(view, item_id, to_menu_id)
    end
    invalidate(view)
    return true
end

function MenuOrderManager:insertSeparator(view, menu_id, idx)
    local items = self:getMenuItems(view, menu_id)
    if type(getOrderTable(view)[menu_id]) ~= "table" then return false end
    if idx < 1 then idx = 1 end
    if idx > #items + 1 then idx = #items + 1 end
    table.insert(items, idx, SEPARATOR_ID)
    self:stageList(view, menu_id, items)
    return true
end

function MenuOrderManager:removeSeparator(view, menu_id, idx)
    local items = self:getMenuItems(view, menu_id)
    if type(getOrderTable(view)[menu_id]) ~= "table" then return false end
    if not items[idx] then return false end
    if items[idx] ~= SEPARATOR_ID then return false end
    table.remove(items, idx)
    -- This verb KNOWS it removed a divider (stageList's joint rule cannot
    -- tell a last-divider removal on a reordered menu from a bulk sort's
    -- stripped transport, so it would skip recording). Record the observed
    -- post-removal arrangement directly; the stageList below then handles
    -- ordering (and agrees on dividers: same observed anchors).
    do
        local IntentOps = require("lib.intent_ops")
        local observed, previous = {}, false
        for _, id in ipairs(items) do
            if id == SEPARATOR_ID then
                observed[#observed + 1] = previous
            else
                previous = id
            end
        end
        local s = sessionFor(view)
        IntentOps.setDividerArrangement(view, ensureTxn(), s.reg, menu_id, observed)
    end
    self:stageList(view, menu_id, items)
    return true
end

function MenuOrderManager:reorderTabs(view, new_tab_list)
    local txn = ensureTxn()
    local defaults = getDefaultOrder(view)[MENU_BUTTONS_KEY] or {}
    local same_as_default = #new_tab_list == #defaults
    if same_as_default then
        for i, t in ipairs(new_tab_list) do
            if defaults[i] ~= t then same_as_default = false break end
        end
    end
    -- Hidden entries stay excluded even in a "stock" arrangement.
    if same_as_default then
        local hidden_tabs = {}
        for _, id in ipairs(self:getDisabledItems(view)) do hidden_tabs[id] = true end
        for _, t in ipairs(new_tab_list) do
            if hidden_tabs[t] then same_as_default = false break end
        end
    end
    txn:setTabOrder(view, same_as_default and nil or util.tableDeepCopy(new_tab_list))
    invalidate(view)
    return true
end

-- -------------------------------------------------------------------------
-- Restore / reset semantics (record cleanup; materialization does the rest)
-- -------------------------------------------------------------------------

function MenuOrderManager:restoreItemDefault(view, item_id)
    -- Stock home lookup mirrors the curated defaults: entries that were never
    -- part of a stock layout fall back to their live registry home (a
    -- plugin's hint-resolved default), so restoring a plugin entry re-attaches
    -- it to whatever its provider currently requests - and lets it follow
    -- future provider changes, because clearing the records below removes the
    -- whole customization instead of pinning today's answer.
    local stock_home
    local stock_index
    local defaults = getDefaultOrder(view)
    for menu_id, dlist in pairs(defaults) do
        if menu_id ~= MENU_BUTTONS_KEY and menu_id ~= DISABLED_KEY
                and type(dlist) == "table" then
            for _, id in ipairs(dlist) do
                if id == item_id then stock_home = menu_id break end
            end
            if stock_home then break end
        end
    end
    if not stock_home then
        local s = sessionFor(view)
        local node = s.reg.nodes[item_id]
        if node then
            if node.default_parent then
                stock_home = node.default_parent
            elseif node.sorting_hint and s.reg.menus[node.sorting_hint] then
                stock_home = node.sorting_hint
            end
        end
    end
    if not stock_home or type(getOrderTable(view)[stock_home]) ~= "table" then
        return false, _("No default placement is available for this entry.")
    end
    local txn = ensureTxn()
    txn:clearItem(view, item_id)
    -- Pin the curated stock slot explicitly: restore semantics demand the
    -- exact default neighbourhood (dividers included), which generic
    -- newcomer alignment deliberately does not preserve. Provider defaults
    -- without a curated slot (plugin hints) stay unpinned on purpose.
    local defaults = getDefaultOrder(view)
    stock_index = nil
    for i, id in ipairs(defaults[stock_home] or {}) do
        if id == item_id then stock_index = i break end
    end
    if stock_index then
        local successors = defaults[stock_home]
        local nxt = successors[stock_index + 1]
        local prv = nil
        for i = stock_index - 1, 1, -1 do
            if successors[i] ~= SEPARATOR_ID then prv = successors[i] break end
        end
        -- The curated slot is provider-stamped like any manual anchor: a
        -- restored entry follows ITS provider, and the pin goes inert if the
        -- id is later claimed by someone else.
        local provider = sessionFor(view).reg.nodes[item_id]
            and sessionFor(view).reg.nodes[item_id].provider or "stock"
        if nxt ~= nil and nxt ~= SEPARATOR_ID then
            txn:setPositionOverride(view, item_id,
                { before = nxt, provider = provider })
        elseif prv then
            txn:setPositionOverride(view, item_id,
                { after = prv, provider = provider })
        end
    end
    MenuOrderManager.recent_moves[view][item_id] = nil
    invalidate(view)
    return true
end

-- Tombstone garbage collection ("Forget stale customizations"):
-- drop every customization record whose id no live provider serves, so a
-- later reinstall starts from the CURRENT provider defaults instead of
-- resurrecting pre-uninstall placements. Records for ids still served by
-- KOReader or any plugin are never touched.
function MenuOrderManager:countStaleCustomizations(view)
    local s = sessionFor(view)
    return GhostGC.countStaleIds(view, s.reg)
end

function MenuOrderManager:forgetStaleCustomizations(view)
    local s = sessionFor(view)
    local stale = GhostGC.countStaleIds(view, s.reg)
    if #stale == 0 then return true, {} end
    local txn = ensureTxn()
    local forgotten_count = GhostGC.forgetIds(view, txn, stale)
    -- Durability: the GC is a deliberate user action and must survive even
    -- when no editor save follows (session end, crash, unrelated reads).
    -- Same funnel as every other save: canonical first (one rebase retry),
    -- then materialization of the changed views.
    local outcome = commitWithGuard(txn, {
        get_session = function(v) return sessionFor(v) end,
        prepare = minimizeIntent,
        invalidate = invalidate,
    })
    ensureTxn()
    if not outcome.committed then
        logger.err("ReorderingMenus: failed to persist stale-GC:", outcome.error)
        return false, stale
    end
    if outcome.failed_views[view] then
        logger.err("ReorderingMenus: stale-GC was saved, but regeneration",
            "failed for", view, ":", outcome.failed_views[view])
    else
        invalidate(view)
    end
    return true, stale, forgotten_count
end

function MenuOrderManager:resetTabsOnly(view)
    local txn = ensureTxn()
    txn:setTabOrder(view, nil)
    for _, tab in ipairs(getDefaultOrder(view)[MENU_BUTTONS_KEY] or {}) do
        txn:setHidden(view, tab, nil)
    end
    MenuOrderManager.recent_moves[view] = {}
    invalidate(view)
    return true
end

function MenuOrderManager:resetSubmenu(view, menu_id)
    local s = sessionFor(view)
    local txn = ensureTxn()
    local section = txn:view(view)
    local defaults = getDefaultOrder(view)

    local pulled_back = {}

    -- Stock children of this menu return home from wherever they went. The
    -- check covers both the intent-level parent and the actual rendered
    -- location, because an imported hand-edited sequence can list a row
    -- somewhere its records do not.
    local order_now = getOrderTable(view)
    local default_list = defaults[menu_id]
    if type(default_list) == "table" then
        for _, child in ipairs(default_list) do
            if child ~= SEPARATOR_ID and type(child) == "string" then
                local current_parent = Materializer.effectiveParent(s.reg, section, child)
                local listed_parent = findParentInProjection(order_now, child)
                local hidden_record = section.hidden[child]
                if current_parent ~= menu_id
                        or (listed_parent ~= nil and listed_parent ~= menu_id)
                        or hidden_record then
                    pulled_back[child] = listed_parent or current_parent
                        or (hidden_record and hidden_record.origin)
                    txn:clearItem(view, child)
                end
            end
        end
    end

    -- Foreign items deliberately parked here return to their own homes.
    for id, record in pairs(util.tableDeepCopy(section.parent_override)) do
        if record.parent == menu_id then
            local home = Materializer.effectiveParent(s.reg,
                Materializer.emptyIntent(), id)
            if home and home ~= menu_id then
                pulled_back[id] = menu_id
                txn:setParentOverride(view, id, nil)
                txn:setPositionOverride(view, id, nil)
            end
        end
    end

    -- Items hidden from this menu specifically become visible again, at
    -- their recorded home when nothing else resolves one.
    for id, record in pairs(util.tableDeepCopy(section.hidden)) do
        if record.origin == menu_id then
            txn:setHidden(view, id, nil)
            if Materializer.effectiveParent(s.reg, txn:view(view), id) == nil then
                txn:setParentOverride(view, id, {
                    provider = providerStamp(s.reg, id),
                    parent = record.origin,
                })
            end
            pulled_back[id] = menu_id
        end
    end

    -- Record each pulled-back item's return so open editors of its previous
    -- location heal their stale snapshots instead of resurrecting it.
    for item_id, old_parent in pairs(pulled_back) do
        MenuOrderManager.recent_moves[view] = MenuOrderManager.recent_moves[view] or {}
        MenuOrderManager.recent_moves[view][item_id] = {
            from = tostring(old_parent),
            to = menu_id,
        }
    end

    txn:setOrderOverride(view, menu_id, nil)
    txn:setRawOverride(view, menu_id, nil)
    -- Manual anchors (single-relocation drags) are placement records too:
    -- a menu reset must clear every anchor whose item belongs to THIS menu,
    -- otherwise the pre-reset arrangement survives the reset.
    for id in pairs(util.tableDeepCopy(section.position_override)) do
        local record = section.position_override[id]
        if type(record) == "table" then
            local home = Materializer.effectiveParent(s.reg,
                Materializer.emptyIntent(), id)
            if home == menu_id or findParentInProjection(order_now, id) == menu_id then
                txn:setPositionOverride(view, id, nil)
            end
        end
    end
    for key in pairs(txn:view(view).separators or {}) do
        local sep = txn:view(view).separators[key]
        if sep and sep.parent == menu_id then
            txn:view(view).separators[key] = nil
        end
    end

    invalidate(view)
    return true, pulled_back
end

-- -------------------------------------------------------------------------
-- Created submenus
-- -------------------------------------------------------------------------

-- Legacy numeric custom ids ("custom_submenu_3") are recognized for
-- compatibility, but new submenus get collision-proof namespaced ids:
--   reorderingmenus:user:<uuid>
-- The namespace prefix is RESERVED (see koreader_adapter): no plugin or
-- stock id can ever land under it, so a future KOReader version introducing
-- "reading_tools" can never fuse with a user submenu that happens to share
-- its display title. The title lives only in the intent record.
local deterministic_id_counter = 0

local function newCustomSubmenuId()
    -- Test hook: RNM_DETERMINISTIC_IDS makes generated submenu ids
    -- reproducible, so state-machine failures can be replayed verbatim.
    if os.getenv("RNM_DETERMINISTIC_IDS") then
        local counter = (deterministic_id_counter or 0) + 1
        deterministic_id_counter = counter
        return KoreaderAdapter.NAMESPACE_PREFIX .. "user:"
            .. string.rep("00", 12) .. string.format("%08x", counter)
    end
    -- P1B (#14): KOReader-native UUID v4 generation (frontend/random.lua,
    -- same source stock uses for e.g. device_id). Replaces the private
    -- /dev/urandom read + custom hex encoder + math.random fallback.
    return KoreaderAdapter.NAMESPACE_PREFIX .. "user:" .. Random.uuid()
end

function MenuOrderManager:createSubmenu(view, parent_menu_id, title, idx)
    local order = getOrderTable(view)
    local parent_list = order[parent_menu_id]
    if type(parent_list) ~= "table" or NativeWriter.RESERVED[parent_menu_id] then
        return false, _("The target menu is unavailable.")
    end
    title = util.trim(tostring(title or ""))
    if title == "" then
        return false, _("The submenu name cannot be empty.")
    end
    local new_id = newCustomSubmenuId()

    local txn = ensureTxn()
    -- The parent lives ONLY in parent_override (single authority): the
    -- creation record carries the title, the override carries placement.
    txn:setCustomMenu(view, new_id, { title = title })
    txn:setParentOverride(view, new_id, {
        provider = nil,   -- customs are not registry nodes; always applies
        parent = parent_menu_id,
    })
    if idx == nil or idx < 1 or idx > #parent_list + 1 then
        idx = #parent_list + 1
    end
    local staged = util.tableDeepCopy(parent_list)
    table.insert(staged, idx, new_id)
    self:stageList(view, parent_menu_id, staged)
    return true, new_id
end

-- Register a hand-authored menu level verbatim (raw passthrough). Used for
-- levels that exist outside stock defaults and outside created submenus.
-- Goes through the shared opaque-fragment vocabulary (raw owns the level
-- exclusively by construction there).
function MenuOrderManager:stageRawLevel(view, menu_id, list)
    local IntentOps = require("lib.intent_ops")
    IntentOps.preserveOpaqueLevel(view, ensureTxn(), menu_id, list)
    invalidate(view)
    return true
end

function MenuOrderManager:deleteCustomSubmenu(view, submenu_id)
    local order = getOrderTable(view)
    local section = ensureTxn():view(view)
    -- Canonical custom-menu membership is authoritative even when the
    -- container itself is hidden and therefore absent from the projection.
    if type(section.custom_menus) ~= "table"
            or section.custom_menus[submenu_id] == nil then
        return false, _("Only created submenus can be deleted.")
    end
    local content = type(order[submenu_id]) == "table" and order[submenu_id] or {}
    for __, item_id in ipairs(content) do
        if item_id ~= SEPARATOR_ID then
            return false, _("Move or hide this submenu's items before deleting it.")
        end
    end
    -- Hidden occupants are invisible in the projection but still belong here:
    -- deleting over their heads would orphan them against a nonexistent home.
    for id, record in pairs(section.hidden or {}) do
        if type(record) == "table" and record.origin == submenu_id then
            return false, _("Move or hide this submenu's items before deleting it.")
        end
    end
    for id, record in pairs(section.parent_override or {}) do
        if type(record) == "table" and record.parent == submenu_id
                and Materializer.effectiveParent(sessionFor(view).reg, section, id)
                    == submenu_id then
            return false, _("Move or hide this submenu's items before deleting it.")
        end
    end
    ensureTxn():deleteCustomMenu(view, submenu_id)
    invalidate(view)
    return true
end

function MenuOrderManager:getCustomSubmenuTitle(view, submenu_id)
    local customs = getOrderTable(view)[CUSTOM_SUBMENUS_KEY]
    if type(customs) == "table" and type(customs[submenu_id]) == "string" then
        return customs[submenu_id]
    end
    return nil
end

function MenuOrderManager:getCustomSubmenus(view)
    local customs = getOrderTable(view)[CUSTOM_SUBMENUS_KEY]
    return type(customs) == "table" and util.tableDeepCopy(customs) or {}
end

function MenuOrderManager:isCustomSubmenu(view, submenu_id)
    return self:getCustomSubmenuTitle(view, submenu_id) ~= nil
end

-- -------------------------------------------------------------------------
-- Backups (session-scoped undo of staged intent)
-- -------------------------------------------------------------------------

function MenuOrderManager:backupOrder(view)
    backups[view] = util.tableDeepCopy(ensureTxn():view(view))
    return true
end

function MenuOrderManager:restoreOrder(view)
    if backups[view] then
        ensureTxn():setViewSection(view, util.tableDeepCopy(backups[view]))
        MenuOrderManager.recent_moves[view] = {}
        invalidate(view)
        return true
    end
    return false
end

-- -------------------------------------------------------------------------
-- Mirroring between Book view and Normal view
-- -------------------------------------------------------------------------

local function getMirrorContext(view)
    if view == "reader" then return "filemanager" end
    if view == "filemanager" then return "reader" end
    return nil
end

local function mirrorTargetKnown(other_view, item_id, dest_menu)
    local s = sessions[other_view]
    local reg = s and s.reg or nil
    if reg and reg.nodes and reg.nodes[item_id] then return true end
    local order = getOrderTable(other_view)
    if findParentInProjection(order, item_id) then return true end
    for _, disabled_id in ipairs(order[DISABLED_KEY] or {}) do
        if disabled_id == item_id then return true end
    end
    local dlist = getDefaultOrder(other_view)[dest_menu]
    return type(dlist) == "table" and util.arrayContains(dlist, item_id)
end

-- The DESTINATION menu must exist in the other view before a move mirrors:
-- writing a parent_override pointing at a foreign menu would poison canonical
-- intent with a cross-view-ghost record (the projection heals on read, but
-- every restart re-materializes from the polluted store until an unrelated
-- save of that view happens to wash it out). Tabs count as destinations so
-- items may mirror into a tab's own list.
local function mirrorDestinationKnown(other_view, dest_menu)
    if type(dest_menu) ~= "string" then return false end
    local s = sessions[other_view]
    local reg = s and s.reg or nil
    if reg and reg.menus[dest_menu] then return true end
    return getDefaultOrder(other_view)[dest_menu] ~= nil
end

function MenuOrderManager:_mirrorVisibility(view, item_id, is_hidden)
    -- Mirrored visibility reuses the SAME validated command (setItemHidden,
    -- with its protected-item gate and unhide-migration) against the second
    -- view — never a direct record write (Prompt 4 §8).
    if not IntentStore.meta().mirror_changes then return end
    local other_view = getMirrorContext(view)
    if not other_view then return end
    local dest = self:getParentMenu(view, item_id)
        or Materializer.effectiveParent(sessionFor(view).reg,
            Materializer.emptyIntent(), item_id)
    if not mirrorTargetKnown(other_view, item_id, dest) then
        logger.info("ReorderingMenus: mirror skipped,", item_id,
            "is not known to", other_view)
        return
    end
    self:setItemHidden(other_view, item_id, is_hidden, nil, true)
end

function MenuOrderManager:_mirrorMove(view, item_id, to_menu_id)
    if not IntentStore.meta().mirror_changes then return end
    local other_view = getMirrorContext(view)
    if not other_view then return end
    if not mirrorTargetKnown(other_view, item_id, to_menu_id)
            or not mirrorDestinationKnown(other_view, to_menu_id) then
        logger.info("ReorderingMenus: mirror skipped,", item_id,
            "or its destination", to_menu_id, "is not known to", other_view)
        return
    end
    -- Validated against the SECOND view with the same semantic command as
    -- the primary move (Prompt 4 §8): ancestry can diverge per view (a move
    -- valid in Reader can be cyclic in File Manager), so the mirror is
    -- gated on the other view's effective containment, never staged blind.
    -- A skipped mirror leaves the other view untouched (no partial state).
    if type(to_menu_id) == "string" and type(item_id) == "string" then
        if to_menu_id == item_id
                or self:isMenuDescendant(other_view, item_id, to_menu_id) then
            logger.info("ReorderingMenus: mirror skipped,", item_id, "->",
                to_menu_id, "is cyclic in", other_view)
            return
        end
    end
    local s_other = sessionFor(other_view)
    local txn = ensureTxn()
    local IntentOps = require("lib.intent_ops")
    -- Same command shape as moveItemToMenu: unhide on move, validated
    -- membership, single-parent sequence discipline, append slot (index
    -- mapping across divergent views is meaningless, so mirrors append).
    IntentOps.setVisibility(other_view, txn, s_other.reg, item_id, false, nil)
    local ok_place = IntentOps.setMembership(other_view, txn, s_other.reg,
        item_id, to_menu_id)
    if not ok_place then
        logger.info("ReorderingMenus: mirror skipped: unsupported placement",
            item_id, "->", to_menu_id, "in", other_view)
        return
    end
    IntentOps.stripItemFromSequences(other_view, txn, item_id)
    txn:setPositionOverride(other_view, item_id, nil)
    MenuOrderManager.recent_moves[other_view] = MenuOrderManager.recent_moves[other_view] or {}
    MenuOrderManager.recent_moves[other_view][item_id] =
        { from = self:getParentMenu(other_view, item_id), to = to_menu_id }
    invalidate(other_view)
end

function MenuOrderManager:isMirroringEnabled()
    return IntentStore.meta().mirror_changes == true
end

-- P0-11 ownership rule:
--   * hidden-position mode is a TRANSACTION-OWNED preference flip (it rides
--     setMetaValue's staging, committing/discarding with the layout edit);
--   * the mirroring TOGGLE is a truly independent user preference: flipping
--     it cannot invalidate any staged arrangement (it only gates whether
--     FUTURE verbs mirror), so it persists immediately.
--
-- The one hazard to close: persisting meta while a transaction holds staged
-- ui_state would make IntentStore.save() write the CANONICAL views together
-- with the toggle, freezing half-staged state durably. While a live
-- transaction exists, the toggle is applied to BOTH the staged metadata and
-- canonical meta, and durable persistence defers to that transaction's next
-- commit (which writes both consistently). With no transaction open, the
-- historical instant-persist applies.
function MenuOrderManager:setMirroringEnabled(enabled)
    local txn = active_txn
    local usable = txn and txn:isOpen()
        and txn.store_epoch == IntentStore.storeEpoch() and txn or nil
    if usable then
        -- Keep staged metadata coherent with the preference flip; the value
        -- itself rides the transaction's next Save/Discard.
        usable:setMetaValue("mirror_changes", enabled == true)
        return true
    end
    return IntentStore.setMeta("mirror_changes", enabled == true)
end

function MenuOrderManager:isHiddenInPlace()
    -- P1B: hidden-row PRESENTATION is an ordinary operational preference
    -- (plugin settings namespace), not layout state. Legacy canonical-meta
    -- values are ignored; the plugin setting is the single authority.
    return PluginPrefs.get("hidden_in_place", true) == true
end

function MenuOrderManager:setHiddenInPlace(enabled)
    PluginPrefs.set("hidden_in_place", enabled == true)
    return true
end

-- -------------------------------------------------------------------------
-- Layout copy
-- -------------------------------------------------------------------------

function MenuOrderManager:copyLayout(from_view, to_view)
    local txn = ensureTxn()
    txn:setViewSection(to_view, util.tableDeepCopy(txn:view(from_view)))
    invalidate(to_view)
    return true
end

-- Suspend-for-disable (KOReader PluginLoader.stopPlugin hook).
--
-- Disabling the plugin must return KOReader's menus to stock: stock
-- MenuSorter reads the native override files on every build, so withdrawing
-- them restores default order immediately - even before the prompted
-- restart. Canonical intent is deliberately PRESERVED, so re-enabling
-- regenerates the customized layout from it (the sidecar's suspended marker
-- distinguishes our withdrawal from a deliberate user revert, which would
-- wipe intent instead; see NativeWriter.syncView).
--
-- Deliberately session-preserving: dropping sessions here would re-run the
-- startup sync in-process and regenerate the files we just withdrew.
-- Best-effort per view; returns a per-view summary. Never raises.
function MenuOrderManager:suspendForDisable()
    -- Durability first: the suspended marker (sidecar, atomic) must be
    -- durable BEFORE the native file is withdrawn. A crash between the two
    -- steps must leave "marked + file present" (safe: next startup sees our
    -- bytes) rather than "unmarked + file absent" (fatal: next startup reads
    -- a deliberate user revert and wipes canonical intent).
    local summary = {}
    for _, view in ipairs(MenuSchema.VIEWS) do
        local marked, mark_err = NativeWriter.markSuspended(view)
        local removed, remove_err = true, nil
        if marked then
            removed, remove_err = KoreaderAdapter.removeNativeOrder(view)
        end
        summary[view] = {
            removed = removed,
            remove_error = remove_err,
            suspended = marked,
            suspend_error = mark_err,
        }
        if not removed then
            logger.warn("ReorderingMenus: suspend could not withdraw",
                view, "native order:", remove_err)
        elseif not marked then
            logger.warn("ReorderingMenus: suspend could not mark",
                view, "sidecar:", mark_err)
        end
    end
    KoreaderAdapter.invalidateNativeModuleCache()
    return summary
end

-- Restore hidden structural tab containers across all views in ONE semantic operation.
-- Unhides hazardous containers, commits once, and returns restored ids + status.
function MenuOrderManager:prepareForPluginRemoval()
    local restored = { failures = {} }
    for _, view in ipairs({ "reader", "filemanager" }) do
        restored[view] = {}
        local order = self:loadOrder(view)
        if order then
            for _, id in ipairs(order[DISABLED_KEY] or {}) do
                local ok_change, change_err = self:setItemHidden(view, id, false)
                if ok_change ~= false then
                    table.insert(restored[view], id)
                else
                    table.insert(restored.failures, {
                        view = view,
                        id = id,
                        error = ok_change == false and "protected item"
                            or tostring(change_err),
                    })
                end
            end
        end
    end
    local outcome = self:commitStaged()
    if not outcome.committed then
        table.insert(restored.failures, {
            view = nil,
            error = outcome.error or "commit failed",
        })
    end
    for failed_view, write_err in pairs(outcome.failed_views or {}) do
        table.insert(restored.failures, {
            view = failed_view,
            error = write_err,
        })
    end
    restored.ok = #restored.failures == 0
    return restored
end

function MenuOrderManager:applyLiveReload(ui, _view)
    local sanitizer = function(tree)
        local UIScreens = require("lib.ui_screens")
        return UIScreens:sanitizeLiveMenuTree(tree)
    end
    return KoreaderAdapter.applyLiveReload(ui, sanitizer)
end

function MenuOrderManager:reconcileRegisteredItems(view, menu_items, providers, collisions)
    local s0 = sessions[view]
    local prev_reg = s0 and s0.reg or nil
    -- Collisions ride along (may be nil for legacy/test callers): dropping
    -- them here used to wipe the deterministic smallest-name attribution that
    -- setLiveRegistrations had just stored, losing contested-identity
    -- metadata during every reconciliation.
    self:setLiveRegistrations(view, menu_items, providers, collisions)
    self:refreshRegistry(view)
    local s = sessions[view]
    -- A refreshed registry can change the derived graph without changing
    -- canonical intent (new/removed provider row, provider identity flip,
    -- sorting-hint change). Force the normal sync classifier to compare the
    -- last checkpoint against this new registry before a no-op save is
    -- eligible for the fast path.
    -- Untouched provider state follows current provider defaults; no synthetic
    -- lifecycle pins are generated. Stamped user intent remains dormant while
    -- a provider is absent and reactivates when it returns.
    local changed = false
    if prev_reg ~= nil then
        for id in pairs(s.reg.nodes) do
            if prev_reg.nodes[id] == nil and not NativeWriter.RESERVED[id] then
                changed = true
                break
            end
        end
        if not changed then
            for id in pairs(prev_reg.nodes) do
                if s.reg.nodes[id] == nil and not NativeWriter.RESERVED[id] then
                    changed = true
                    break
                end
            end
        end
    end

    return changed
end

-- -------------------------------------------------------------------------
-- Protection helpers
-- -------------------------------------------------------------------------

function MenuOrderManager:isTabProtected(tab_id)
    return Validator.isTabProtected(tab_id)
end

function MenuOrderManager:isItemProtected(item_id)
    return Validator.isItemProtected(item_id)
end

-- -------------------------------------------------------------------------
-- Preset management (delegating; intent snapshots, not runtime arrays)
-- -------------------------------------------------------------------------

function MenuOrderManager:getPresetsDir(view)
    return Presets.getPresetsDir(view)
end

function MenuOrderManager:getSubmenuPresetsDir(view, menu_id)
    -- Discovery-facing accessor: never creates directories.
    return Presets.findSubmenuPresetsDir(view, menu_id)
end

function MenuOrderManager:saveSubmenuPreset(view, menu_id, menu_title, preset_name,
                                            include_nested, current_menu_items)
    local s = sessionFor(view)
    local txn = ensureTxn()
    return Presets.saveSubmenuPreset(view, menu_id, menu_title, preset_name,
        include_nested, s.reg, txn:view(view), current_menu_items)
end

function MenuOrderManager:listSubmenuPresets(view, menu_id)
    return Presets.listSubmenuPresets(view, menu_id)
end

function MenuOrderManager:loadSubmenuPreset(view, menu_id, preset, current_menu_items)
    -- P1B CONTRACT (one commit per apply): a SUBMENU preset is a FRAGMENT
    -- staged into the OPEN transaction (so placement/membership validation
    -- sees the surrounding draft), then committed ONCE via saveOrder below.
    -- Governed levels are replaced wholesale (saved fragment wins over both
    -- previously staged intent AND un-staged widget rows for those levels —
    -- P0 Bug8); ungoverned levels and post-capture arrivals survive via tail
    -- merge. Full-view presets (loadPreset) likewise commit once via
    -- saveOrder. Neither path writes native output directly.
    local s = sessionFor(view)
    local txn = ensureTxn()
    local ok, err = Presets.loadSubmenuPreset(view, menu_id, preset, s.reg, txn,
        current_menu_items)
    if not ok then return false, err end
    invalidate(view)
    return self:saveOrder(view)
end

function MenuOrderManager:deleteSubmenuPreset(view, menu_id, preset)
    return Presets.deleteSubmenuPreset(view, menu_id, preset)
end

function MenuOrderManager:getHiddenBuiltinPath(view)
    return Presets.getHiddenBuiltinPath(view)
end

function MenuOrderManager:getHiddenBuiltinIds(view)
    return Presets.getHiddenBuiltinIds(view)
end

function MenuOrderManager:isBuiltinHidden(view, preset_id)
    return Presets.isBuiltinHidden(view, preset_id)
end

function MenuOrderManager:hideBuiltinPreset(view, preset_id)
    return Presets.hideBuiltinPreset(view, preset_id)
end

function MenuOrderManager:unhideBuiltinPreset(view, preset_id)
    return Presets.unhideBuiltinPreset(view, preset_id)
end

function MenuOrderManager:getBuiltinPresets(view)
    return Presets.getBuiltinPresets(view)
end

function MenuOrderManager:listUserPresets(view)
    return Presets.listUserPresets(view)
end

function MenuOrderManager:getAllPresets(view)
    return Presets.getAllPresets(view)
end

function MenuOrderManager:listDeletablePresets(view)
    return Presets.listDeletablePresets(view)
end

function MenuOrderManager:savePreset(view, preset_name)
    local txn = ensureTxn()
    return Presets.saveViewPreset(view, preset_name, txn:view(view))
end

function MenuOrderManager:updatePreset(view, preset)
    local txn = ensureTxn()
    return Presets.updateUserPresetFile(view, preset, txn:view(view))
end

-- Import a dense (legacy) order table into a standalone intent section by
-- diffing it against the CURRENT defaults.
local function importDenseAsIntent(view, reg, dense)
    local txn = IntentStore.openTransaction()
    txn:setViewSection(view, IntentStore.newViewSection())
    NativeWriter.importAgainstDefaults(view, reg, txn, dense)
    return util.tableDeepCopy(txn:view(view))
end

function MenuOrderManager:loadPreset(view, preset)
    local resolved, resolve_err = Presets.resolve(view, preset)
    if not resolved then return false, resolve_err or _("Preset not found.") end

    if resolved.kind == "default" then
        local ok, err = self:resetOrder(view)
        if not ok then return false, err end
        logger.info("ReorderingMenus: applied Default preset - reset to stock")
        return true
    end

    local s = sessionFor(view)
    local txn = ensureTxn()

    if resolved.kind == "builtin" then
        -- Built-in layouts are complete tab-bar intents: start from stock and
        -- apply the fragment, exactly like their dense predecessors did.
        txn:resetView(view)
        local fragment = resolved.fragment
        txn:setTabOrder(view, fragment.tab_order
            and util.tableDeepCopy(fragment.tab_order) or nil)
        local hidden_set = {}
        for _, tab in ipairs(fragment.hidden_tabs or {}) do
            hidden_set[tab] = true
        end
        for _, tab in ipairs(getDefaultOrder(view)[MENU_BUTTONS_KEY] or {}) do
            if hidden_set[tab] then
                txn:setHidden(view, tab, {
                    provider = "stock",
                    origin = MENU_BUTTONS_KEY,
                })
            else
                txn:setHidden(view, tab, nil)
            end
        end
    else
        local preset_intent
        if resolved.kind == "user_v2" then
            preset_intent = resolved.data.intent
        elseif resolved.kind == "user_file" then
            local data = Presets.readUserPreset(resolved.path)
            if not data then return false, _("Failed to load preset file.") end
            -- P1B ingress: view/type compatibility BEFORE any conversion or
            -- application. A reader snapshot must never land in FM state.
            local view_ok, view_err = Presets.checkViewCompatibility(view, data)
            if not view_ok then return false, view_err end
            if data.format == "reorderingmenus_intent_preset" and type(data.intent) == "table" then
                preset_intent = data.intent
            else
                preset_intent = importDenseAsIntent(view, s.reg, data)
            end
        elseif resolved.kind == "legacy_dense" then
            preset_intent = importDenseAsIntent(view, s.reg, resolved.dense)
        end
        if type(preset_intent) ~= "table" then
            return false, _("Preset not found.")
        end
        Presets.applyUserIntentPreset(view, txn, preset_intent, s.reg)
        -- Centralized safe migration for legacy presets carrying stale
        -- parents, tab_nesting, or invalid containers: drop unsupported
        -- placements deterministically (tab stays in bar). The preset file
        -- on disk is untouched, so user data stays recoverable.
        do
            local ok_san, report = pcall(function()
                return Placement.sanitizeSection(s.reg, txn:view(view))
            end)
            if ok_san and report and (#report.dropped_parents > 0
                    or #report.stripped_sequences > 0 or report.tab_order_filtered) then
                logger.warn("ReorderingMenus: preset for", view,
                    "migrated unsupported placements:",
                    "dropped parents=" .. table.concat(report.dropped_parents, ","),
                    "stripped sequences=" .. table.concat(report.stripped_sequences, ","))
            end
        end
    end

    MenuOrderManager.recent_moves[view] = {}
    -- A preset is a semantic reset of the view's arrangement: the next
    -- projection derives from the freshly applied intent alone.
    invalidate(view)
    return self:saveOrder(view)
end

function MenuOrderManager:deletePreset(view, preset_name)
    for _, b in ipairs(Presets.getBuiltinPresets(view)) do
        if b.id == preset_name or b.name == preset_name then
            if b.id == "builtin_default" then
                return false, _("Cannot delete the default preset.")
            end
            return self:hideBuiltinPreset(view, b.id)
        end
    end
    return Presets.deletePresetFile(view, preset_name)
end

return MenuOrderManager

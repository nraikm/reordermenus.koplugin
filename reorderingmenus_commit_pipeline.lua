--[[
commit_pipeline.lua — THE commit/materialization funnel.

One small manager-level operation, commitAndApply(transaction, options),
replaces every per-caller duplication of:

    commit (+ one stale rebase) -> resolve/validate -> writeView ->
    sidecar checkpoint -> removeNativeOrder on reset -> live reload

Sequence inside the funnel:

  1. canonical intent commits ONCE (source of truth);
  2. the ACTUAL committed generation is read back from the store;
  3. changed views come from the transaction itself
     (Transaction.changedViews - computed against pre-commit canonical,
      not remembered by callers);
  4. every changed view is materialized (writeView or removeNativeOrder
     for emptied views);
  5. derived files are written; the sidecar checkpoints what was emitted;
  6. live reload runs only for requested views;
  7. a structured Outcome is returned (P0-5): callers can distinguish
     "nothing durable happened" from "intent saved but regeneration
     needed" from "saved but reload failed" without parsing booleans.

No event bus, no command objects, no workflow engine: one function with a
loop over the transaction's own changed views.
--]]

local logger = require("logger")

local IntentStore = require("reorderingmenus_intent_store")
local Materializer = require("reorderingmenus_materializer")
local Validator = require("reorderingmenus_validator")
local NativeWriter = require("reorderingmenus_native_writer")
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
local MenuSchema = require("reorderingmenus_menu_schema")

local CommitPipeline = {}

CommitPipeline.STATUS = {
    -- Nothing changed (semantic no-op); no durable write occurred.
    UNCHANGED = "unchanged",
    -- Commit failed or refused.
    NOT_SAVED = "not_saved",
    -- Canonical intent is durable but at least one derived view failed to
    -- regenerate. Restart (or next sync) regenerates from intent alone.
    NEEDS_REGENERATION = "saved_needs_regeneration",
    -- Everything durable succeeded; native restart required to see changes.
    SAVED_RESTART_REQUIRED = "saved_restart_required",
    NEEDS_RESTART = "saved_restart_required",
    -- Fully applied.
    SAVED = "saved",
}

local function safeGeneration(view)
    local ok, value = pcall(IntentStore.generation, view)
    return ok and value or 0
end

--- Construct the one canonical Outcome shape used at every boundary.
--- Public so the manager can turn an unexpected raised exception into the
--- same fail-closed contract without reconstructing status from booleans.
function CommitPipeline.newOutcome(status, err)
    return {
        status = status,
        committed = false,
        generation = safeGeneration(),
        view_generations = {
            reader = safeGeneration("reader"),
            filemanager = safeGeneration("filemanager"),
        },
        changed_views = {},
        failed_views = {},
        reload_failed = {},
        error = err and tostring(err) or nil,
    }
end

function CommitPipeline.failureOutcome(err)
    return CommitPipeline.newOutcome(CommitPipeline.STATUS.NOT_SAVED,
        err or "commit pipeline raised")
end

function CommitPipeline.unchangedOutcome()
    return CommitPipeline.newOutcome(CommitPipeline.STATUS.UNCHANGED)
end

--- Materialize ONE view's committed section to its derived native file.
---
--- The remove-vs-write decision is SEMANTIC, based on what the sparse
--- emission would contain — not on whether the intent section has records:
--- provider-inert tombstones (dormant era records) legitimately produce an
--- EMPTY emission while still occupying canonical state. previewEmission
--- applies the full cleaner-generation policy (reserved-map stripping
--- included); a nil preview means "stock rules must flow again NOW": the
--- file is removed and the removal checkpointed as a legitimate empty
--- emission ({structure = nil}) so external-edit classification keeps a
--- real baseline. Otherwise writeView emits atomically as usual.
--- Returns ok(bool), err.
local function materializeView(view, reg)
    local section = IntentStore.view(view)
    local graph = Materializer.resolve(reg, section)
    local _, repaired = Validator.validate(graph, reg, section)

    -- Canonical emptiness is decided on INTENT, not on the projection: a
    -- deliberate reset / pristine world must end with NO derived file even
    -- when the cleaner-generation policy would keep the reserved maps alive
    -- for one more mid-session build (previous emission held a non-empty
    -- disabled set). Writing that scrubbing emission here leaves a zombie
    -- reserved-only file: isCustomized stays true and stock rules stay
    -- shadowed - reset would look like it never happened.
    local has_records = false
    for _, collection_name in ipairs(MenuSchema.VIEW_COLLECTIONS) do
        local c = section[collection_name]
        if type(c) == "table" and next(c) ~= nil then
            has_records = true
            break
        end
    end
    local intent_empty = not has_records and section.tab_order == nil

    -- Provider-inert tombstones legitimately occupy canonical state while
    -- producing an EMPTY emission (Materializer gates every application
    -- through provider equality): previewEmission applies the full
    -- cleaner-generation policy, so a nil preview means "stock rules must
    -- flow again NOW" even though records remain. Both routes converge on
    -- remove + empty-emission checkpoint ({structure = nil}) so external-
    -- edit classification keeps a real baseline and reconcile stays clean;
    -- canonical records are never touched here (tombstones survive).
    local preview = NativeWriter.previewEmission(view, reg, section, repaired)
    if intent_empty or preview == nil
            or NativeWriter.emissionIsReservedOnly(preview) then
        local ok_remove = KoreaderAdapter.removeNativeOrder(view)
        if not ok_remove then
            return false, "remove failed"
        end
        local ok_ckpt = NativeWriter.checkpointEmptyEmission(view)
        if not ok_ckpt then
            return false, "checkpoint failed"
        end
        return true, nil
    end
    return NativeWriter.writeView(view, reg, section, repaired)
end

--- The funnel. Options:
---   get_session    -> function(view) -> { reg = ... } | nil
---   prepare        -> function(txn, view, reg)  sparse-minimization hook,
---                     run for EVERY changed view BEFORE the commit so the
---                     persisted intent is already minimal when generations
---                     are assigned
---   reload         = { view1, ... } views to live-reload after success
---   reload_fn      = function(view) -> ok(bool), err   (UI live rebuild)
---   invalidate     = function(view)                    (drop projections)
---
--- Returns an Outcome:
---   {
---     status       = CommitPipeline.STATUS.*,
---     committed    = true|false      -- canonical intent durable?
---     generation   = number          -- actual persisted global generation
---     view_generations = { reader = n, filemanager = n }
---     changed_views    = { reader=bool, filemanager=bool }  (from txn)
---     failed_views     = { [view] = err }   -- derived output failures
---     reload_failed    = { [view] = err }
---     error            = string|nil         -- commit-stage error if any
---   }
function CommitPipeline.commitAndApply(txn, options)
    options = options or {}
    local outcome = CommitPipeline.newOutcome(nil)

    -- Protected canonical storage (#1): refuse EVERYTHING at the funnel
    -- entrance - commits, no-op commits, and derived-output maintenance
    -- alike. A no-op commit would otherwise slip past IntentStore.save()'s
    -- protection gate (nothing durable to write) and still run the
    -- maintenance branch below, regenerating this world's derived files
    -- from the frozen empty state and wiping the user's live menu layout.
    -- Nothing about the guarded world may reach disk until an explicit
    -- user reset/import lifts the guard.
    if IntentStore.isProtected() then
        logger.err("ReorderingMenus: refusing to commit:",
            "storage is protected by an unsupported future schema")
        outcome.status = CommitPipeline.STATUS.UNCHANGED
        outcome.error = "protected_state"
        return outcome
    end

    local changed = txn:changedViews()
        or { reader = false, filemanager = false }
    local any_changed = changed.reader or changed.filemanager

    -- Pre-commit sparse minimization for EVERY view the transaction would
    -- replace — including ones whose staged section still equals canonical
    -- (a startup import may have re-staged records identical to canonical
    -- while a stale bulk sequence from an earlier import lingers; that
    -- residue is exactly what minimization exists to remove).
    if options.prepare then
        for _, view in ipairs(MenuSchema.VIEWS) do
            local s = options.get_session and options.get_session(view)
            if s and s.reg then
                options.prepare(view, txn, s.reg)
            end
        end
        -- Re-derive changed views: minimization may have emptied a staged
        -- section back down to canonical.
        changed = txn:changedViews()
        any_changed = changed.reader or changed.filemanager
    end

    -- 1+2+3. One canonical commit; the funnel reads back what actually
    -- persisted. A stale transaction gets exactly ONE record-level rebase:
    -- repeated races are reported, never retried indefinitely.
    local ok_commit, commit_err = txn:commit(true)
    if not ok_commit and commit_err == "stale_transaction" then
        logger.warn("ReorderingMenus: save raced another writer;",
            "rebasing staged changes once")
        local merged_sections = {}
        for _, view in ipairs(MenuSchema.VIEWS) do
            merged_sections[view] = txn:mergeSection(view)
        end
        local rebased = IntentStore.openTransaction()
        txn:discard()
        for _, view in ipairs(MenuSchema.VIEWS) do
            rebased:setViewSection(view, merged_sections[view])
        end
        -- Recompute changed views against the REBASED staging: the merge
        -- may have adopted canonical wholesale for untouched views.
        changed = rebased:changedViews()
        any_changed = changed.reader or changed.filemanager
        txn = rebased
        ok_commit, commit_err = txn:commit(true)
    end
    if not ok_commit then
        outcome.status = CommitPipeline.STATUS.NOT_SAVED
        outcome.error = tostring(commit_err or "commit failed")
        return outcome
    end

    -- Registry-only changes (provider arrival/removal/replacement, sorting
    -- hint or defaults changes) can alter a derived graph without changing
    -- canonical intent. The manager marks those views explicitly so they are
    -- regenerated even when another view also has a canonical change (the
    -- ordinary no-change maintenance branch below would otherwise be skipped).
    for _, view in ipairs(MenuSchema.VIEWS) do
        if options.force_views and options.force_views[view] then
            changed[view] = true
            any_changed = true
        end
    end

    outcome.committed = true
    outcome.generation = IntentStore.generation()
    for _, view in ipairs(MenuSchema.VIEWS) do
        outcome.view_generations[view] = IntentStore.generation(view)
    end
    outcome.changed_views = changed

    if not any_changed then
        -- Semantic no-op: generations did not move and there is nothing new
        -- to materialize - EXCEPT when a view has no valid checkpoint yet
        -- (first save establishes the reconciliation baseline; a stale
        -- writer version refreshes its stamp). Both are derived-output
        -- maintenance, never canonical work: no generation moves.
        local needs_maintenance = false
        for _, view in ipairs(MenuSchema.VIEWS) do
            local maintain = NativeWriter.recordNeedsMaterialization(view)
            if not maintain then
                -- Emission drift with unchanged canonical (a provider-era
                -- flip gated records out, stock layout changed): the derived
                -- file is stale even though every generation agrees. Same
                -- maintenance class as a stale checkpoint - regenerate,
                -- never import.
                local s = options.get_session and options.get_session(view)
                if s and s.reg
                        and not NativeWriter.emissionMatchesRecord(view, s.reg) then
                    maintain = true
                end
            end
            if maintain then
                needs_maintenance = true
                changed[view] = true
            end
        end
        if not needs_maintenance then
            outcome.status = CommitPipeline.STATUS.UNCHANGED
            return outcome
        end
        for _, view in ipairs(MenuSchema.VIEWS) do
            if NativeWriter.recordNeedsMaterialization(view) then
                changed[view] = true
            end
        end
    end

    -- 4+5. Materialize EVERY changed view. Failures are recorded per view;
    -- canonical intent stays durable either way (Case B in P0-5 terms).
    for _, view in ipairs(MenuSchema.VIEWS) do
        if changed[view] then
            local reg
            if options.get_session then
                local s = options.get_session(view)
                reg = s and s.reg or nil
            elseif options.sessions then
                reg = options.sessions[view]
                    and options.sessions[view].reg or nil
            else
                local Registry = require("reorderingmenus_registry")
                local defaults = KoreaderAdapter.getDefaultOrder(view)
                if defaults then
                    local regs, provs, colls = KoreaderAdapter.collectLiveRegistrations(nil)
                    reg = Registry.buildFromData(defaults, regs or {}, provs or {}, colls or {})
                end
            end
            if not reg then
                -- Invariant: Every canonically changed view must either regenerate
                -- successfully or explicitly appear in failed_views (saved_needs_regeneration).
                outcome.failed_views[view] = "no registry available"
            else
                -- Fault containment (P0 fault matrix B6/B7/B8/B9): a raised
                -- error inside materialization must not escape the funnel.
                -- Canonical intent is ALREADY durable here; letting a raise
                -- through loses the structured Outcome AND skips every
                -- remaining changed view's derived write. Contain per view
                -- into failed_views so callers see saved_needs_regeneration.
                local ok_call, ok_write, err = pcall(materializeView, view, reg)
                if not ok_call then
                    if type(ok_write) ~= "string" then
                        ok_write = "derived write failed"
                            .. (ok_write ~= nil and (" (" .. tostring(ok_write) .. ")") or "")
                    end
                    outcome.failed_views[view] = ok_write
                elseif not ok_write then
                    outcome.failed_views[view] =
                        tostring(err or "derived write failed")
                end
            end
        end
    end

    -- 6. Live reload only where requested AND derived output succeeded.
    if options.reload_fn then
        for _, view in ipairs(options.reload or {}) do
            if not outcome.failed_views[view] then
                local ok_call, ok_reload, reload_err =
                    pcall(options.reload_fn, view)
                if not ok_call then
                    outcome.reload_failed[view] =
                        tostring(ok_reload or "reload failed")
                elseif not ok_reload then
                    outcome.reload_failed[view] =
                        tostring(reload_err or "reload failed")
                end
            end
        end
    end

    -- 7. Truthful status.
    local any_derived_failure = next(outcome.failed_views) ~= nil
    local any_reload_failure = next(outcome.reload_failed) ~= nil
    if any_derived_failure then
        outcome.status = CommitPipeline.STATUS.NEEDS_REGENERATION
        local failed_list = {}
        for fv in pairs(outcome.failed_views) do table.insert(failed_list, fv) end
        table.sort(failed_list)
        outcome.error = "saved_needs_regeneration:" .. table.concat(failed_list, ",")
    elseif any_reload_failure or not options.reload_fn then
        outcome.status = CommitPipeline.STATUS.SAVED_RESTART_REQUIRED
    else
        outcome.status = CommitPipeline.STATUS.SAVED
    end
    return outcome
end

return CommitPipeline

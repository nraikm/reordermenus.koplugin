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
    -- Canonical intent is durable but at least one derived view failed to
    -- regenerate. Restart (or next sync) regenerates from intent alone.
    NEEDS_REGENERATION = "saved_needs_regeneration",
    -- Everything durable succeeded; only the in-session live reload failed.
    NEEDS_RESTART = "saved_needs_restart",
    -- Fully applied.
    SAVED = "saved",
}

--- Materialize ONE view's committed section to its derived native file.
--- Emptied sections remove the file instead (stock rules flow untouched).
--- Returns ok(bool), err.
local function materializeView(view, reg)
    local section = IntentStore.view(view)
    local graph = Materializer.resolve(reg, section)
    local _, repaired = Validator.validate(graph, reg, section)

    -- An empty section means "back to stock": the sparse writer would emit
    -- nothing anyway, so remove the derived file explicitly and clear the
    -- checkpoint. This mirrors the historical resetOrder sequence but lives
    -- INSIDE the pipeline so reset-shaped transactions need no special path.
    local has_records = false
    for _, collection_name in ipairs(MenuSchema.VIEW_COLLECTIONS) do
        local c = section[collection_name]
        if type(c) == "table" and next(c) ~= nil then
            has_records = true
            break
        end
    end
    if not has_records and section.tab_order == nil then
        local ok_remove = KoreaderAdapter.removeNativeOrder(view)
        if not ok_remove then
            return false, "remove failed"
        end
        local ok_clear = NativeWriter.clearRecord(view)
        if not ok_clear then
            return false, "checkpoint clear failed"
        end
        KoreaderAdapter.invalidateNativeModuleCache()
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
    local outcome = {
        status = nil,
        committed = false,
        generation = IntentStore.generation(),
        view_generations = {},
        changed_views = {},
        failed_views = {},
        reload_failed = {},
        error = nil,
    }

    local changed = txn.changedViews()
        or { reader = false, filemanager = false }
    local any_changed = changed.reader or changed.filemanager

    -- Pre-commit sparse minimization for every changed view (the manager's
    -- minimizeIntent): the intent that COMMITS is the intent that persists.
    if options.prepare and any_changed then
        for _, view in ipairs(MenuSchema.VIEWS) do
            if changed[view] then
                local s = options.get_session and options.get_session(view)
                if s and s.reg then
                    options.prepare(txn, view, s.reg)
                end
            end
        end
    end

    -- 1+2+3. One canonical commit; the funnel reads back what actually
    -- persisted. A stale transaction gets exactly ONE record-level rebase:
    -- repeated races are reported, never retried indefinitely.
    local ok_commit, commit_err = txn:commit(true)
    if not ok_commit and commit_err == "stale_transaction" then
        logger.warn("ReorderingMenus: save raced another writer;",
            "rebasing staged changes once")
        local merged_sections = {}
        local merged_anchors = {}
        for _, view in ipairs(MenuSchema.VIEWS) do
            merged_sections[view] = txn:mergeSection(view)
            merged_anchors[view] = txn:mergeHiddenAnchors(view)
        end
        local rebased = IntentStore.openTransaction()
        txn:discard()
        for _, view in ipairs(MenuSchema.VIEWS) do
            rebased:setViewSection(view, merged_sections[view])
            rebased:setHiddenAnchors(view, merged_anchors[view])
        end
        -- Recompute changed views against the REBASED staging: the merge
        -- may have adopted canonical wholesale for untouched views.
        changed = rebased.changedViews()
        any_changed = changed.reader or changed.filemanager
        txn = rebased
        ok_commit, commit_err = txn:commit(true)
    end
    if not ok_commit then
        outcome.status = CommitPipeline.STATUS.UNCHANGED
        outcome.error = tostring(commit_err or "commit failed")
        return outcome
    end

    outcome.committed = true
    outcome.generation = IntentStore.generation()
    for _, view in ipairs(MenuSchema.VIEWS) do
        outcome.view_generations[view] = IntentStore.generation(view)
    end
    outcome.changed_views = changed

    if not any_changed then
        -- Semantic no-op: generations did not move, nothing to materialize.
        outcome.status = CommitPipeline.STATUS.UNCHANGED
        return outcome
    end

    -- 4+5. Materialize EVERY changed view. Failures are recorded per view;
    -- canonical intent stays durable either way (Case B in P0-5 terms).
    for _, view in ipairs(MenuSchema.VIEWS) do
        if changed[view] then
            local reg
            if options.get_session then
                local s = options.get_session(view)
                reg = s and s.reg or nil
            else
                reg = options.sessions and options.sessions[view]
                    and options.sessions[view].reg or nil
            end
            if not reg then
                outcome.failed_views[view] = "no registry available"
            else
                local ok_write, err = materializeView(view, reg)
                if not ok_write then
                    outcome.failed_views[view] = tostring(err or "write failed")
                end
            end
        end
    end

    -- 6. Live reload only where requested AND derived output succeeded.
    if options.reload_fn then
        for _, view in ipairs(options.reload or {}) do
            if not outcome.failed_views[view] then
                local ok_reload, reload_err = options.reload_fn(view)
                if not ok_reload then
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
    elseif any_reload_failure then
        outcome.status = CommitPipeline.STATUS.NEEDS_RESTART
    else
        outcome.status = CommitPipeline.STATUS.SAVED
    end
    return outcome
end

return CommitPipeline

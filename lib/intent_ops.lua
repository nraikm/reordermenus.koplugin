--[[--
intent_ops.lua — ONE shared semantic mutation vocabulary (Prompt 2 §1).

Editor changes, external native import, and preset application previously
answered the same questions with separate algorithms:

  relocation / order inference  stageList (classify_permutation) vs
                                native_writer (infer_list_change + block_move)
  membership                    reconcileMembership vs import claims loops vs
                                preset child loops
  visibility                    setItemHidden vs importDisabledChanges
  dividers                      stageList (sep_N) vs import (_ext_/_sep_) vs
                                preset (cap_/captured_) — three key schemes
  custom containers             createSubmenu vs import brand-new levels vs
                                preset recreation — three variants
  raw/opaque                    stageRawLevel vs import brand_new_levels

This module is the smallest abstraction that removes those duplicated
semantic decisions. It does NOT build a command framework: pure helpers that
take (view, txn, reg, ...) and stage intent records through the transaction's
typed writers, so every path shares:

  * ordering ownership rule (§2 — see setOrderingFromSequence)
  * divider replacement rule (§4 — see setDividerArrangement)
  * dormancy preservation (§6 — provider stamps, unknown ids as ordinary
    identities, never filtered because "unknown")

Ordering ownership rule (one rule for all paths):

  order_override[menu] = complete deliberate arrangement for that menu
    (item projection, no dividers). Governs order of ids it lists.
  position_override[id] = sparse single-item anchor for ids NOT governed by
    their effective parent's order_override. Anchors for ids omitted from an
    existing sequence are the SUPPORTED insertion mechanism into an
    already-reordered level (preview == saved == restarted).

  * Writing a bulk sequence clears position anchors ONLY for ids the sequence
    lists (they are subsumed — Transaction:setOrderOverride does this).
    Anchors for other ids survive (they are insertions, not contradictions).
  * Writing a single anchor never clears a bulk sequence for its level by
    itself; stageList replaces earlier anchors from the same menu because it
    receives the menu's COMPLETE arrangement (replace, not layer). Cross-menu
    moves strip the moved id from every sequence (it left those levels).
  * An anchor landing at its default slot is a durable no-op and is pruned;
    a sequence equal to its default item order is pruned to nil (resume flow).
  * Hidden / provider-absent / unknown ids are ordinary identities for
    ordering: their records persist (dormant) and reactivate on return.
    Minimization (§3) must not delete them because they are currently
    inapplicable — only explicit overwrite/reset/forget removes intent.

Divider rule (Prompts 2 §4 + 4 — one explicit per-menu state):

  no records              -> follow stock dividers (no override)
  zero sentinel           -> explicit EMPTY (suppress stock, render none)
  N normal records        -> explicit REPLACEMENT (stock suppressed, render
                             exactly those anchors in key-sorted order)
  only removal marks      -> stock flow MINUS the marked slots (one mark
                             suppresses one stock occurrence anchored there)

  Compared against DEFAULT anchors so resuming stock stays record-free.
  Single-stock-slot deletions write removal marks (minimal, exact); all other
  non-default arrangements become complete replacements. Keys are
  deterministic per menu (`<menu>__sep_<i>`, `<menu>__nosep_<i>`) on every
  writer path (editor, import, presets); readers are key-agnostic.
  Statement rule (whose staged list authors dividers): divider records are
  written only when the staged list carries divider rows, or when a
  divider-free staged list matches the current AND default items (explicit
  clear). Items-only bulk sorts never freeze divider-free snapshots.
--]]

local Materializer = require("lib.materializer")
local MenuSchema = require("lib.menu_schema")
local SemanticDiff = require("lib.semantic_diff")

local IntentOps = {}

local SEPARATOR_ID = MenuSchema.SEPARATOR_ID

function IntentOps.providerOf(reg, id)
    if reg == nil then return nil end
    local node = reg.nodes and reg.nodes[id] or nil
    return node and node.provider or nil
end

local function separatorAnchorsOf(list)
    return SemanticDiff.separator_anchors(type(list) == "table" and list or {})
end

IntentOps.separatorAnchorsOf = separatorAnchorsOf

function IntentOps.defaultAnchors(reg, menu_id)
    local def_list = reg and reg.menus and reg.menus[menu_id]
        and reg.menus[menu_id].list or nil
    if type(def_list) ~= "table" then return {} end
    return separatorAnchorsOf(def_list)
end

-- -------------------------------------------------------------------------
-- Ordering: one classification, one record shape for all paths.
-- -------------------------------------------------------------------------
-- baseline_item_seq : item-only sequence to diff against (editor: default
--   derivation; import: last emission's item projection). Caller decides the
--   baseline; the CLASSIFICATION (one relocation vs bulk vs noop) and the
--   RECORD SHAPE (anchor vs sequence vs nil) are shared.
-- observed_item_seq : item-only proposed sequence (separators stripped).
-- Returns "anchor" | "sequence" | "noop" | "pure_membership" plus detail, or
-- nil + err on structural invalidity. Stages through txn.
--
-- Complete-arrangement replacement (stageList): earlier same-menu anchors are
-- dropped so successive drags stay invertible — EXCEPT anchors that are
-- currently inapplicable-but-durable (Prompt 2 §3): an anchor whose id is
-- hidden / provider-absent / unknown, whose provider stamp is dormant, or
-- whose after/before target is hidden / absent / unknown, survives an
-- unrelated complete-arrangement save and reactivates on return. Only an
-- explicit overwrite of that same id (it is the relocation's move.item, or
-- it is listed in a new bulk sequence, or clearItem/reset/forget) removes
-- it. In particular a no-op save (UNCHANGED) or a membership-only save
-- (PURE_*) never deletes revivable anchors merely because their rows are
-- invisible right now.
local function anchorInvolvesDormant(reg, section, id, record)
    if Materializer.hiddenApplies(reg, section, id) then return true end
    local node = reg.nodes and reg.nodes[id] or nil
    local is_custom = type(section.custom_menus) == "table"
        and section.custom_menus[id] ~= nil
    if not node and not is_custom then return true end -- unknown id
    if type(record) == "table" and record.provider ~= nil then
        local live = node and node.provider or nil
        if live ~= record.provider then return true end -- dormant stamp
    end
    local target = type(record) == "table"
        and (record.after ~= nil and record.after or record.before) or nil
    if type(target) == "string" then
        if Materializer.hiddenApplies(reg, section, target) then return true end
        local tnode = reg.nodes and reg.nodes[target] or nil
        local tcustom = type(section.custom_menus) == "table"
            and section.custom_menus[target] ~= nil
        if not tnode and not tcustom then return true end -- absent target
    end
    return false
end

function IntentOps.setOrderingFromSequence(view, txn, reg, menu_id,
        baseline_item_seq, observed_item_seq)
    local descriptors = {}
    local provider_of = function(id) return IntentOps.providerOf(reg, id) end
    for _, id in ipairs(observed_item_seq or {}) do
        descriptors[id] = { provider = provider_of(id) }
    end
    local classification, cls_err = SemanticDiff.classify_permutation(
        baseline_item_seq or {}, observed_item_seq or {},
        { separator_aware = false, descriptors = descriptors })
    if cls_err then return nil, cls_err end
    local kind = classification.kind
    -- Complete-arrangement replacement: drop earlier same-menu anchors FIRST
    -- (so the branches below encode exactly the final arrangement), but keep
    -- inapplicable-but-durable ones plus ids this call explicitly rewrites
    -- (the relocation target / new bulk members — setOrderOverride clears
    -- listed ids itself, which is the explicit overwrite for bulks).
    do
        local rewritten = {}
        if kind == SemanticDiff.KIND.ONE_RELOCATION
                and type(classification.move) == "table" then
            rewritten[classification.move.item] = true
        elseif kind ~= SemanticDiff.KIND.UNCHANGED
                and kind ~= SemanticDiff.KIND.PURE_ADDITION
                and kind ~= SemanticDiff.KIND.PURE_REMOVAL then
            for _, id in ipairs(classification.sequence or observed_item_seq or {}) do
                rewritten[id] = true
            end
        end
        local section = txn:view(view)
        for id, record in pairs(section.position_override or {}) do
            if not rewritten[id]
                    and Materializer.effectiveParent(reg, section, id) == menu_id
                    and not anchorInvolvesDormant(reg, section, id, record) then
                txn:setPositionOverride(view, id, nil)
            end
        end
    end
    if kind == SemanticDiff.KIND.ONE_RELOCATION then
        local move = classification.move
        local noop_move = SemanticDiff.is_noop_move(baseline_item_seq or {}, move)
        txn:setOrderOverride(view, menu_id, nil)
        if noop_move then
            txn:setPositionOverride(view, move.item, nil)
            return "noop", { move = move }
        end
        -- Ambiguous shared ids (P0-5): refuse new anchor pins while contested.
        if Materializer.isAmbiguous(reg, move.item) then
            return "ambiguous", { move = move }
        end
        txn:setPositionOverride(view, move.item, {
            after = move.type == "move_before" and false or move.after,
            before = move.type == "move_before" and move.before or nil,
            provider = move.provider or provider_of(move.item),
        })
        return "anchor", { move = move }
    elseif kind == SemanticDiff.KIND.UNCHANGED then
        txn:setOrderOverride(view, menu_id, nil)
        return "noop", {}
    elseif kind == SemanticDiff.KIND.PURE_ADDITION
            or kind == SemanticDiff.KIND.PURE_REMOVAL then
        -- Ordering-neutral: membership owns these ids. Never freeze a
        -- sequence for world state; drop any stale freeze beside reconciled
        -- membership.
        txn:setOrderOverride(view, menu_id, nil)
        return "pure_membership", classification
    else
        -- COMPLEX_PERMUTATION: one era-stamped curated sequence.
        local seq = classification.sequence or observed_item_seq or {}
        local eras = {}
        for _, id in ipairs(seq) do eras[id] = provider_of(id) end
        txn:setOrderOverride(view, menu_id, seq, eras)
        return "sequence", { sequence = seq }
    end
end

-- Single-item insertion anchor (cross-menu moves, external additions).
-- after=false means list head. Provider-stamped for dormancy.
-- Ambiguous shared ids (P0-5) refuse new pins while identity is contested.
function IntentOps.setInsertionAnchor(view, txn, reg, id, after)
    if Materializer.isAmbiguous(reg, id) then return false, "ambiguous" end
    txn:setPositionOverride(view, id, {
        after = after,
        provider = IntentOps.providerOf(reg, id),
    })
    return true
end

-- Strip one id from every bulk sequence containing it (single-parent
-- discipline on cross-menu moves). Its destination membership comes from its
-- parent_override + optional insertion anchor alone.
function IntentOps.stripItemFromSequences(view, txn, id)
    local section = txn:view(view)
    local touched = {}
    for menu_id in pairs(section.order_override or {}) do
        touched[#touched + 1] = menu_id
    end
    table.sort(touched, function(a, b) return tostring(a) < tostring(b) end)
    for _, menu_id in ipairs(touched) do
        local override = section.order_override[menu_id]
        if type(override) == "table" and type(override.entries) == "table" then
            local kept = {}
            for _, entry in ipairs(override.entries) do
                if not MenuSchema.isSeparatorEntry(entry) and entry.id ~= id then
                    kept[#kept + 1] = entry
                end
            end
            if #kept > 0 then
                section.order_override[menu_id] = { entries = kept }
            else
                txn:setOrderOverride(view, menu_id, nil)
            end
        end
    end
end

-- -------------------------------------------------------------------------
-- Membership / parent: one gate for all paths.
-- -------------------------------------------------------------------------
-- Sets parent_override through the centralized Placement gate. Structural
-- violations (tab_nesting / non_tab_in_bar / self / malformed) are refused
-- (false + reason); vanished containers (unknown_parent) are RECORDED for
-- dormancy — the row cascades to disabled and reappears when its home
-- returns. Clearing (parent=nil) removes the record.
function IntentOps.setMembership(view, txn, reg, id, parent)
    -- Ambiguous shared ids (P0-5): no new provider-specific pins while
    -- identity is contested. Clearing (parent=nil) is always allowed.
    if parent ~= nil and Materializer.isAmbiguous(reg, id) then
        return false, "ambiguous"
    end
    local Placement
    do
        local ok, mod = pcall(require, "lib.placement")
        if ok then Placement = mod end
    end
    if parent == nil then
        txn:setParentOverride(view, id, nil)
        return true
    end
    if Placement and Placement.canPlace then
        local section_now = txn:view(view)
        local ok_place, reason = Placement.canPlace(reg, section_now, id, parent)
        if not ok_place then
            if reason == Placement.REASONS.UNKNOWN_PARENT then
                -- Dormant: record verbatim.
            else
                return false, reason
            end
        end
    end
    -- HEAD semantics preserved green: ALWAYS stage the record (even when
    -- parent equals the provider default). Sparseness (dropping
    -- default-redundant records) happens in minimizeIntent on save (proven
    -- no-op prune), not here. Immediate clearing here made no-op saves look
    -- dirty (N3 generation churn) and dropped hint-home restores (R) by
    -- conflating staging with minimization. Callers that need sparse-noop
    -- (already correct, no record) still no-op via the txn writer when the
    -- staged value equals canonical? No — staging always writes; minimize
    -- prunes before commit. Matches historical moveItemToMenu/import behavior
    -- (always setParentOverride when conditions met).
    txn:setParentOverride(view, id, {
        provider = IntentOps.providerOf(reg, id),
        parent = parent,
    })
    return true
end

-- Resolve cross-parent claims with ONE policy everywhere: prefer a
-- non-default claimant (customized destination wins); ties break
-- alphabetically; a menu never claims itself. Returns { [id] = chosen }.
function IntentOps.resolveMembershipClaims(reg, claims)
    local Registry = require("lib.registry")
    local chosen_by_id = {}
    local ids = {}
    for id in pairs(claims or {}) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
    for _, id in ipairs(ids) do
        local claimants = claims[id]
        if type(claimants) == "table" then
            local sorted = {}
            for _, m in ipairs(claimants) do sorted[#sorted + 1] = m end
            table.sort(sorted, function(a, b) return tostring(a) < tostring(b) end)
            local node = reg and reg.nodes and reg.nodes[id] or nil
            local default_parent = node and node.default_parent or nil
            if default_parent == nil and reg ~= nil then
                default_parent = Registry.getDefaultParent(reg, id)
            end
            local non_default = {}
            for _, m in ipairs(sorted) do
                if m ~= default_parent and m ~= id then
                    non_default[#non_default + 1] = m
                end
            end
            local valid = {}
            for _, m in ipairs(sorted) do
                if m ~= id then valid[#valid + 1] = m end
            end
            chosen_by_id[id] = non_default[1] or valid[1] or sorted[1]
        end
    end
    return chosen_by_id
end

-- -------------------------------------------------------------------------
-- Visibility: one record shape for all paths.
-- -------------------------------------------------------------------------
function IntentOps.setVisibility(view, txn, reg, id, hidden, origin)
    -- Ambiguous shared ids (P0-5): hiding the shared row would hide both
    -- providers' rows; refuse new hide pins while contested. Unhide (clear)
    -- is always allowed.
    if hidden and Materializer.isAmbiguous(reg, id) then
        return false, "ambiguous"
    end
    if hidden then
        local existing = txn:getHidden(view, id)
        txn:setHidden(view, id, {
            provider = IntentOps.providerOf(reg, id),
            origin = origin,
            -- Re-hiding preserves the existing ordinal (hide-sequence
            -- stability); Transaction:setHidden implements this when ordinal
            -- is nil and a record already exists.
            ordinal = existing and existing.ordinal or nil,
        })
    else
        txn:setHidden(view, id, nil)
    end
end

-- -------------------------------------------------------------------------
-- Dividers: one explicit per-menu state for all paths (Prompts 2 §4 + 4).
--   no records          -> follow stock dividers (no override)
--   zero sentinel       -> explicit EMPTY (suppress stock, render none)
--   >=1 normal records  -> explicit REPLACEMENT (stock suppressed entirely)
--   only removal marks  -> stock flow MINUS the marked slots
-- Compared against DEFAULT anchors so resuming stock stays record-free.
-- A pure single-stock-slot deletion (observed is default minus some slots,
-- order preserved, no additions) writes one { removed = true } marker per
-- missing occurrence — minimal (no litter) and exact (no duplication).
-- Anything else non-default becomes a complete replacement. Markers key
-- slots by the unconditional default-predecessor chain, which never depends
-- on visibility, so hidden members neither confuse matching nor need a
-- replacement fallback.
-- -------------------------------------------------------------------------
local function isOrderedSubsequence(small, big)
    local j = 1
    for i = 1, #big do
        if j <= #small and big[i] == small[j] then j = j + 1 end
    end
    return j > #small
end

function IntentOps.setDividerArrangement(view, txn, reg, menu_id, observed_anchors)
    observed_anchors = observed_anchors or {}
    local section = txn:view(view)
    local default_anchors = IntentOps.defaultAnchors(reg, menu_id)
    local function clearMenu()
        for key in pairs(section.separators or {}) do
            if section.separators[key]
                    and section.separators[key].parent == menu_id then
                section.separators[key] = nil
            end
        end
    end
    if #observed_anchors == 0 then
        clearMenu()
        if #default_anchors > 0 then
            txn:setSeparator(view, Materializer.explicitZeroKey(menu_id), {
                parent = menu_id,
                zero_dividers = true,
            })
        end
        return "empty"
    end
    local same = #observed_anchors == #default_anchors
    if same then
        for i = 1, #observed_anchors do
            if observed_anchors[i] ~= default_anchors[i] then same = false break end
        end
    end
    if same then
        clearMenu()
        return "default"
    end
    -- Pure-removal fast path: observed is default minus some slots, order
    -- preserved, nothing added or reordered. Multiset difference per anchor
    -- (consecutive duplicate stock dividers share one anchor; one mark
    -- suppresses one occurrence).
    if #observed_anchors < #default_anchors
            and isOrderedSubsequence(observed_anchors, default_anchors) then
        local want = {}
        for _, a in ipairs(observed_anchors) do
            local k = tostring(a)
            want[k] = (want[k] or 0) + 1
        end
        clearMenu()
        local idx = 0
        for _, a in ipairs(default_anchors) do
            local k = tostring(a)
            if (want[k] or 0) > 0 then
                want[k] = want[k] - 1
            else
                idx = idx + 1
                txn:setSeparator(view,
                    string.format("%s__nosep_%d", menu_id, idx), {
                        parent = menu_id,
                        after = a,
                        removed = true,
                    })
            end
        end
        return "suppression"
    end
    clearMenu()
    for i, anchor in ipairs(observed_anchors) do
        txn:setSeparator(view, string.format("%s__sep_%d", menu_id, i), {
            parent = menu_id,
            after = anchor,
        })
    end
    return "replacement"
end

-- -------------------------------------------------------------------------
-- Custom containers + opaque fragments.
-- -------------------------------------------------------------------------
function IntentOps.defineCustomContainer(view, txn, id, title, parent)
    txn:setCustomMenu(view, id, { title = title })
    if type(parent) == "string" then
        txn:setParentOverride(view, id, { provider = nil, parent = parent })
    end
end

function IntentOps.preserveOpaqueLevel(view, txn, menu_id, list)
    -- Raw owns its level exclusively (Transaction:setRawOverride clears the
    -- level's semantic ordering records by construction).
    txn:setRawOverride(view, menu_id, list)
end

return IntentOps

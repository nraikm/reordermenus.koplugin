--[[--
semantic_diff.lua — minimal intent inference for external native edits.

When a user hand-edits a native menu-order file, the observed change should
become the MINIMAL user action, not a frozen snapshot of the whole list:

    old: A B C D E      manual edit: A D B C E
    => move D before B  (one position_override)

not "order_override = [A D B C E]", which would shadow every future KOReader
reorder of untouched neighbours.

Production inference uses classify_permutation via IntentOps. Historical
lcs / infer_list_change / resolve_claims entrypoints remain available through
semantic_diff_legacy; their different vocabularies stay out of this core.
--]]

local MenuSchema = require("lib.menu_schema")

local SemanticDiff = {}

local SEPARATOR_ID = MenuSchema.SEPARATOR_ID
SemanticDiff.SEPARATOR_ID = SEPARATOR_ID

-- ===========================================================================
-- PURE SEMANTIC ORDERING LAYER (schema-independent, 2026-08-24)
-- ===========================================================================
-- Everything below consumes ORDINARY SEQUENCES (arrays of string ids) and
-- returns SEMANTIC RESULTS. Nothing here touches IntentStore, the
-- materializer, the filesystem, or canonical intent storage. Integration
-- maps these results onto whatever record shapes the schema defines.
--
-- Options understood by every entry point (`opts`):
--   separator_aware (bool, default false)
--       true  = SEPARATOR_ID tokens are POSITIONAL DIVIDERS: any number of
--               them may appear, they never count as item identity, and
--               ordering questions are answered on the item projection while
--               divider layout is reported separately.
--       false = the separator token is an ordinary id (duplicated tokens are
--               a duplicate-identity error, like any other id).
--   descriptors (map id -> { provider = ... , ... })
--       Optional provider-aware metadata. Algorithms never REQUIRE it; when
--       present, the provider stamp is copied onto produced operations so
--       callers can persist era information without re-deriving it. Ids
--       absent from descriptors (dormant/unavailable rows) participate in
--       every algorithm as ordinary identities.
--
-- Error convention: structural problems return `nil, err` where err is a
-- plain table { code = ..., ... }. Codes: "not_a_sequence",
-- "non_string_identity", "duplicate_identities" (with sorted `duplicates`),
-- "missing_anchor", "bad_arguments", "bad_operation",
-- "unknown_operation_type".
-- ---------------------------------------------------------------------------

SemanticDiff.KIND = {
    UNCHANGED = "unchanged",
    ONE_RELOCATION = "one_relocation",
    PURE_ADDITION = "pure_addition",
    PURE_REMOVAL = "pure_removal",
    COMPLEX = "complex_permutation",
}

SemanticDiff.OP_TYPE = {
    MOVE_AFTER = "move_after",       -- { after = id } ; after=false = list head
    MOVE_BEFORE = "move_before",     -- { before = id } ; before=false = list head
    PARENT_ONLY = "parent_only",     -- append at end of parent's children
}

-- Normalize an input sequence: validates array-ness and identity uniqueness.
-- Returns (normalized_copy, nil) or (nil, err). Separators are kept
-- positionally in separator_aware mode and exempt from duplicate checks;
-- elsewhere they are ordinary ids.
function SemanticDiff.normalize_sequence(seq, opts)
    opts = opts or {}
    if type(seq) ~= "table" then return nil, { code = "not_a_sequence" } end
    local aware = opts.separator_aware == true
    local out, seen, dupes = {}, {}, {}
    for _, id in ipairs(seq) do
        if type(id) ~= "string" then
            return nil, { code = "non_string_identity", detail = tostring(id) }
        end
        if aware and id == SEPARATOR_ID then
            out[#out + 1] = id
        else
            if seen[id] then
                dupes[id] = true
            else
                seen[id] = true
                out[#out + 1] = id
            end
        end
    end
    if next(dupes) then
        local list = {}
        for id in pairs(dupes) do list[#list + 1] = id end
        table.sort(list)
        return nil, { code = "duplicate_identities", duplicates = list }
    end
    return out
end

-- Item projection: drop divider tokens (harmless when none present).
function SemanticDiff.items_projection(seq)
    local out = {}
    for _, id in ipairs(seq or {}) do
        if id ~= SEPARATOR_ID then out[#out + 1] = id end
    end
    return out
end

-- Divider anchors: one entry per separator, valued at its preceding item id
-- (false when the divider leads the list). Deterministic array walk.
function SemanticDiff.separator_anchors(seq)
    local anchors, previous = {}, false
    for _, id in ipairs(seq or {}) do
        if id == SEPARATOR_ID then
            anchors[#anchors + 1] = previous
        else
            previous = id
        end
    end
    return anchors
end

function SemanticDiff.sequence_equal(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

function SemanticDiff.separator_layout_equal(a, b)
    local xa, xb = SemanticDiff.separator_anchors(a), SemanticDiff.separator_anchors(b)
    return SemanticDiff.sequence_equal(xa, xb)
end

local function normalize_pair(a, b, opts)
    local na, ea = SemanticDiff.normalize_sequence(a, opts)
    if not na then return nil, nil, ea end
    local nb, eb = SemanticDiff.normalize_sequence(b, opts)
    if not nb then return nil, nil, eb end
    return na, nb, nil
end

-- Membership diff of the ITEM projections. `added` follows the proposed
-- order, `removed` follows the baseline order (never hash order).
function SemanticDiff.multiset_diff(baseline, proposed, opts)
    local nb, np, err = normalize_pair(baseline, proposed, opts)
    if err then return nil, err end
    local ba, pr = SemanticDiff.items_projection(nb), SemanticDiff.items_projection(np)
    local counts = {}
    for _, id in ipairs(ba) do counts[id] = (counts[id] or 0) + 1 end
    local added = {}
    for _, id in ipairs(pr) do
        local c = counts[id]
        if c and c > 0 then
            counts[id] = c - 1
        else
            added[#added + 1] = id
        end
    end
    local removed = {}
    for _, id in ipairs(ba) do
        if counts[id] and counts[id] > 0 then
            removed[#removed + 1] = id
            counts[id] = counts[id] - 1
        end
    end
    return { added = added, removed = removed }, nil
end

function SemanticDiff.is_subsequence(small, big)
    local j = 1
    for i = 1, #big do
        if big[i] == small[j] then j = j + 1 end
    end
    return j > #small
end

-- -------------------------------------------------------------------------
-- ONE AUTHORITATIVE RELOCATION DETECTION
-- -------------------------------------------------------------------------
-- Answers: "did sequence B result from moving exactly one logical entry of
-- sequence A?" Analytically, with ZERO materializations: B minus some entry
-- X must equal A minus the same entry. Every X satisfying that is a valid
-- interpretation; ambiguous cases (adjacent transpositions admit two) are
-- settled by the CANONICAL CHOICE RULE below so equivalent final
-- arrangements always yield equivalent semantic placement and drag
-- direction/history can never leak into serialization:
--
--   1. smallest travel distance |from_index - to_index|;
--   2. ties -> smallest baseline index;
--   3. still tied -> lexicographically smallest id.
--
-- Anchor emission policy (canonical anchor selection):
--   * predecessor anchor preferred: { type="move_after", after = pred };
--   * landing at the head of the list: { type="move_after", after = false }
--     (absolute head form, matching the historical anchor serialization);
--   * opt-in alternate style opts.anchor_style == "successor" emits
--     { type="move_before", before = succ } for head landings instead;
--   * parent-only form exists in the vocabulary for caller-side use but is
--     never emitted by detection (a detected move always has an anchor or is
--     the head form).
--
-- Diagnostics carry indexes for LOGGING only; the semantic payload is
-- `move` alone. Indexes must never be persisted.
-- ---------------------------------------------------------------------------

local function relocation_candidates(a, b)
    local cands = {}
    for to_index = 1, #b do
        local item = b[to_index]
        local rest_b = {}
        for i = 1, #b do
            if i ~= to_index then rest_b[#rest_b + 1] = b[i] end
        end
        local rest_a, taken = {}, false
        for i = 1, #a do
            if not taken and a[i] == item then
                taken = true
            else
                rest_a[#rest_a + 1] = a[i]
            end
        end
        if taken and SemanticDiff.sequence_equal(rest_a, rest_b) then
            local from_index = 1
            for i = 1, #a do
                if a[i] == item then from_index = i break end
            end
            cands[#cands + 1] = {
                item = item,
                from_index = from_index,
                to_index = to_index,
                distance = math.abs(from_index - to_index),
            }
        end
    end
    return cands
end

local function pick_canonical_candidate(cands)
    local best
    for _, c in ipairs(cands) do
        if not best
                or c.distance < best.distance
                or (c.distance == best.distance and c.from_index < best.from_index)
                or (c.distance == best.distance and c.from_index == best.from_index
                        and c.item < best.item) then
            best = c
        end
    end
    return best
end

local function build_move_op(candidate, proposed, opts)
    opts = opts or {}
    local op
    if candidate.to_index > 1 then
        op = { type = "move_after", item = candidate.item,
               after = proposed[candidate.to_index - 1] }
    elseif candidate.to_index <= #proposed then
        if opts.anchor_style == "successor" and candidate.to_index < #proposed then
            op = { type = "move_before", item = candidate.item,
                   before = proposed[candidate.to_index + 1] }
        else
            op = { type = "move_after", item = candidate.item, after = false }
        end
    else
        op = { type = "parent_only", item = candidate.item }
    end
    local descriptors = opts.descriptors
    if type(descriptors) == "table" then
        local d = descriptors[candidate.item]
        if type(d) == "table" and d.provider ~= nil then
            op.provider = d.provider
        end
    end
    return op
end

-- THE single-relocation oracle. Returns (detection, nil) or (nil, err);
-- detection is nil (without error) whenever B is NOT a one-entry move of A
-- (equal sequences, membership differences, multi-entry reshuffles).
function SemanticDiff.detect_relocation(baseline, proposed, opts)
    local nb, np, err = normalize_pair(baseline, proposed, opts)
    if err then return nil, err end
    local ba, pr = SemanticDiff.items_projection(nb), SemanticDiff.items_projection(np)
    if #ba ~= #pr then return nil, nil end
    if SemanticDiff.sequence_equal(ba, pr) then return nil, nil end
    if not SemanticDiff.same_multiset_items(ba, pr) then return nil, nil end
    local cands = relocation_candidates(ba, pr)
    if #cands == 0 then return nil, nil end
    local best = pick_canonical_candidate(cands)
    return {
        move = build_move_op(best, pr, opts),
        diagnostics = {
            baseline_index = best.from_index,
            proposed_index = best.to_index,
            distance = best.distance,
            candidates = #cands,
        },
    }, nil
end

function SemanticDiff.same_multiset_items(a, b)
    if #a ~= #b then return false end
    local counts = {}
    for _, id in ipairs(a) do counts[id] = (counts[id] or 0) + 1 end
    for _, id in ipairs(b) do
        local c = counts[id]
        if not c or c == 0 then return false end
        counts[id] = c - 1
    end
    return true
end

-- Apply a semantic placement operation to a sequence (pure). Works for
-- relocations (item present) and insertions (item absent). Anchors are
-- STRICT: a missing anchor is an error, never a silent fallback.
-- Accepts a bare op or a detection/classification wrapper carrying `.move`.
function SemanticDiff.apply_operation(seq, op)
    if type(op) == "table" and type(op.move) == "table" then op = op.move end
    if type(seq) ~= "table" or type(op) ~= "table" then
        return nil, { code = "bad_arguments" }
    end
    local item = op.item
    if type(item) ~= "string" then return nil, { code = "bad_operation" } end
    local out, removed = {}, false
    for _, id in ipairs(seq) do
        if not removed and id == item then
            removed = true
        else
            out[#out + 1] = id
        end
    end
    local t = op.type
    if t == "move_after" then
        local after = op.after
        if after == false or after == nil then
            table.insert(out, 1, item)
        else
            local at
            for i, id in ipairs(out) do
                if id == after then at = i break end
            end
            if not at then return nil, { code = "missing_anchor", anchor = after } end
            table.insert(out, at + 1, item)
        end
    elseif t == "move_before" then
        local before = op.before
        if before == nil then return nil, { code = "bad_operation" } end
        if before == false then
            table.insert(out, 1, item)
        else
            local at
            for i, id in ipairs(out) do
                if id == before then at = i break end
            end
            if not at then return nil, { code = "missing_anchor", anchor = before } end
            table.insert(out, at, item)
        end
    elseif t == "parent_only" then
        out[#out + 1] = item
    else
        return nil, { code = "unknown_operation_type", detail = tostring(t) }
    end
    return out
end

-- -------------------------------------------------------------------------
-- CLASSIFICATION: unchanged / one relocation / bulk permutation
-- -------------------------------------------------------------------------
-- The one call `stageList` needs. Replaces candidate-by-candidate
-- hypothetical materialization with a single analytical decision:
--
--   SemanticDiff.classify_permutation(baseline, proposed)
--     -> { kind = "unchanged", ... }            no intent required
--     -> { kind = "one_relocation", move = op } sparse representation
--     -> { kind = "pure_addition" / "pure_removal", added/removed }
--     -> { kind = "complex_permutation", sequence = items }
--
-- `sequence` is always the ITEM projection (dividers reported separately),
-- so a complex classification never freezes divider layout into the record.
-- Dividers are compared via separator_layout_equal and reported in
-- `separators_changed`; callers combine that with their divider records
-- independently of the sequence form.
--
-- opts.noop_baseline (optional): an alternative sequence (e.g. the caller's
-- CURRENT effective derivation, as opposed to pure default). When provided,
-- "unchanged" is also returned when proposed equals it — the manager's
-- away-then-back case collapses to a no-op without probing.
-- -------------------------------------------------------------------------

function SemanticDiff.classify_permutation(baseline, proposed, opts)
    local nb, np, err = normalize_pair(baseline, proposed, opts)
    if err then return nil, err end
    opts = opts or {}
    local ba, pr = SemanticDiff.items_projection(nb), SemanticDiff.items_projection(np)

    if #ba == #pr and SemanticDiff.sequence_equal(ba, pr) then
        return {
            kind = "unchanged",
            separators_changed = not SemanticDiff.separator_layout_equal(nb, np),
        }, nil
    end

    local noop = opts.noop_baseline
    if type(noop) == "table" then
        local nn, nerr = SemanticDiff.normalize_sequence(noop, opts)
        if nerr then return nil, nerr end
        if SemanticDiff.sequence_equal(SemanticDiff.items_projection(nn), pr) then
            return {
                kind = "unchanged",
                separators_changed = not SemanticDiff.separator_layout_equal(np, nn),
                matches_noop_baseline = true,
            }, nil
        end
    end

    local changes, _ = SemanticDiff.multiset_diff(nb, np, opts)
    local membership_changed = #changes.added > 0 or #changes.removed > 0

    if not membership_changed then
        local detection = SemanticDiff.detect_relocation(ba, pr, opts)
        if detection then
            return { kind = "one_relocation", move = detection.move,
                     diagnostics = detection.diagnostics }, nil
        end
    elseif #changes.added > 0 and #changes.removed == 0
            and SemanticDiff.is_subsequence(ba, pr) then
        -- Pure insertion: incumbents keep relative order -> no ORDERING info;
        -- membership reconciliation owns these ids.
        return { kind = "pure_addition", added = changes.added,
                 separators_changed = not SemanticDiff.separator_layout_equal(nb, np) },
            nil
    elseif #changes.removed > 0 and #changes.added == 0
            and SemanticDiff.is_subsequence(pr, ba) then
        return { kind = "pure_removal", removed = changes.removed,
                 separators_changed = not SemanticDiff.separator_layout_equal(nb, np) },
            nil
    end

    return { kind = "complex_permutation", sequence = pr,
             separators_changed = not SemanticDiff.separator_layout_equal(nb, np) },
        nil
end

-- -------------------------------------------------------------------------
-- ORDERING EQUIVALENCE
-- -------------------------------------------------------------------------
-- Two distinct questions that must never be conflated:
--
--   orders_equivalent(a, b)      APPLICABLE order: do both sequences present
--                                the same rows in the same effective order?
--                                Dormant/unavailable ids are NOT special here
--                                — they are ordinary identities wherever the
--                                CALLER drew the sequence from; equivalence of
--                                applicable order is defined on the sequences
--                                as given (callers pass live projections when
--                                asking about live applicability).
--   canonical_records_equal()    RECORD equality: same item multiset, same
--                                order, same divider layout, same provider
--                                stamps. This is the identity for "does this
--                                stored record already say this?" decisions.
-- -------------------------------------------------------------------------

function SemanticDiff.orders_equivalent(a, b, opts)
    local na, nb_, err = normalize_pair(a, b, opts)
    if err then return nil, err end
    local ia, ib = SemanticDiff.items_projection(na), SemanticDiff.items_projection(nb_)
    if not SemanticDiff.sequence_equal(ia, ib) then return false, nil end
    -- Applicable-order question: identical item order is equivalent regardless
    -- of divider layout (dividers are presentation, carried separately).
    return true, nil
end

function SemanticDiff.canonical_records_equal(a, b, opts)
    local na, nb_, err = normalize_pair(a, b, opts)
    if err then return nil, err end
    if not SemanticDiff.sequence_equal(na, nb_) then return false, nil end
    local da = type(opts) == "table" and opts.descriptors_a or nil
    local db = type(opts) == "table" and opts.descriptors_b or nil
    if da or db then
        for _, id in ipairs(na) do
            local pa = da and type(da[id]) == "table" and da[id].provider or nil
            local pb = db and type(db[id]) == "table" and db[id].provider or nil
            if pa ~= pb then return false, nil end
        end
    end
    return true, nil
end

-- Sequence equality IGNORING dormant entries: two records describe the same
-- LIVE arrangement when their projections onto available ids match, even if
-- one still carries tombstones for currently-unavailable ids. `is_available`
-- maps id -> boolean; ids absent from the map count as available (so plain
-- callers get plain equality).
function SemanticDiff.live_orders_equivalent(a, b, is_available, opts)
    local na, nb_, err = normalize_pair(a, b, opts)
    if err then return nil, err end
    local function live(seq)
        local out = {}
        for _, id in ipairs(seq) do
            if id ~= SEPARATOR_ID
                    and (is_available == nil or is_available[id] ~= false) then
                out[#out + 1] = id
            end
        end
        return out
    end
    return SemanticDiff.sequence_equal(live(na), live(nb_)), nil
end

-- -------------------------------------------------------------------------
-- MUTATION-BOUNDARY NO-OP DETECTION
-- -------------------------------------------------------------------------
-- Cheap predicates the minimizer composes. None of them resolve anything.
-- -------------------------------------------------------------------------

-- Move to same location: applying `op` to `baseline` reproduces `baseline`.
function SemanticDiff.is_noop_move(baseline, op, opts)
    local nb, err = SemanticDiff.normalize_sequence(baseline, opts)
    if err then return nil, err end
    local applied, aerr = SemanticDiff.apply_operation(nb, op)
    if aerr then return false, nil end
    return SemanticDiff.sequence_equal(applied, nb), nil
end

-- Preserve the historical API for migration callers and diagnostic probes.
local Legacy = require("lib.semantic_diff_legacy")
SemanticDiff.lcs = Legacy.lcs
function SemanticDiff.infer_list_change(old, new)
    return Legacy.infer_list_change(old, new, SemanticDiff)
end
SemanticDiff.resolve_claims = Legacy.resolve_claims

return SemanticDiff

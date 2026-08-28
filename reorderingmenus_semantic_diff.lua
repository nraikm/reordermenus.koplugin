--[[--
semantic_diff.lua — minimal intent inference for external native edits.

When a user hand-edits a native menu-order file, the observed change should
become the MINIMAL user action, not a frozen snapshot of the whole list:

    old: A B C D E      manual edit: A D B C E
    => move D before B  (one position_override)

not "order_override = [A D B C E]", which would shadow every future KOReader
reorder of untouched neighbours.

Algorithms (all deterministic; ties break on the lexicographically smallest
id, never on pairs() iteration order):

  lcs(a, b)          - longest common subsequence via dynamic programming
  diff_sequences     - LCS-based element diff: kept / removed / added
  infer_list_change  - classifies one menu's old->new as a minimal action:
                         identical            -> nil (no information)
                         single_move          -> { id, after } anchor
                         reversal             -> { reversed = true } (bulk)
                         block_move           -> { block = ids, after }
                         unrepresentable      -> full sequence (explicit bulk)
  infer_membership   - cross-parent claims -> per-id destination choice with
                         customized-destination-wins and alphabetical tie-break

The caller decides what to do with an explicit bulk sequence; this module only
guarantees that anything representable as a smaller action IS returned as the
smaller action.
--]]

local MenuSchema = require("reorderingmenus_menu_schema")

local SemanticDiff = {}

local SEPARATOR_ID = MenuSchema.SEPARATOR_ID
SemanticDiff.SEPARATOR_ID = SEPARATOR_ID

-- -------------------------------------------------------------------------
-- Longest common subsequence of two arrays of strings.
-- O(#a * #b) time/space - menu lists are small (tens of rows), fine.
-- Deterministic: produces ONE canonical LCS (the DP backtrace prefers
-- moving up over left, which is stable for any input pair).
-- -------------------------------------------------------------------------
function SemanticDiff.lcs(a, b)
    local n, m = #a, #b
    local dp = {}
    for i = 0, n do dp[i] = { [0] = 0 } end
    for j = 1, m do dp[0][j] = 0 end
    for i = 1, n do
        for j = 1, m do
            if a[i] == b[j] then
                dp[i][j] = dp[i - 1][j - 1] + 1
            else
                local up, left = dp[i - 1][j], dp[i][j - 1]
                dp[i][j] = (up >= left) and up or left
            end
        end
    end
    -- backtrace
    local result = {}
    local i, j = n, m
    while i > 0 and j > 0 do
        if a[i] == b[j] then
            table.insert(result, 1, a[i])
            i, j = i - 1, j - 1
        elseif dp[i - 1][j] >= dp[i][j - 1] then
            i = i - 1
        else
            j = j - 1
        end
    end
    return result
end

-- Element-level classification of old vs new. Returns:
--   kept   = ordered common subsequence (as it appears in NEW)
--   removed= ids in OLD but not in NEW (sorted)
--   added  = ids in NEW but not in OLD (in new order)
function SemanticDiff.diff_sequences(old, new)
    local kept = SemanticDiff.lcs(old, new)
    local kept_set = {}
    for _, id in ipairs(kept) do kept_set[id] = true end

    local old_set, new_set = {}, {}
    for _, id in ipairs(old) do old_set[id] = true end
    for _, id in ipairs(new) do new_set[id] = true end

    local removed, added = {}, {}
    for _, id in ipairs(old) do
        if not kept_set[id] and not new_set[id] then table.insert(removed, id) end
    end
    -- ids present in both but NOT in the LCS were moved; they are neither
    -- removed nor added.
    local moved_or_kept_in_new = {}
    for _, id in ipairs(new) do
        if not kept_set[id] then
            if old_set[id] then
                table.insert(moved_or_kept_in_new, id)
            else
                table.insert(added, id)
            end
        end
    end
    for _, id in ipairs(kept) do table.insert(moved_or_kept_in_new, id) end
    table.sort(removed)
    return kept, removed, moved_or_kept_in_new, added
end

local function same_multiset(a, b)
    if #a ~= #b then return false end
    local count = {}
    for _, x in ipairs(a) do count[x] = (count[x] or 0) + 1 end
    for _, x in ipairs(b) do
        count[x] = (count[x] or 0) - 1
        if (count[x] or 0) < 0 then return false end
    end
    return true
end

local function find_block_relocation(old, new)
    local n = #old
    for len = n - 1, 2, -1 do
        for start = 1, n - len + 1 do
            local block = {}
            for i = start, start + len - 1 do
                table.insert(block, old[i])
            end
            for nstart = 1, #new - len + 1 do
                local matches = true
                for k = 1, len do
                    if new[nstart + k - 1] ~= block[k] then
                        matches = false
                        break
                    end
                end
                if matches and nstart ~= start then
                    local rest_old, rest_new = {}, {}
                    for i = 1, n do
                        local in_block = i >= start and i < start + len
                        if not in_block then table.insert(rest_old, old[i]) end
                    end
                    for i = 1, #new do
                        local in_block = i >= nstart and i < nstart + len
                        if not in_block then table.insert(rest_new, new[i]) end
                    end
                    local same = true
                    for k = 1, #rest_old do
                        if rest_old[k] ~= rest_new[k] then
                            same = false
                            break
                        end
                    end
                    if same and #rest_old == #rest_new then
                        local anchor = nstart > 1 and new[nstart - 1] or false
                        return {
                            block = block,
                            after = anchor,
                            before = (nstart + len <= #new)
                                and new[nstart + len] or nil,
                        }
                    end
                end
            end
        end
    end
    return nil
end

-- Classify one menu's old->new transformation. `old`/`new` are raw lists of
-- string ids (separators included). Returns nil when nothing changed, else a
-- descriptor.
function SemanticDiff.infer_list_change(old, new)
    if type(old) ~= "table" or type(new) ~= "table" then return nil end

    -- strip separators for ordering analysis; separator placement is handled
    -- through separator records by the caller.
    local function strip(t)
        local out = {}
        for _, id in ipairs(t) do
            if id ~= SEPARATOR_ID then table.insert(out, id) end
        end
        return out
    end
    local olds, news = strip(old), strip(new)

    if #olds == #news then
        local identical = true
        for i = 1, #olds do
            if olds[i] ~= news[i] then identical = false break end
        end
        if identical then return nil end

        local reversed = #olds > 1
        for i = 1, #olds do
            if olds[i] ~= news[#news - i + 1] then reversed = false break end
        end
        if reversed then
            return { kind = "reversal" }
        end

        local det = SemanticDiff.detect_relocation(olds, news, { separator_aware = false })
        if det and det.move then
            local move = det.move
            local after = move.type == "move_before" and false or move.after
            return { kind = "single_move", id = move.item, after = after }
        end

        local blk = find_block_relocation(olds, news)
        if blk then
            return { kind = "block_move", block = blk.block, after = blk.after }
        end
    else
        -- Unequal lengths: distinguish genuine reshuffles (bulk) from PURE
        -- insertions / removals, where every survivor keeps its relative
        -- order. Those carry no ORDERING information at all - the id sets
        -- change, which membership reconciliation handles - so freezing an
        -- explicit sequence for them would shadow future upstream reorders.
        local function is_subsequence(small, big)
            local j = 1
            for i = 1, #big do
                if big[i] == small[j] then j = j + 1 end
            end
            return j > #small
        end
        if #news < #olds and is_subsequence(news, olds) then
            local new_set = {}
            for _, id in ipairs(news) do new_set[id] = true end
            local removed = {}
            for _, id in ipairs(olds) do
                if not new_set[id] then table.insert(removed, id) end
            end
            return { kind = "removal", removed = removed }
        end
        if #news > #olds and is_subsequence(olds, news) then
            local old_set = {}
            for _, id in ipairs(olds) do old_set[id] = true end
            local added = {}
            for _, id in ipairs(news) do
                if not old_set[id] then table.insert(added, id) end
            end
            return { kind = "addition", added = added }
        end
    end

    return { kind = "bulk", sequence = news }
end

-- Resolve membership claims gathered from every changed level of an edited
-- file: an id listed under a non-default parent means "the user moved it".
-- Claims is { [id] = { menu_a, menu_b, ... } }; returns { [id] = chosen }.
-- Policy: prefer a non-default claimant (customized destination wins);
-- ties break alphabetically for determinism under any iteration order.
function SemanticDiff.resolve_claims(reg, claims)
    local chosen_by_id = {}
    for id, claimants in pairs(claims) do
        table.sort(claimants)
        local node = reg.nodes[id]
        local default_parent = node and node.default_parent or nil
        local non_default = {}
        for _, m in ipairs(claimants) do
            if m ~= default_parent then table.insert(non_default, m) end
        end
        chosen_by_id[id] = non_default[1] or claimants[1]
    end
    return chosen_by_id
end

-- ===========================================================================
-- PURE SEMANTIC ORDERING LAYER (schema-independent, 2026-08-24)
-- ===========================================================================
-- Everything below consumes ORDINARY SEQUENCES (arrays of string ids) and
-- returns SEMANTIC RESULTS. Nothing here touches IntentStore, the
-- materializer, the filesystem, or Agent A's canonical schema. Integration
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
    local leftover = {}
    for id, c in pairs(counts) do leftover[id] = c end
    local removed = {}
    for _, id in ipairs(ba) do
        if leftover[id] and leftover[id] > 0 then
            removed[#removed + 1] = id
            leftover[id] = leftover[id] - 1
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
        if taken and #rest_a == #rest_b then
            local same = true
            for i = 1, #rest_a do
                if rest_a[i] ~= rest_b[i] then same = false break end
            end
            if same then
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

-- Inverse move: op undoes another placement on the same item (their anchor
-- neighborhoods coincide). Two ops are inverses exactly when applying one
-- after the other restores the original sequence — checked by execution, not
-- by field comparison, so move_after/move_before spellings of the same spot
-- cancel correctly.
local function inverse_pair(seq, first, second, opts)
    local once, err1 = SemanticDiff.apply_operation(seq, first)
    if err1 then return false end
    local twice, err2 = SemanticDiff.apply_operation(once, second)
    if err2 then return false end
    if not SemanticDiff.sequence_equal(twice, seq) then return false end
    -- Guard against true no-op pairs: an inverse must actually MOVE something.
    return not SemanticDiff.sequence_equal(once, seq)
end

function SemanticDiff.moves_are_inverse(seq, op_a, op_b, opts)
    local nb, err = SemanticDiff.normalize_sequence(seq, opts)
    if err then return nil, err end
    return inverse_pair(nb, op_a, op_b, opts), nil
end

-- Redundant explicit anchor: recording `op` would not change what the
-- baseline already says (same location), OR the anchor names a neighborhood
-- the row already occupies.
function SemanticDiff.anchor_is_redundant(baseline, op, opts)
    return SemanticDiff.is_noop_move(baseline, op, opts)
end

-- Restored default: proposed equals the default derivation (item-wise).
function SemanticDiff.matches_default(proposed, default_seq, opts)
    local eq, err = SemanticDiff.orders_equivalent(default_seq, proposed, opts)
    if err then return nil, err end
    return eq, nil
end

-- -------------------------------------------------------------------------
-- MINIMIZATION WITHOUT REPEATED GRAPH RESOLUTION
-- -------------------------------------------------------------------------
-- Pure, LOCAL reduction of a staged operation set against ONE known baseline
-- sequence plus the relevant current record description. No materializer
-- calls, no store access. The caller supplies:
--
--   baseline      - current applicable item sequence for the level
--   staged_ops    - array of semantic ops (move_after/move_before/parent_only)
--   current_record - optional description of what is already persisted:
--                    { form = "anchor", op = <semantic op> }
--                       or { form = "sequence", items = {...} }
--   is_available  - optional map id->bool; dormant-aware filtering
--
-- Rules (in order):
--   R1 drop any staged op that is a no-op against the RUNNING sequence
--      (starts at baseline);
--   R2 drop a staged op whose effect merely RESTORES the running sequence to
--      its pre-stage state along the chain (inverse-of-previous cancellation);
--   R3 if after reduction every op is a no-op against baseline AND the
--      current record's semantic content equals the baseline projection, the
--      whole stage is REDUNDANT (record should be dropped upstream);
--   R4 a current anchor record equal to the surviving staged op is dropped
--      from the output (already persisted); a current SEQUENCE record equal
--      to the final projected sequence marks the stage redundant.
-- Dormant discipline: ops touching ids with is_available[id] == false are
-- PRESERVED verbatim (a currently ineffective record may be intentionally
-- retained for provider return); the minimizer never drops those and reports
-- them under `retained_dormant`. Callers decide liveness policy; this module
-- refuses to guess.
-- -------------------------------------------------------------------------

function SemanticDiff.minimize_stage(baseline, staged_ops, current_record, opts)
    opts = opts or {}
    local nb, err = SemanticDiff.normalize_sequence(baseline, opts)
    if err then return nil, err end
    local is_available = opts.is_available
    local function dormant(id)
        return is_available ~= nil and is_available[id] == false
    end

    if type(staged_ops) ~= "table" then
        return nil, { code = "bad_arguments", detail = "staged_ops must be an array" }
    end

    local retained_dormant = {}
    local running = nb
    local kept = {}
    for i, op in ipairs(staged_ops) do
        if type(op) ~= "table" or type(op.item) ~= "string" then
            return nil, { code = "bad_arguments", detail = "op #" .. tostring(i) }
        end
        if dormant(op.item) then
            retained_dormant[#retained_dormant + 1] = op
        else
            local applied, aerr = SemanticDiff.apply_operation(running, op)
            if aerr then
                return nil, aerr
            end
            if SemanticDiff.sequence_equal(applied, running) then
                -- R1: no-op at this point in the chain.
            else
                kept[#kept + 1] = { op = op, seq_before = running, seq_after = applied }
                running = applied
            end
        end
    end

    -- R2: collapse adjacent inverse pairs (move X then move X back).
    local collapsed = {}
    for i = 1, #kept do
        local last = collapsed[#collapsed]
        if last and inverse_pair(last.seq_before, last.op, kept[i].op, opts) then
            collapsed[#collapsed] = nil
            running = last.seq_before
        else
            collapsed[#collapsed + 1] = kept[i]
        end
    end

    local final_sequence = running
    if #collapsed > 0 then final_sequence = collapsed[#collapsed].seq_after end

    -- Record comparison, purely structural.
    local redundant_against_record = false
    local drop_matching_anchor = false
    if current_record and current_record.form == "sequence"
            and type(current_record.items) == "table" then
        local rec, rerr = SemanticDiff.normalize_sequence(current_record.items, opts)
        if rerr then return nil, rerr end
        if SemanticDiff.sequence_equal(
                SemanticDiff.items_projection(rec),
                SemanticDiff.items_projection(final_sequence)) then
            redundant_against_record = true
        end
    elseif current_record and current_record.form == "anchor"
            and type(current_record.op) == "table" then
        if #collapsed == 1
                and SemanticDiff.same_anchor_semantics(collapsed[1].op, current_record.op) then
            drop_matching_anchor = true
        end
    end

    -- R3: nothing survived and the final state equals the baseline.
    local all_noop = #collapsed == 0 and #retained_dormant == 0
        and SemanticDiff.sequence_equal(final_sequence, nb)

    return {
        ops = collapsed,
        final_sequence = final_sequence,
        retained_dormant = retained_dormant,
        redundant = all_noop or redundant_against_record,
        drop_matching_anchor = drop_matching_anchor,
    }, nil
end

-- Anchor-form equivalence: two placements agree when executing both against
-- any common sequence yields the same landing spot for the item. We check it
-- against the given baseline (cheap, deterministic, sufficient for record
-- comparison where both were derived from that baseline).
function SemanticDiff.same_anchor_semantics(op_a, op_b)
    if type(op_a) ~= "table" or type(op_b) ~= "table" then return false end
    if op_a.item ~= op_b.item then return false end
    local ta, tb = op_a.type, op_b.type
    if ta == tb then
        if ta == "move_after" then return op_a.after == op_b.after end
        if ta == "move_before" then return op_a.before == op_b.before end
        if ta == "parent_only" then return true end
        return false
    end
    -- Cross-spelling equivalence (after=X vs before=Y naming the same gap):
    -- resolve via application against a synthetic witness sequence.
    local witness, parts = {}, {}
    local function add(id) if type(id) == "string" then parts[id] = true end end
    add(op_a.after); add(op_a.before); add(op_b.after); add(op_b.before); add(op_a.item)
    for id in pairs(parts) do witness[#witness + 1] = id end
    table.sort(witness)
    local ra, ea = SemanticDiff.apply_operation(witness, op_a)
    if ea then return false end
    local rb, eb = SemanticDiff.apply_operation(witness, op_b)
    if eb then return false end
    -- Same landing position of item?
    local pa, pb
    for i, id in ipairs(ra) do if id == op_a.item then pa = i break end end
    for i, id in ipairs(rb) do if id == op_b.item then pb = i break end end
    return pa ~= nil and pa == pb
end

return SemanticDiff

-- # semantic_diff replacement plan for stageList (for the integration agent)

Status: implemented, tested (`tests/test_semantic_ordering_unit.lua`,
6287 assertions, plus legacy `tests/test_semantic_diff_unit.lua` 20/0 and
namespace-isolation 12/0 green). This file specifies HOW to wire it.

## 1. Public semantic API (call these; nothing else is needed)

Module `reorderingmenus_semantic_diff`. All functions are PURE: sequences in
(arrays of string ids), semantic results out. No store, no materializer, no
schema access. Determinism never depends on hash order or history.

Constants:

    SemanticDiff.KIND       = { UNCHANGED="unchanged",
                                ONE_RELOCATION="one_relocation",
                                PURE_ADDITION="pure_addition",
                                PURE_REMOVAL="pure_removal",
                                COMPLEX="complex_permutation" }
    SemanticDiff.OP_TYPE    = { MOVE_AFTER="move_after",     -- after=false => head
                                MOVE_BEFORE="move_before",   -- before=false => head
                                PARENT_ONLY="parent_only" }  -- append at end
    SemanticDiff.SEPARATOR_ID                                  -- re-exported

Core entry points:

    SemanticDiff.classify_permutation(baseline, proposed, opts)
      -> { kind, move?, sequence?, added?, removed?, separators_changed,
           matches_noop_baseline? }, err
        THE stageList decision. opts:
          separator_aware = true|false  -- false: SEPARATOR_ID is an ordinary id
                                        -- true: dividers are positional tokens;
                                        -- ordering decided on item projection
          descriptors     = { [id] = { provider = ... } }
                                        -- stamps copied onto produced ops
          noop_baseline   = <seq>       -- extra no-op reference (e.g. the
                                        -- CURRENT effective derivation, so an
                                        -- away-then-back drag classifies as
                                        -- unchanged without any probing)

    SemanticDiff.detect_relocation(baseline, proposed, opts)
      -> { move = op, diagnostics }, err | nil
        One authoritative answer to "is B exactly one logical entry moved?".
        Ambiguities settled canonically: min |from-to| distance, then min
        BASELINE index, then lexicographically smallest id. Drag direction or
        history can NEVER change the serialization. Diagnostics indexes are
        logging-only; persist only `.move`.

    SemanticDiff.apply_operation(seq, op) -> seq', err
        Executes move_after/move_before/parent_only. STRICT anchors: missing
        anchor => err { code = "missing_anchor" }, never a silent fallback.

Equivalence family (integration picks which to use where):

    orders_equivalent(a, b, opts)         applicable-order question
    canonical_records_equal(a, b, opts)   stored-record identity (order +
                                          divider layout semantics via raw
                                          token comparison + provider stamps
                                          through opts.descriptors_a/_b)
    live_orders_equivalent(a, b, is_available_map)
                                          equality IGNORING ids whose
                                          availability is false (dormant
                                          tombstones stay distinct under
                                          canonical_records_equal)

No-op / minimization primitives (all O(len^2) array math, zero resolves):

    is_noop_move(baseline, op)            move to same location
    moves_are_inverse(seq, op_a, op_b)    inverse pair restoring baseline
                                          (execution-checked, so cross-spelling
                                          anchors cancel correctly)
    anchor_is_redundant(baseline, op)     redundant explicit anchor
    matches_default(proposed, default)    restored default
    same_anchor_semantics(op_a, op_b)     two spellings of the same placement

    minimize_stage(baseline, staged_ops, current_record, opts)
      -> { ops, final_sequence, retained_dormant, redundant,
           drop_matching_anchor }, err
        Local reduction against ONE baseline sequence + a description of the
        current record ({ form="anchor", op=... } | { form="sequence",
        items=... }). Drops chain no-ops, collapses inverse pairs, flags
        whole-stage redundancy, detects already-persisted anchors.
        DORMANT DISCIPLINE: opts.is_available[id]==false ops are returned in
        `retained_dormant` verbatim and force redundant=false. The module will
        NOT silently optimize away currently-inert records; callers decide
        liveness policy.

Sequence utilities: normalize_sequence (validates uniqueness; sorted
duplicate list in error), multiset_diff, items_projection,
separator_anchors, sequence_equal, separator_layout_equal, is_subsequence.

LEGACY API PRESERVED BYTE-FOR-BYTE (native_writer.lua still depends on it):
lcs, diff_sequences, infer_list_change, resolve_claims.

Error convention everywhere: nil-plus-table { code = ... }; codes listed in
the module header. Duplicate identities (including duplicated separator
tokens when not separator_aware) are hard errors, never silently deduped.

## 2. Current stageList inference (manager lines ~1118-1287) and its costs

    collectStagedRows -> seq (stripped) + sep_anchors
    trial = deepcopy(section); clear order_override/sequence_eras/
            position_override
    expected_full = Materializer.resolve(trial)              -- RESOLVE 1
    singleRelocation(expected, seq)                          -- local copy
    clear old position anchors of this menu
    IF maybe-single-move THEN
      for each row in seq:                                   -- up to L times
        probe = deepcopy(section) + candidate anchor
        Materializer.resolve(probe) == seq ?                 -- RESOLVE 2..L+1
      pure_default probe                                     -- RESOLVE L+2
    ELSEIF seq == expected THEN
      for each stale anchor:                                 -- up to L times
        probe minus anchor; resolve                          -- RESOLVE ..2L+2
    ELSE
      setOrderOverride(seq, eras)

Every branch decision is made by RE-MATERIALIZING hypothetical worlds. That
is what the semantic layer replaces.

## 3. Replacement wiring (Agent D)

One classification call after `expected` is derived (RESOLVE 1 stays; it is
the only materialization needed):

    local classification = SemanticDiff.classify_permutation(
        expected,                       -- item projection of the trial derive
        seq,                            -- collectStagedRows output (stripped)
        { descriptors = descriptor_map, -- optional provider stamps per id
          noop_baseline = pure_default_items })  -- see note below

Manager behavior per result:

    kind == UNCHANGED
        Clear order_override[menu_id] AND every position anchor on this
        menu's rows (the existing old_position_ids loop already does this).
        Write nothing else. invalidate(view, {drop_history=true}). Covers BOTH
        "matches default derivation" and "away-then-back equals current
        effective state" (classification reports matches_noop_baseline=true
        for the latter - log it if you want telemetry).

    kind == ONE_RELOCATION
        Gate on dividers exactly as today (#sep_anchors == 0 or
        dividers_unchanged). Then ONE record:
          txn:setPositionOverride(view, move.item,
              { after = move.after,           -- false means head, as before
                provider = move.provider or Registry.getProvider(reg, move.item) })
          txn:setOrderOverride(view, menu_id, nil)
        No candidate probing: `move` is already the canonical interpretation
        (equivalent final arrangements always yield the identical anchor).

    kind == PURE_ADDITION / PURE_REMOVAL
        Ordering-neutral; reconcileMembership (which runs earlier) already
        owns the membership claims. Just clear order_override when the
        arrangement otherwise equals expected. Do NOT freeze a sequence.

    kind == COMPLEX_PERMUTATION
        Era-stamp every sequenced entry (eras[id] =
        move.provider-source or Registry.getProvider(reg, id)) and
        setOrderOverride(classification.sequence, eras). Note
        classification.sequence is ALREADY the item projection - do not strip
        again. Divider changes ride separately via separators_changed /
        replaceSeparatorIntent (unchanged code path).

    errors (err ~= nil)
        Structural invalid input (duplicate identities etc.). Treat like the
        existing stale-editor guards: refuse the stage loudly rather than
        writing partial intent.

noop_baseline note: the manager currently spends RESOLVE L+2 proving
"staged == pure default". If the graph can supply the pure-default items for
the level cheaply, pass them as noop_baseline and the check becomes free.
Otherwise pass nothing and keep one explicit pure-default probe - either way
the candidate loop is gone.

Optional second step (multi-drag chains): editors currently call stageList
once per arrangement, so a single classification suffices. If staging ever
becomes incremental (op streams), use minimize_stage with the current
position_override mapped to { form = "anchor", op = ... } to collapse
inverse drags BEFORE writing.

## 4. Replacement map

| Existing algorithm/path                                    | New primitive                                   | Old code deletable after integration |
|------------------------------------------------------------|-------------------------------------------------|--------------------------------------|
| local singleRelocation (manager ~1028-1055)                 | SemanticDiff.detect_relocation                  | yes (whole function)                 |
| candidate-by-candidate probe loop (manager ~1193-1213)      | classify_permutation -> ONE_RELOCATION.move     | yes (whole loop + its deepcopy)      |
| pure-default probe + equality branch (manager ~1225-1238)   | classify_permutation(noop_baseline) / matches_default | yes                            |
| per-anchor redundancy probes (manager ~1248-1266)           | is_noop_move / anchor_is_redundant / minimize_stage | yes                              |
| reversal/block_move special cases in infer_list_change      | classify_permutation (COMPLEX covers them)      | keep for native_writer compat until its lane migrates |
| separatorAnchors/stripSeparators locals                     | separator_anchors / items_projection            | optional (thin wrappers, harmless)   |
| Materializer.listEquals calls in stageList                  | sequence_equal                                  | optional                             |

## 5. Complexity estimate (what wiring buys)

Per stageList call on a level with L rows and A stale anchors:
  today: 2 + L + A deep-copy+resolve cycles (worst ~2L+2; every drag on a
         frozen level pays it)
  after: exactly 1 resolve (trial derive), optionally +1 pure-default;
         classification itself is O(L^2) string comparisons (microseconds).

Typical numbers from this repo's own suites: an 8-row editor level saves
~15 hypothetical resolutions per save; a 200-step fuzz trajectory with ~30%
stageList steps at average depth 10 saves roughly 500-600 materializations
per replay, replacing them with pure array math. External-edit import in
native_writer was already analytic; it gains deterministic canonical-anchor
guarantees (adjacent-swap ambiguity no longer resolved by iteration luck)
without behavioral API change (20/0 legacy unit tests pass unmodified).

Determinism note: classification/detection depend ONLY on the argument pair.
Repeated runs produce byte-identical decision streams (asserted in-suite
over randomized trajectories with a fixed-seed LCG, independent of Lua hash
order).

--[[--
test_semantic_ordering_unit.lua — PURE ordering-semantics suite.

No KOReader env, no settings dir, no store: exercises ONLY the schema-
independent semantic layer of semantic_diff.lua

  detect_relocation / classify_permutation / apply_operation /
  orders_equivalent / canonical_records_equal / live_orders_equivalent /
  is_noop_move / normalize_sequence /
  multiset_diff / separator_anchors / items_projection

Property invariant under test (task §Tests):
  for valid unique sequences A, B classified as a single relocation,
  apply(A, detected_move) == B   -- soundness AND completeness below.

Run: luajit tests/test_semantic_ordering_unit.lua   (any cwd)
--]]

package.path = "/Users/nr/Development/ReorderingMenus/?.lua;" .. package.path
local SD = require("lib.semantic_diff")

local passed, failed = 0, 0
local failures = {}
local function ok(cond, msg)
    if cond then passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = msg
        print("[FAIL] " .. msg)
    end
end
local function eq(a, e, msg)
    if a == e then passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = msg
        print("[FAIL] " .. msg .. " expected=" .. tostring(e) .. " got=" ..
            tostring(a))
    end
end
local function seq_eq(a, b, msg)
    local sa, sb = table.concat(a or {}, "|"), table.concat(b or {}, "|")
    eq(sa, sb, msg .. " [" .. sa .. " vs " .. sb .. "]")
end
local function dump(v)
    if type(v) ~= "table" then return tostring(v) end
    local parts = {}
    for _, x in ipairs(v) do parts[#parts + 1] = tostring(x) end
    return "{" .. table.concat(parts, ",") .. "}"
end
local function err_code(r, e)
    return type(e) == "table" and e.code or nil, r
end

-- ===========================================================================
-- §1 ONE AUTHORITATIVE RELOCATION ALGORITHM
-- ===========================================================================

-- Task's motivating example.
do
    local det, err = SD.detect_relocation({"A","B","C","D","E"},
                                          {"A","D","B","C","E"})
    eq(err_code(det, err), nil, "reloc task-example no error")
    ok(det ~= nil, "reloc task-example detected")
    if det then
        eq(det.move.type, "move_after", "reloc task-example type")
        eq(det.move.item, "D", "reloc task-example item")
        eq(det.move.after, "A", "reloc task-example after")
        eq(det.diagnostics.candidates, 1, "reloc task-example unambiguous")
    end
end

-- Every single-move position: exhaustive over baselines of len 1..5.
do
    local checked, detected = 0, 0
    local baselines = {
        {"A"}, {"A","B"}, {"A","B","C"}, {"A","B","C","D"},
        {"A","B","C","D","E"},
    }
    for _, base in ipairs(baselines) do
        local n = #base
        for from = 1, n do
            for to = 1, n do
                if from ~= to then
                    local proposed = {}
                    for i = 1, n do
                        if i ~= from then proposed[#proposed + 1] = base[i] end
                    end
                    table.insert(proposed, to, base[from])
                    checked = checked + 1
                    local det, derr =
                        SD.detect_relocation(base, proposed)
                    if not derr and det then
                        detected = detected + 1
                        local applied, aerr =
                            SD.apply_operation(base, det.move)
                        ok(not aerr,
                            "property apply no error " .. dump(base) .. "->" ..
                            dump(proposed))
                        if not aerr then
                            seq_eq(applied, proposed,
                                "PROPERTY round-trip " .. dump(base) .. "->" ..
                                dump(proposed))
                        end
                    else
                        ok(false, "COMPLETENESS miss " .. dump(base) .. "->" ..
                            dump(proposed))
                    end
                end
            end
        end
    end
    -- n(n-1) summed over n=1..5 = 0+2+6+12+20
    eq(checked, 40, "exhaustive single-move case count")
    eq(detected, 40, "every explicit single move detected")
end

-- Edge cases from the spec.
do
    -- first -> last (lands after the current tail)
    local det = SD.detect_relocation({"A","B","C"}, {"B","C","A"})
    ok(det and det.move.item == "A" and det.move.after == "C",
        "reloc first->last anchors after tail")
    -- last -> first (head form: after = false)
    det = SD.detect_relocation({"A","B","C"}, {"C","A","B"})
    ok(det and det.move.item == "C" and det.move.after == false,
        "reloc last->first emits after=false")
    -- length one: nothing can move
    det, _ = SD.detect_relocation({"A"}, {"A"})
    eq(det, nil, "reloc length-one identical -> none")
    -- empty sequences
    det, _ = SD.detect_relocation({}, {})
    eq(det, nil, "reloc empty -> none")
    -- unequal lengths -> not a relocation
    det, _ = SD.detect_relocation({"A","B"}, {"A"})
    eq(det, nil, "reloc unequal lengths -> none")
    -- unavailable/dormant id supplied in baseline participates normally.
    -- Ambiguity note: {"A","ghost","B"} -> {"ghost","A","B"} admits BOTH
    -- "ghost up one" and "A down one"; the canonical rule attributes it to
    -- the smallest BASELINE index, i.e. A. Dormant-ness must not change that.
    det = SD.detect_relocation({"A","ghost","B"}, {"ghost","A","B"})
    ok(det and det.move.item == "A" and det.move.after == "ghost",
        "reloc dormant id ordinary identity; ambiguity -> earliest baseline row")
    -- provider descriptor copied onto op; absent descriptor -> no stamp
    det = SD.detect_relocation({"A","B"}, {"B","A"},
        { descriptors = { A = { provider = "plugin:v1" } } })
    ok(det ~= nil, "reloc descriptors accepted")
    if det then
        eq(det.move.item, "A", "reloc descriptor case item")
        eq(det.move.provider, "plugin:v1", "reloc provider stamp copied")
    end
    det = SD.detect_relocation({"A","B"}, {"B","A"})
    ok(det and det.move.provider == nil, "reloc no descriptors -> no stamp")
end

-- Invalid duplicate identities.
do
    local det, err = SD.detect_relocation({"A","A","B"}, {"A","B","A"})
    eq(det, nil, "duplicates rejected (no detection)")
    eq(type(err) == "table" and err.code or nil, "duplicate_identities",
        "duplicates error code")
    eq(err and err.duplicates and err.duplicates[1], "A",
        "duplicates listed sorted")
    local _, err2 = SD.normalize_sequence({"B","A","B"})
    eq(err2.code, "duplicate_identities", "normalize catches duplicates")
    local _, err3 = SD.normalize_sequence({"A", 42})
    eq(err3.code, "non_string_identity", "non-string identity rejected")
    local _, err4 = SD.normalize_sequence("not a table")
    eq(err4.code, "not_a_sequence", "non-table rejected")
end

-- Canonical anchor choice: ambiguity settled deterministically.
do
    -- Adjacent transposition admits TWO interpretations (A forward, B back);
    -- rule: smallest travel distance, then smallest BASELINE index, then id.
    local det = SD.detect_relocation({"A","B"}, {"B","A"})
    ok(det and det.move.item == "A" and det.move.after == "B",
        "adjacent swap canonically attributed to smaller baseline index")
    -- Equivalent histories: reaching the same arrangement through different
    -- drag paths changes NOTHING (detection depends only on the pair).
    local base = {"A","B","C","D","E"}
    local target = {"A","C","D","E","B"}
    -- B moved 5->2 (distance 3). C, D, E each shifted back one slot, but
    -- removing any ONE of them never reconciles the rests: B is the UNIQUE
    -- valid interpretation here. Anchor: predecessor of B's new slot.
    local seen = {}
    for run = 1, 25 do
        local det = SD.detect_relocation(base, target)
        seen[det.move.item .. ">" .. tostring(det.move.after)] = true
    end
    local keys = {}
    for k in pairs(seen) do keys[#keys + 1] = k end
    eq(#keys, 1, "equivalent histories serialize identically")
    eq(keys[1], "B>E", "stable canonical anchor: unique min-distance reading")

    -- Successor-style head anchor opt-in.
    det = SD.detect_relocation({"A","B","C"}, {"C","A","B"},
        { anchor_style = "successor" })
    ok(det and det.move.type == "move_before" and det.move.before == "A",
        "successor style emits move_before at head landing")
    -- Predecessor preference elsewhere is unaffected by style.
    det = SD.detect_relocation({"A","B","C"}, {"B","A","C"},
        { anchor_style = "successor" })
    ok(det and det.move.type == "move_after" and det.move.after == "B",
        "predecessor preferred regardless of style")
end

-- ===========================================================================
-- §2 CLASSIFICATION (task §3)
-- ===========================================================================
do
    local K = SD.KIND
    local c = SD.classify_permutation({"A","B","C"}, {"A","B","C"})
    eq(c.kind, K.UNCHANGED, "classify identical -> unchanged")
    eq(c.separators_changed, false, "identical input: separator flag false")

    c = SD.classify_permutation({"A","B","C","D","E"}, {"A","D","B","C","E"})
    eq(c.kind, K.ONE_RELOCATION, "single drag -> one_relocation")
    ok(c.move and c.move.item == "D" and c.move.after == "A",
        "one_relocation carries semantic move only")
    ok(type(c.diagnostics) == "table"
        and type(c.diagnostics.baseline_index) == "number",
        "diagnostics present (logging only, never persisted)")

    c = SD.classify_permutation({"A","B","C","D"}, {"B","A","D","C"})
    eq(c.kind, K.COMPLEX, "two swaps -> complex_permutation")
    seq_eq(c.sequence, {"B","A","D","C"}, "complex sequence is item projection")

    c = SD.classify_permutation({"A","B","C","D"}, {"D","C","B","A"})
    eq(c.kind, K.COMPLEX, "reversal -> complex_permutation (bulk semantics)")

    c = SD.classify_permutation({"A","B","C"}, {"A","B","C","D","E"})
    eq(c.kind, K.PURE_ADDITION, "subsequence growth -> pure_addition")
    seq_eq(c.added, {"D","E"}, "pure_addition lists added ids (proposed order)")
    c = SD.classify_permutation({"A","B","C"}, {"B"})
    eq(c.kind, K.PURE_REMOVAL, "subsequence shrink -> pure_removal")
    seq_eq(c.removed, {"A","C"}, "pure_removal lists removed ids (baseline order)")

    c = SD.classify_permutation({"A","B","C"}, {"C","B","X"})
    eq(c.kind, K.COMPLEX, "membership change + reorder -> complex")

    -- noop_baseline option: away-then-back collapses WITHOUT any probing.
    c = SD.classify_permutation({"A","B","C"}, {"B","A","C"},
        { noop_baseline = {"B","A","C"} })
    eq(c.kind, K.UNCHANGED, "proposed == noop_baseline -> unchanged")
    eq(c.matches_noop_baseline, true, "provenance recorded")

    local _, err = SD.classify_permutation({"A","A"}, {"A"})
    eq(err.code, "duplicate_identities", "classify rejects duplicate identities")
end

-- ===========================================================================
-- §8 SEPARATOR-AWARE ORDERING
-- ===========================================================================
do
    local SEP = SD.SEPARATOR_ID
    local opts = { separator_aware = true }

    local c = SD.classify_permutation({"A",SEP,"B","C"}, {"A",SEP,"B","C"}, opts)
    eq(c.kind, SD.KIND.UNCHANGED, "sep-aware identical -> unchanged")
    eq(c.separators_changed, false, "sep-aware identical: layout unchanged")

    c = SD.classify_permutation({"A",SEP,"B"}, {"A","B",SEP}, opts)
    eq(c.kind, SD.KIND.UNCHANGED, "divider-only shift keeps applicable order")
    eq(c.separators_changed, true, "divider-only shift IS flagged")

    local norm, nerr = SD.normalize_sequence({"A",SEP,SEP,"B"}, opts)
    eq(nerr, nil, "repeated separator tokens legal in aware mode")
    eq(#norm, 4, "separator tokens kept positionally")
    local anchors = SD.separator_anchors({SEP,"A",SEP,SEP,"B"})
    eq(#anchors, 3, "one anchor per separator token")
    eq(tostring(anchors[1]), "false", "leading separator anchors false")
    eq(anchors[2], "A", "separator anchors its preceding item")
    eq(anchors[3], "A", "consecutive separators share preceding item anchor")

    -- Unaware mode: a duplicated separator token is a duplicate identity.
    local _, derr = SD.normalize_sequence({"A",SEP,SEP,"B"})
    eq(derr.code, "duplicate_identities",
        "unaware mode: duplicated separator rejected like any id")

    -- Relocation THROUGH separators resolves on the item projection.
    local det = SD.detect_relocation({"A",SEP,"B","C"}, {"B","A",SEP,"C"}, opts)
    ok(det and det.move.item == "A" and det.move.after == "B",
        "relocation detected across separator tokens")
    ok(SD.separator_layout_equal({"A",SEP,"B","C"}, {"B","A",SEP,"C"}),
        "separator layout compared independent of item moves")

    -- Complex classification NEVER freezes divider layout.
    c = SD.classify_permutation(
        {"A",SEP,"B","C","D"}, {"D",SEP,"C","B","A"}, opts)
    eq(c.kind, SD.KIND.COMPLEX, "separated reversal -> complex")
    seq_eq(c.sequence, {"D","C","B","A"}, "complex sequence excludes dividers")
    -- The reversal moved the divider's preceding item from A to D, so the
    -- LAYOUT genuinely changed; the flag must report it truthfully.
    eq(c.separators_changed, true, "layout flag reports real layout change")
    ok(SD.sequence_equal(c.sequence, SD.items_projection(
            {"D",SEP,"C","B","A"})),
        "complex sequence is exactly the item projection")
end

-- ===========================================================================
-- §4 ORDERING EQUIVALENCE
-- ===========================================================================
do
    local SEP = SD.SEPARATOR_ID
    local eqv, eerr
    -- Currently applicable order: item order only; divider layout ignored.
    eqv = SD.orders_equivalent({"A",SEP,"B"}, {"A","B",SEP})
    eq(eqv, true, "orders_equivalent ignores divider layout")
    eqv = SD.orders_equivalent({"A","B","C"}, {"A","B"})
    eq(eqv, false, "orders_equivalent respects membership")
    _, eerr = SD.orders_equivalent({"A","A"}, {"A"})
    eq(eerr.code, "duplicate_identities", "equivalence validates inputs")

    -- Canonical-record equality: exact tokens AND provider stamps.
    local rec_a = {"A","B"}
    local rec_b = {"A","B"}
    eq(SD.canonical_records_equal(rec_a, rec_b), true,
        "records equal on same tokens")
    eq(SD.canonical_records_equal({"A","B"}, {"B","A"}), false,
        "records differ on order")
    eq(SD.canonical_records_equal(
        {"A","B"}, {"A","B"},
        { descriptors_a = { A = { provider = "p1" } },
          descriptors_b = { A = { provider = "p1" } } }),
        true, "same stamps -> equal records")
    eq(SD.canonical_records_equal(
        {"A","B"}, {"A","B"},
        { descriptors_a = { A = { provider = "p1" } },
          descriptors_b = { A = { provider = "p2" } } }),
        false, "different provider era -> different record")

    -- Live vs canonical with dormant entries.
    local live_avail = { ghost = false }
    eqv = SD.live_orders_equivalent(
        {"A","ghost","B"}, {"A","B"}, live_avail)
    eq(eqv, true, "tombstoned id does not break LIVE equality")
    eqv = SD.live_orders_equivalent({"A","ghost","B"}, {"B","A"}, live_avail)
    eq(eqv, false, "live projection still respects order")
    -- ...but canonical equality keeps them distinct (dormant record is DATA).
    eq(SD.canonical_records_equal({"A","ghost","B"}, {"A","B"}), false,
        "canonical equality preserves tombstone difference")
end

-- ===========================================================================
-- §5 MUTATION-BOUNDARY NO-OP DETECTION
-- ===========================================================================
do
    local noop
    -- Move to same location.
    noop = SD.is_noop_move({"A","B","C"},
        { type = "move_after", item = "B", after = "A" })
    eq(noop, true, "is_noop_move: row already in that slot")
    noop = SD.is_noop_move({"A","B","C"},
        { type = "move_after", item = "B", after = "C" })
    eq(noop, false, "is_noop_move: real move detected")

    -- apply_operation strictness.
    local out, aerr = SD.apply_operation({"A","B"},
        { type = "move_after", item = "C", after = "A" })
    ok(aerr == nil and out and out[1] == "A" and out[2] == "C" and out[3] == "B",
        "insertion of absent item via anchor is legal")
    out, aerr = SD.apply_operation({"A","B"},
        { type = "move_after", item = "B", after = "ZZZ" })
    ok(out == nil and aerr and aerr.code == "missing_anchor",
        "missing anchor is an ERROR, never silent")
    out, aerr = SD.apply_operation({"A","B"}, { type = "teleport", item = "A" })
    ok(out == nil and aerr.code == "unknown_operation_type",
        "unknown op types rejected")
end

-- ===========================================================================
-- §9 DETERMINISM + PROPERTY SWEEP (randomized)
-- ===========================================================================
do
    -- Linear congruential generator: fixed seed => identical stream anywhere.
    local seed = 20260824
    local function rnd(n)  -- deterministic integer in [1, n]
        seed = (seed * 1103515245 + 12345) % 2147483648
        return (seed % n) + 1
    end

    local function shuffled(items)
        local t = {}
        for _, x in ipairs(items) do t[#t + 1] = x end
        for i = #t, 2, -1 do
            local j = rnd(i)
            t[i], t[j] = t[j], t[i]
        end
        return t
    end

    local alphabet = {"a","b","c","d","e","f"}
    local classified_single, complex_ok, unchanged_ok = 0, 0, 0
    local N = 3000

    for trial = 1, N do
        local size = rnd(6)
        local base = {}
        for i = 1, size do base[i] = alphabet[i] end
        local proposed = shuffled(base)

        local c = SD.classify_permutation(base, proposed)
        if c.kind == SD.KIND.UNCHANGED then
            unchanged_ok = unchanged_ok + 1
            ok(SD.sequence_equal(base, proposed),
                "property: unchanged only when truly equal (trial " ..
                trial .. ")")
        elseif c.kind == SD.KIND.ONE_RELOCATION then
            classified_single = classified_single + 1
            -- THE invariant: apply(A, detected_move) == B.
            local applied, aerr = SD.apply_operation(base, c.move)
            ok(aerr == nil, "property: apply error-free (trial " .. trial .. ")")
            if not aerr then
                seq_eq(applied, proposed,
                    "PROPERTY apply(A,detected)==B (trial " .. trial .. ")")
            end
            -- Soundness of the sparse claim: it really IS one relocation.
            local det = SD.detect_relocation(base, proposed)
            ok(det ~= nil,
                "property: classify agrees with detector (trial " .. trial ..")")
        else
            complex_ok = complex_ok + 1
            -- COMPLETENESS: anything complex must NOT be representable as a
            -- single relocation.
            local det = SD.detect_relocation(base, proposed)
            ok(det == nil,
                "property: complex truly not single-relocatable (trial " ..
                trial .. ")")
            seq_eq(c.sequence, proposed,
                "property: complex carries full item projection (trial " ..
                trial .. ")")
        end
    end

    ok(classified_single > 0 and unchanged_ok > 0 and complex_ok > 0,
        "property sweep exercised all three classes (" ..
        tostring(classified_single) .. "/" .. tostring(complex_ok) .. "/" ..
        tostring(unchanged_ok) .. ")")

    -- Repeated runs: byte-identical decisions across executions.
    local function decision_digest()
        local acc = {}
        local s2 = 987654321
        local function rnd2(n)
            s2 = (s2 * 1103515245 + 12345) % 2147483648
            return (s2 % n) + 1
        end
        local pool = {"p","q","r","s","t"}
        for i = 1, 400 do
            local size = rnd2(5)
            local base = {}
            for k = 1, size do base[k] = pool[k] end
            local prop = {}
            for _, x in ipairs(base) do prop[#prop + 1] = x end
            for i2 = #prop, 2, -1 do
                local j = rnd2(i2)
                prop[i2], prop[j] = prop[j], prop[i2]
            end
            local c = SD.classify_permutation(base, prop)
            local sig = c.kind .. ":" .. (c.move and
                (c.move.item .. ">" .. tostring(c.move.after)) or "")
            acc[#acc + 1] = sig
        end
        return table.concat(acc, ";")
    end
    local d1, d2 = decision_digest(), decision_digest()
    eq(d2, d1, "repeated runs produce identical decision streams")
end

print(string.format("semantic_ordering TOTAL: %d passed, %d failed",
    passed, failed))
if failed > 0 then os.exit(1) end

# ReorderingMenus — Reference Semantics

This document defines the current data-pipeline contract. It is the
conformance baseline for the state machine, differential fuzzing, and future
refactors; dated review documents are historical evidence rather than
competing specifications.

Pipeline under specification:

    registry -> materializer -> validator -> native_writer
    canonical intent kept in intent_store.lua

---

## 1. Canonical intent

Canonical intent (`reorderingmenus_intent.lua`) is the single source of
truth. The native per-view order files (`<view>_menu_order.lua`) are
*derived caches*. A sidecar (`reorderingmenus_materialization.lua`) binds
each native file to the intent generation that produced it so staleness is
detectable.

Collections (per view):

| collection         | record shape                     | meaning |
|--------------------|----------------------------------|---------|
| hidden             | id -> {provider, origin}         | item/tab hidden; era-stamped |
| parent_override    | id -> {provider?, parent}        | explicit re-parenting |
| position_override  | id -> {after?/before?, provider?}| one-row relocation anchor |
| order_override     | menu_id -> {entries={id,provider}[]} | explicit bulk sequence; item entries only |
| custom_menus       | id -> {title}                    | user-created submenu identity/title |
| separators         | key -> {parent, after}           | sole divider-placement authority |
| raw_override       | menu_id -> {list=table}          | isolated verbatim passthrough |
| tab_order          | id[]?                            | explicit tab bar order |

`parent_override` is the sole parent authority for custom containers as well
as moved rows. A level with `raw_override` has no simultaneous
`order_override` or separator records. Historical inline separator tokens and
raw/semantic conflicts are normalized deterministically on load.

### S1 — corrupt canonical intent must never silently vanish

**Contract:** if the canonical file cannot be parsed or fails validation,
the exact original bytes are quarantined to
`reorderingmenus_intent.lua.corrupt-<time>`, a structured problem report is
returned, and loading continues from a clean (or deterministically
repaired) state. The pre-corruption content must remain recoverable.

**Status:** FIXED this cycle. Previously `load()` silently fell back to
`newState()`, so the next save permanently destroyed all customization.
Evidence: `tests/test_corrupt_canonical_intent.lua` (71 assertions,
C1–C4 contract).

### S2 — deterministic repair, no silent sanitization

Record-level malformations (malformed sequences, dangling custom-menu
parents, bad eras) are repaired deterministically *after* quarantine, and
every repair is reported in the problems list. Healthy files are never
rewritten (C4). Whole-collection corruptions coerce only the reported
collections and are flagged `malformed_collection`.

---

## 2. Materialization

`Materializer.resolve(reg, intent)` produces
`{tabs, lists, disabled, custom_titles, unplaced}`.

### S3 — ID-based correctness

All ordering decisions key on stable IDs. Display titles, translations,
and sort widgets never influence persistence or identity.

### S4 — untouched-follows-current-default

An untouched stock ID renders at its default parent, in default relative
order, unless its level was explicitly reordered (order_override /
separators / incoming parent_override) or its home level no longer exists
in the projection (validator cascades it to `KOMenu:disabled`).

### S5 — customized-user-intent wins

Explicit user records beat defaults while their provider era applies.
Provider-less ghosts keep dormant canonical intent but do not materialize
into visible lists. A different provider serving the same ID does not inherit
the dormant records. If the original provider returns, its records apply
again.

### S6 — resolution is history-free

No previous-list snapshot participates in resolution. The current registry
and canonical intent completely determine the graph, so a KOReader/defaults
change cannot inherit a stale in-memory arrangement.

### S7 — emit == re-import (native fixpoint)

The native file written for a state must, when imported by a fresh
session, reproduce the same semantic projection. Two fixes enforce this:

Divider import normalizes placement into anchored separator records, and the
served graph is always re-derived from the committed canonical state. The
second import of plugin-emitted bytes must be a semantic no-op. Evidence is
provided by `test_differential_fuzz.lua`, external-edit lifecycle suites, and
restart-equivalence suites at the runner's selected tier.

### S8 — sparse emission

A menu key is emitted only when its materialized list deviates from the
pure-default derivation. This makes the native file minimal and keeps the
"no customization == stock behavior" property.

---

## 3. Validation & safety nets

### S9 — validator cascade

Hiding or orphaning a container sends its entire subtree to
`KOMenu:disabled` so MenuSorter never orphans members as `NEW:` entries.
When cascading, the validator emits traversal order (container first, then
unreachable levels); without a cascade, `disabled` preserves
`hidden_order` relative order followed by sorted extras.

### S10 — sorting-hint guard / airbag

`koreader_adapter` wraps `MenuSorter.sort`: on upstream crash it retries
with sanitized inputs and logs. Stock indexes `menu_buttons[1]`
unconditionally; an empty bar remains fatal and is re-raised. Production
never emits an empty bar.

### S11 — transactions are spent on commit

A committed transaction's staged table aliases canonical state; reusing it
would let edits mutate canonical state without a durable write.
`ensureTxn` replaces committed/discarded transactions. Mutation-tested.

### S12 — crash-safe commit order

Canonical intent commits first, native file second. A crash between them
leaves a lagging derived file that `syncView` detects via the sidecar's
bound generation and regenerates.

---

## 4. Reset semantics

### S13 — reset_submenu resets everything that places items in that menu

Resetting a menu clears its order_override, raw_override, separators owned
by it, foreign children pulled back, **and every position_override whose
item lives in that menu**. Status: FIXED (anchors previously survived,
keeping the dragged arrangement alive across reset+save+restart).
Evidence: promoted fixture `seed-*-*-reset_submenu`, probe
`probe_reset_order.lua`.

### S14 — reset_all == fresh current base

Any valid state reduced by Reset All equals the stock derivation under the
current defaults era.

---

## 5. Semantic boundaries

### B1 — cross-menu preset membership

Presets carrying `parent_override` records re-home items across menus. Arrival
slotting can shift untouched siblings' absolute indices, but their relative
order is preserved. This is a membership change, not an ordering claim over
the untouched siblings.

### B2 — raw external levels

Raw fallback is limited to hand-authored levels that cannot be represented
losslessly in the live registry. It does not make malformed entries live and
does not override explicit hidden or moved-away semantics. Once present, the
raw record is the exclusive ordering authority for that level.

---

## 6. Testing stack map

| layer | suite | catches |
|---|---|---|
| corruption contract | test_corrupt_canonical_intent | silent data loss, repair regressions |
| legacy invariant SM | test_state_machine | direct intent.* mutations, ~25k checks |
| manager-verb SM | test_state_machine_verbs (+ sm_world) | full alphabet through real write path |
| shrinking/fixtures | tests/lib/shrinker.lua, fixtures/, test_regressions_generated | regression permanence |
| differential | test_differential_fuzz | native fixpoint, serialization determinism |
| mutation | tests/mutation_test.lua | dead safety logic |
| tiers | `TIER=quick|ci|nightly|soak ./run_tests.sh` (`tests/run_tier.sh` delegates here) | scaled random coverage |

Generated ids in the SM (`xitem%d`, `nitem%d`, presets `sm<seed>_<n>`) are
per-world counters: module-level counters leaked state between worlds in
one process and broke reproducibility (fixed).

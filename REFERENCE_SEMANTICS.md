# ReorderingMenus — Reference Semantics

This document defines what the plugin's data pipeline is *supposed* to do,
records where current behavior diverges from the documented contract, and
cites the probe/test evidence for each claim. It is the conformance
baseline for the state machine, differential fuzzing, and future refactors.

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
| hidden_order       | string[]                         | user hide sequence (order preserved for UI) |
| parent_override    | id -> {provider?, parent}        | explicit re-parenting |
| position_override  | id -> {anchor, before}           | single-relocation drag anchor |
| order_override     | menu_id -> id[]                  | bulk frozen sequence |
| sequence_eras      | menu_id -> id -> provider-era    | which era each sequence member belongs to |
| custom_menus       | id -> {title, parent}            | user-created submenus |
| separators         | key -> {parent, index?}          | separator placements |
| raw_override       | menu_id -> table                 | dense passthrough |
| tab_order          | id[]?                            | explicit tab bar order |

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

`Materializer.resolve(reg, intent, prev_lists?)` produces
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
Provider-less ghosts keep dormant intent but **must not materialize into
visible lists** (see §5 divergence D1 — current behavior differs; captured
for review rather than silently changed).

### S6 — update healing anchors within an era only

`prev_lists` anchoring ("rows the previous layout knew keep their
arrangement") is legitimate *within* one defaults era. Across a defaults
identity change (KOReader update), the old arrangement must not anchor the
new projection. **Status:** FIXED (`s.last_graph = nil` on rebuild;
mutation-tested as `era-graph-drop`).

### S7 — emit == re-import (native fixpoint)

The native file written for a state must, when imported by a fresh
session, reproduce the same semantic projection. Two fixes enforce this:

1. `resolve` collapses adjacent duplicate separators (import normalizes
   them; emitting doubled forms made persisted bytes diverge from restart).
2. `saveOrder` caches the *written* graph (`last_graph = repaired`) so the
   served projection equals persisted bytes instead of a stale
   prev_lists-anchored arrangement.

Evidence: `tests/test_differential_fuzz.lua` (12 seeds x 40 steps green).

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

## 5. Known divergences (captured, not silently changed)

### D1 — ghost materialization

Documented contract: provider-less ghosts retain dormant intent but do not
render. Observed (probe `probe_ghost_semantics.lua`): ghost rows DO appear
in emitted lists; real MenuSorter later drops them at render time because
no widget supplies the item. Existing test G1 asserts presence-in-intent,
G3 checks editor lists but not the hint-home menu where the ghost lingers.
**Decision needed:** change materializer to filter ghosts from lists, or
amend the docs. Tests currently encode observed behavior.

### D2 — preset apply vs minimizeIntent interaction

Applying a preset whose snapshot governs a surface can drop records that
prev_lists anchoring made look redundant; the session view may briefly show
an arrangement with less backing than the file will later reproduce.
Auto-promoted fixtures under `tests/fixtures/regression/` capture concrete
histories (replayed by `test_regressions_generated.lua`). These are known-
failing on purpose: they turn green exactly when the divergence is fixed,
at which point the fixture retires itself.

### D3 — cross-menu preset import ordering

Presets carrying parent_override records re-home items across menus; the
arrival slotting of those items can shift untouched siblings' absolute
positions (relative order among untouched siblings is preserved). I7
treats menus with incoming parent_override as "membership altered" and
skips default-sibling comparisons there.

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
| tiers | tests/run_tier.sh quick/ci/nightly/soak | scaled random coverage |

Generated ids in the SM (`xitem%d`, `nitem%d`, presets `sm<seed>_<n>`) are
per-world counters: module-level counters leaked state between worlds in
one process and broke reproducibility (fixed).

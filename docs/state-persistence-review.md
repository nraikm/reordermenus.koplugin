# Reordering Menus — State/Persistence Review (Final)

> **Historical audit snapshot.** The suite counts, schema references, open
> decisions, and implementation notes below describe the 2026-08-23 review.
> They are retained for provenance, not as current specifications. Use
> `REFERENCE_SEMANTICS.md`, `docs/architecture.md`, and
> `docs/migration-policy.md` for the current contract.

Date: 2026-08-23 · Reviewer lane: ox-alpha (test infrastructure + coordinated production fixes)
Verification: `./run_tests.sh` → **95 suites passed, 0 failed, exit 0** (quick tier), plus repeated-run stability checks on the touched suites.

---

## 1. Architectural issues found

### A1 — stageList equality-branch anchor probe compared unlike lists (CRITICAL, fixed)
`MenuOrderManager:stageList`'s "arrangement equals default derivation" branch probes anchor redundancy by resolving the section *without* an anchor and comparing to `expected`. The resolved list is separator-inclusive; `expected` was separator-stripped. On any menu whose stock list contains dividers (`search`, `more_tools`, …) the comparison could never succeed, so **a move-away + inverse-drag froze a bogus `position_override {after="opds", provider="stock"}` into canonical intent** — a false customization claim contradicting untouched-follows-default (S4). Reproduced standalone; fixed by stripping separators from the probe (`menuorder_manager.lua`, equality branch). Regression suite: `tests/test_anchor_noop_residue.lua` (A1–A5).

### A2 — Preset apply carried over records for unmentioned STOCK ids (HIGH, fixed)
`Presets.applyUserIntentPreset` carried every record whose id was outside the preset footprint, including stock-resident ids. Consequence: save a preset → move a stock item → apply the preset ⇒ **the churned move survives the apply**. A preset could never undo post-capture customization of a stock row, violating §8's principle. Fixed: carry-over now applies only to ids with no live stock home (plugins/ghosts the snapshot could not know); unmentioned stock rows follow current defaults. `reg` threaded from `loadPreset`; nil-reg callers keep legacy behavior.

### A3 — Runner P0-A guard compared knob families across suites (MEDIUM, fixed)
`run_tests.sh` matched tier `SM_STEPS=80` against any suite's `steps=` banner, so the differential fuzz (`DF_STEPS=40`) and gen1 determinism failed green runs by construction. Guard is now suite-aware (SM / DF / ITERATIONS families checked only for their own suites).

### A4 — Crash-pipeline suite not runnable from the runner (MEDIUM, fixed)
`test_crash_pipeline.lua` hard-exits in its crash stage; run bare it always "failed". The runner now drives it through `tests/run_crash_pipeline.sh` (crash process + recovery process), matching real crash/restart semantics.

### A5 — I16 cascade model missed hint-homed and custom-menu rows (MEDIUM, fixed)
`sm_world.check()`'s I16 expected-disabled model detected cascades only for stock rows (`node.default_parent`). Two real behaviors were unmodelled: (a) a freshly installed plugin row whose sorting_hint tab is hidden cascades into disabled; (b) custom submenus cascade when their parent level disappears. Both detectors extended; the flaky I16 failures disappeared (8/8 stable runs).

### A6 — reader_fm_switch served a stale cached projection (LOW, fixed)
The SM switch verb changed `w.view` without re-syncing the target view, so the next check could compare a pre-switch cached arrangement against current defaults (I7 order noise). Switch now drops and re-syncs the target view — mirroring what the real UI does when opening the other surface.

### A7 — Test-harness drift (LOW, fixed)
Single-return `createSubmenu` misuse in pairwise matrix (got `true`, not the id); missing `saveOrder` before a restart that asserts durability of staged work; stale `go_to: location→search` assumptions after KOReader moved it under `navi`; M5 expecting a fixed quarantine filename vs timestamped backups; IO3 assuming the intent file exists after a semantic no-op save.

### A8 — Divergence D1 remains open (documented, decision needed)
Moved ghosts still render at their retained home (REFERENCE_SEMANTICS §5 D1). Two suites previously encoded opposite expectations; ghost_isolation G1 (presence) matches documented behavior and passes; pairwise was aligned to single-parent retention. Recommend deciding: either filter ghosts from projections (materializer change) or amend docs — tests currently encode observed behavior.

### A9 — Legacy unstamped sequences (accepted risk, documented)
Unstamped bulk sequences still apply unconditionally (compat). Inferred stamps are unsafe in general: attribution requires knowing which provider arranged each row at capture time. Mitigations in place: presets written by this build always stamp; v0/v1 migrations preserve semantics losslessly; era flips release auto-anchored pins. Recommend leaving as-is and letting GC ("Forget stale customizations") be the escape hatch.

---

## 2. Recommended changes (ranked)

| # | Rank | Change | Status |
|---|---|---|---|
| 1 | Critical | Strip separators in stageList anchor-redundancy probe | **Done** |
| 2 | High | Preset carry-over limited to non-stock ids | **Done** |
| 3 | Medium | Suite-aware P0-A config guard in runner | **Done** |
| 4 | Medium | Crash pipeline driven as multi-process pair | **Done** |
| 5 | Medium | I16 cascade model covers hint homes + custom menus | **Done** |
| 6 | Low | reader_fm_switch re-syncs target session | **Done** |
| 7 | Low | Harness drift fixes (pairwise/presets/M5/IO3/RT7) | **Done** |
| 8 | Low | Retire 29 XPASS fixtures after root-cause fixes | **Done** |
| 9 | Optional | Decide D1: filter ghosts from projection or amend docs | Open |
| 10 | Optional | Nightly mutation matrix M1–M18 incl. STALE→exit 1 | Open |

## 3. Exact new test suites added

* `tests/test_anchor_noop_residue.lua` — move+inverse leaves zero records on separator-bearing menus, across save and restart (RED→GREEN for A1).

## 4. Concrete table-driven cases verified (existing suites audited, all passing)

* Roundtrip RT1–RT9 (moves/hides/separators/custom submenus/ghosts/bulk/tabs/simultaneous views/adversarial two-row shuffle) + randomized DF fuzz (8×40 quick).
* Minimal import: same-parent reorder, one-item-to-end, block move, reversal, cross-parent move, hide/unhide via `KOMenu:disabled`, separator insert/remove/move, unknown id, unknown menu key, removal-without-disable (`semantic_diff` classes: single_move/block_move/reversal/removal/addition/bulk).
* Malformed-but-parseable Lua N1–N13: string/bool/table-of-tables lists, numeric ids, duplicate ids, id under multiple parents, duplicate root tabs, sparse arrays, map keys in lists, cyclic tables, unknown root keys, invalid disabled shape, empty/missing roots, multi-parent import.
* Schema: v0→v2, v1→v2 migration, future-version quarantine (stable-name artifact), unknown-field tolerance, idempotence.
* Transactions T1–T7: same-generation txns, conflicting moves, hide-vs-move, double commit, commit-after-discard, stale refusal, external edit while txn open; plus rollback-on-failed-commit (IO3) and no-op commits not advancing generation.
* Multi-process restart P1–P3 (separate luajit processes, package.loaded leakage, guard per-process flags).
* Crash boundaries: intent-committed/no-native, Reader-written/FM-lagging, sidecar-last, temp-validate-rename window.
* Preset futures P1–P5 (default parent change, stock reorder, new stock entry, ghost lifecycle, provider identity), preset robustness (truncation, traversal names `../x`, `/x`, case collisions, Unicode/emoji, huge names), reset metamorphics R1–R4, tombstone GC G1–G5.

## 5. Property/metamorphic tests

Emit/import fixpoint (S7), serialization determinism, reset-all ≡ fresh-install-under-current-world (R1–R4), dirty-state equivalence C1–C7 (now truly clean after the A1 fix), pairwise feature-interaction matrix (66 pairs, 97 assertions), randomized state machines (~25k invariant checks/ci-scale) with ddmin shrinking and fixture promotion.

## 6. Migration strategy

v0/v1→v2 migrators are idempotent, converge through one durable write, never quarantine healthy files, initialize `meta.generation=0`, and are covered by historical-fixture tests including process-boundary reload. Legacy unstamped sequences remain unconditional-by-design (A9); era flips release pins; GC is the user-facing escape hatch.

## 7. Transaction/concurrency strategy

Monotonic global + per-view generations bound into transactions; committed/failed transactions are spent (`store_epoch` guard); record-level three-way rebase (`mergeSection`) with `stale_transaction` refusal; sidecar binds native files to `intent_gen` so lagging derived files regenerate instead of being misread as hand edits; atomic rename everywhere (temp parse-back validate before rename); quarantine artifacts use stable names with collision fallback. No silent lost updates observed across the concurrency suites.

## 8. Residual risks (bugs the design can still exhibit)

1. Cross-view commit rebases replace the other view's canonical section; its sidecar legitimately lags until next sync — benign but visible as regeneration churn (retry-filtered in SM).
2. Divergence D1 (ghost visibility) needs a product decision (see A8).
3. Legacy unstamped sequences can shadow upstream reorders indefinitely until reset/GC (accepted compat trade-off).
4. Concurrent processes share the settings dir without locking; generation checks detect staleness for intent, but native-file last-writer-wins between two simultaneous KOReader instances remains unsupported-by-design (single-instance assumption).

## Files touched (this review)

* Production (announced in COORDINATION.md): `menuorder_manager.lua` (A1 fix + preset reg threading), `presets.lua` (carry-over policy).
* Tests: new `tests/test_anchor_noop_residue.lua`; fixes to `run_tests.sh`, `tests/run_crash_pipeline.sh` wiring, `test_schema_migration.lua`, `test_presets.lua`, `test_pairwise_matrix.lua`, `test_native_semantic_roundtrip.lua`, `test_historical_fixtures.lua`, `test_io_failure_injection.lua`, `tests/lib/sm_world.lua`, `tests/lib/failure_sig.lua` consumers (39+3 stale fixture signatures retired, 29 XPASS fixtures retired).
* Docs: COORDINATION.md cross-lane announcements.

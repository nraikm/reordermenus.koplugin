# ReorderingMenus — Testing Strategy Review

> **Historical audit snapshot.** Counts, failures, recommendations, and tier
> defaults below record the state observed during that review. They are not
> current release evidence. `run_tests.sh` is the authoritative tier
> definition; the README documents current invocation and replay commands.

**Ground truth for every number below:** I ran these suites on this machine (KOReader.app bundled luajit) while writing this review, not from the README.

---

## 0. What the audit actually found (read this first)

The testing infrastructure is **far stronger than the brief describes**, and simultaneously **weaker than its own headline numbers suggest**. Both halves matter.

### Already built (the brief undersells the repo)

| Brief asks for | Status in repo |
|---|---|
| Tiered state-machine scale (§1) | `run_tests.sh TIER=quick/ci/nightly/soak`; suite headers document PR 6×60 → soak 500×1000 |
| Shrinking to minimal reproducers (§2) | `tests/lib/shrinker.lua` (ddmin + budget) + auto-promotion of shrunk fixtures + `test_regressions_generated.lua` replay loop |
| Expanded alphabet (§3) | `sm_world.lua`: **30 verbs**, args frozen at pick time, incl. presets, mirroring, custom submenus, external native edit/deletion, Reader/FM switch, restore-default, reset submenu/view, A→Z/Z→A |
| Invariant battery (§4) | 13+ checks per step (I1–I16), incl. real-MenuSorter render oracle, no-fabrication walk, native fixpoint, serialization determinism, restart equivalence |
| Differential fuzz vs real KOReader (§6) | `test_menusorter_differential_fuzz.lua` (model graph → native file → real MenuSorter → rendered-tree comparison) and `test_differential_fuzz.lua` (round-trip fixpoint) |
| Metamorphic properties (§7) | `test_reset_metamorphic.lua`, `test_txn_concurrency.lua`, restart/hide/mirror suites, pairwise interaction matrix |
| Corrupt-state handling (§16) | `test_corrupt_canonical_intent.lua` (71 assertions), quarantine + deterministic record-level repair |

### What running them just exposed

1. **"33 passing suites / 0 failures" is a quick-tier statement.** At CI scale (`SM_SEEDS=20 SM_STEPS=200`) the verb state machine produced **7 invariant violations**. At nightly scale (100×500, 7m44s wall): **45 violations** across ≥4 distinct signatures.
2. **Two live bug classes are now pinned as two-line fixtures** (auto-shrunk during my run):
   - `seed-712710-step-8`: `stage_list_permutation(setting)` → `reset_submenu(setting)` — **Reset Submenu does not restore default order** after a staged permutation (I7 violation).
   - `seed-7919-step-187` etc.: cross-view commit during a Reader↔FM switch leaves stale sibling order in `navi`/`exit_menu`/`tools` until the next save (I7 violation).
3. **Generation-1 SM is not actually reproducible across processes**: candidate IDs come from `pairs(reg.nodes)` (LuaJIT hash order varies per process), so identical seeds pick different operations each run — observed totals 24,423 / 25,170 / 25,475 assertions for the same config. Its "seeds" only reproduce within one process.
4. **Known-fail normalization risk**: 33 permanent failing fixtures are counted as *passes*. The day one of those files silently stops reproducing the original bug (e.g. because an unrelated change altered which failure fires), nothing notices — retirement is automatic but equivalence is unchecked.
5. **Mutation testing is currently 1 mutant** (`mutation_test.lua`, quarantine neutralization). The mechanism is sound; the matrix doesn't exist yet.
6. The **search→action UI flow** has one test that opens the results dialog and closes it. No drag-in-search, no hidden-row-in-search, no index-staleness coverage — despite `showSearchResults` passing positional `idx` into the action dialog (safe today only because every action re-runs the search).

---

## 1. Scale up the state machine (measured tiers)

Measured on this machine (M-series Mac, luajit):

| Tier | Gen1 (pure pipeline) | Gen2 (manager verbs) | Verdict |
|---|---|---|---|
| current default | 12×120 ≈ **1.2 s** / 6×60 ≈ **3.4 s** | same | far too small — hides real bugs |
| PR | 25×120 (**~1 s**) | 8×80 (**~5 s**) | keep under ~15 s |
| CI | 50×300 (~3 s) | 20×200 (**36 s**) | keep under ~60 s |
| nightly | 200×500 (~8 s) | 100×500 (**7m44s**) | fine overnight |
| soak | 500×1000 (~30 s est.) | 400×1200 (~2.5 h est.) | weekly/scheduled |

Notes:
- Gen1 is nearly free; there is no reason to ever run it at 12 seeds again. Gen2 dominates cost because every op goes through transactions + disk commits.
- The prompt's example nightly (100×500) is exactly right for gen2 — it found **45 failures** where quick found zero.
- Add a **seed-bank mode** (`SM_SEED_LIST="7919,15838,..."`) so CI replays last night's exact seeds plus fresh ones, making regressions-to-green auditable.
- **Gate**: CI must run gen2 at ≥20×200 or it is decorative. Today's default 6×60 demonstrably misses everything.
- **Knobs can be dropped silently** (observed during this audit): invoking the suites with `SM_SEEDS=…` in a context where the variable isn't exported makes them quietly run the default tier — indistinguishable from a real nightly in the pass/fail summary. Fix: each suite prints its *effective* `SEEDS × STEPS / ITERATIONS` line at startup, and `run_tests.sh` greps for it after each run, failing loudly on mismatch. A tier system you can't verify is a tier system you don't have.

## 2. Shrinking (exists — close the remaining gaps)

Current: ddmin over history chunks, replay budget (300), collapse of consecutive duplicate ops, executable `{ seed, history }` fixtures, replayed forever by `test_regressions_generated.lua`. Evidence it works: 287-step histories shrank to 2 ops in my run.

Improvements, in priority order:
1. **Simplify arguments** (second ddmin dimension): after chunk deletion stalls, shrink each op's args — shorter titles, smaller permutations, earlier menu indices, drop optional fields. A `stage_list_permutation(seq=9 ids)` that survives as `[A,B]` reads better and fails faster.
2. **Minimize the menu tree** (third dimension): shrink the world's defaults/registrations before replay — try deleting stock menus/items while the predicate still fires. Target: every fixture names the smallest tree that breaks.
3. **Generalize minimization** ("nice to have"): attempt replacing specific IDs with wildcards to detect coincidental passes.
4. **Structured failure log**: when promotion happens, also emit `fixtures/regression/<name>.md` with the invariant tag, the shrunk step list, and `SM_SEED=<n> ./luajit ...` reproduce lines. Fixtures are already executable; add the human-facing half.
5. **Fix gen1 determinism first** (sort candidate lists before `rand(#list)`). Until then, gen1 failures can't be promoted at all — only gen2's frozen-args history replays across processes.
6. **Retirement safety** (§0.4): before deleting a fixture that now passes, assert its recorded failure signature matches the *current* failure signature captured at promotion; if the signature changed, flag instead of retire.

## 3. Alphabet (30 verbs — the actual gaps)

Present: moves, drags, stageList, hide/unhide/tab-hide, restore-default, separators, tab reorder, create/delete submenu, sort A→Z/Z→A, save/preset apply, reset submenu/view, mirroring toggle, copyLayout, restart, plugin install/uninstall/hint-change, upstream add/remove/reorder, external native edit, native-file deletion, view switching.

Add:
1. **Preset CRUD**: `update_preset` (overwrite), `delete_preset`, then reapply — preset refresh paths are separately coded (`test_preset_update_and_new_items.lua` covers them by hand, not randomly).
2. **Provider collisions**: install a plugin item whose ID equals an existing stock/custom ID (collision gating is a named safety mechanism with no random driver).
3. **Leaf↔submenu shape changes**: upstream turns a leaf into a container and vice-versa between saves.
4. **IO failure injection**: make `AtomicWriter.writeTable` fail on step N via an injectable fault hook; the SM should treat "save failed" as an environment outcome and require the invariant *state survives failed saves unchanged*.
5. **Ghost GC**: `ghost_gc.lua` has no verb; forgetting tombstones mid-history exercises reinstall-vs-resurrect semantics randomly.
6. **Language change**: reload gettext tables mid-run (identity must be title-independent — L-contract).
7. **Weight retuning**: `reset_view`=1, `copy_layout`=1, `delete_native_file`=1 rarely fire at 200 steps. Consider a second weight profile for soak runs that doubles rare ops.

Keep asserting the full battery after **every** operation (already true); the restart-equivalence check stays sampled (`SM_RESTART_EVERY`) since it costs a double reload.

## 4. Invariants — current set, then what's missing

Existing (verified in `sm_world.check()`): I1 render-safety (real MenuSorter) · I2 single-parent · I3 hidden-gone · I4 acyclic · I5/I11 determinism (resolve twice; save twice byte-equal) · I6 user-wins (era-gated) · I7 untouched-follows-current-default (+relative order) · I8 restart equivalence · I9 native fixpoint · I10 rendered-exactly-once both directions · I13 no fabrication (no `NEW:` leaks) · I15 sequence survivor order · I16 disabled-list contract.

Proposed additions — ordered by expected bug yield:

| # | Invariant | Why it will catch real bugs |
|---|---|---|
| N1 | **Idempotence of resolution**: `resolve(reg,I)` twice == deep-equal (not just fingerprint) AND `materialize→emit→reimport→materialize` stable after *every* op, not just saves | catches drift the fingerprint misses (metatable junk, key churn) |
| N2 | **Canonical intent redundancy bound**: after `saveOrder` (which runs `minimizeIntent`), no record may be deleted without changing the projection — i.e., minimized intent is truly minimal | directly tests the minimizer; a no-op record surviving = future ghost-class bugs |
| N3 | **Same semantic state serializes identically**: build intent two different ways that should be semantically equal (e.g. drag-to-same-spot vs no-op; hide+unhide vs never hidden), dump both, bytes must match | catches canonical-form instability that makes merges/rebases noisy |
| N4 | **Era isolation**: for every record stamped provider P where live provider ≠ P, flipping the record must not change the projection | direct probe of provider-era gating without waiting for random upgrades |
| N5 | **Protected reachability**: `reordering_menus` item and ≥1 tab reachable in every projection (validator repairs this — verify the repair, don't trust it) | lock-out prevention is the plugin's cardinal sin |
| N6 | **Validator honesty**: any projection difference between raw resolve and post-validate must appear in `warnings`; no warning ⇒ graphs identical | validator is a repair engine; silent repairs are invisible corruption |
| N7 | **Cross-view independence**: ops in view A never change view B's projection unless mirroring/copyLayout was the op | isolates accidental shared-session bugs (the class behind several known-fails) |
| N8 | **Mirror involution**: mirror-on move M(A→B) then mirror-off reverse move must equal pre-move state in both views; mirrored effects never duplicate rows | ping-pong/duplication guard (mirroring recurses through `_mirrorVisibility` — see mutation M13) |
| N9 | **Search-index staleness**: after any op, all cached `(menu_id, idx)` pairs held by open UI flows either still resolve to their ID or the flow re-derives them | pins the "UI indices never become identity" rule at model level |
| N10 | **Depth bound**: materialization recursion ≤ explicit max depth; deeper trees rejected deterministically | prerequisite for §13 recommendation |

Also: **retire I7 exemptions aggressively.** The current I7 has five carve-outs (frozen menus, separator presence, incoming parent_override, unreachable home, cascaded ghosts). Each is documented, but together they're becoming a ratchet — the 33 known-fail fixtures are almost all I7/I16-shaped. When a fixture is fixed, delete its exemption if it became unnecessary.

## 5. Independent reference model

Status: none exists (`grep ReferenceModel` = empty; `REFERENCE_SEMANTICS.md` is a prose spec, not an implementation).

Design — `tests/lib/ref_model.lua`, sharing **zero** production code:

```lua
-- State: { items = {id → {parent, order_index}}, hidden = {id}, tabs = [ids],
--          customs = {id → {title, parent}} }   -- flat, no sequences, no anchors
-- Ops (same 30 verbs, trivial implementations):
--   move(id, dest)      → items[id].parent = dest; reindex dest sequentially
--   hide(id)/unhide(id) → hidden[id] = true/nil
--   reset_submenu(m)    → rebuild members of m from CURRENT defaults in default order
--   apply_preset(name)  → replace state wholesale with snapshot
--   restart()           → serialize state to disk, wipe memory, reload
--   external_edit(...)  → mutate the on-disk native file only
```

Deliberate simplifications (this is what makes it an oracle):
- **No provider eras**: records always apply (reference world keeps providers alive; era semantics get a dedicated unit suite instead).
- **No slot-alignment/healing**: reference stores absolute order indexes; production's cleverness around `insertAtStockSlot`/prev_lists is precisely what it must check.
- **O(n²) everything**: linear scans instead of registries.
- Comparison via a **semantic reducer**: `reduce(graph) = { id → (visible_parent | HIDDEN), relative_order_per_parent, tabs_order }` — compare reduced(production) == reduced(reference) after every op. Never compare internal representations.

Minimal semantics it must pin (from REFERENCE_SEMANTICS.md): S3 ID-based correctness, S4 untouched-follows-current-default, S5 customized-wins, S6-era gating (as "stamped other-provider ⇒ ignore"), S7 cascade invisibility, S9 reset-to-current-base, restart round-trip.

Where it pays first: the **reset_submenu-after-permutation** bug class (my two-line fixture) is exactly a place where production's healing walk diverges from naive semantics. Feed both models the fixture history; diff the reductions; the reference shows the intended answer directly in the failure report.

## 6. Differential fuzzing against real KOReader (strengthen what exists)

Both existing differential suites generate **synthetic item tables** for MenuSorter (`items[id] = {text=id}` style). That validates structure but not content fidelity. Add:

1. **Content-carrying fuzz**: give generated items realistic localized texts (incl. duplicates and Unicode from §11) so text-dependent paths inside MenuSorter (dedupe, orphan naming `NEW:` prefixing, separator attachment) execute for real.
2. **Cross-check the three projections per iteration**: expected materializer graph ↔ emitted native file ↔ walked rendered tree. Currently checked pairwise in two separate suites; unify into one harness with a single failure minimizer (reuse `shrinker.lua` — it takes any predicate).
3. **Run it under the verb world**, not just static generation: `DF_SEEDS/DF_STEPS` already exist; point the driver at `sm_world` so external edits + presets precede emission.
4. Keep per-seed process isolation (`DF_ONE_SHOT`) — correct call given singleton leakage.

## 7. Metamorphic properties (add as self-checking wrappers around the verb world)

Each property = run arbitrary history segment H, transform, compare. All fit in one new suite driving `sm_world`:

| Property | Oracle |
|---|---|
| Restart ≡ save/load | `H + restart + H'` vs `H + saveBothViews + dropSession + H'` — equal semantic FP (already I8-ish; make it a standalone property with random H′ tails) |
| Hide-cycle | `hide X; unhide X` returns X to its exact previous parent **and** relative position (position part is not asserted today!) |
| Move inverse | move X out, move back to recorded anchor ⇒ projection identical to baseline |
| Provider absence/return | uninstall provider P; reinstall P with same hint ⇒ all P-era records reapply (projection equals pre-uninstall modulo nothing) |
| Unrelated plugin | installing into menu M leaves every *other* menu's visible sequence bit-identical |
| Materializer idempotence | `saveOrder` ×k (k∈2..5) — projection and intent bytes stable (extends I11 beyond k=2) |
| Reset All | covered (`test_reset_metamorphic.lua` R1–R4) — port into randomized wrapper so the pathological state is *generated*, not handwritten |
| Mirror symmetry | mirror-toggle mid-history never changes the *un-mirrored* view; mirrored copies never stack (see N8) |
| Preset round-trip | `save_preset(S) → churn → apply_preset` ⇒ semantic FP equals FP(S) |
| Copy-layout involutive | `copyLayout(A,B)` twice == once (idempotent), and never touches A |
| External-edit convergence | hand-edit native file, import, re-emit ⇒ emitted file semantically equal to the hand edit (importer fixpoint; partially in `test_minimal_import`) |
| Separator transparency | inserting+removing a separator restores byte-identical intent |

## 8. Mutation testing — build the matrix

Mechanism exists (`mutation_test.lua`: mutate → run killer suite in subprocess → restore, crash-safe). Replace the 1-mutant list with the full matrix. Kill criterion: designated killer suite exits non-zero.

| # | Mutation (file) | Killer |
|---|---|---|
| M1 | remove provider-era check in `recordApplies` (materializer) | `test_provider_identity.lua` + gen2 SM |
| M2 | disable cycle breaking (validator `reaches`) | cycle suite + SM I4 |
| M3 | remove collision gating (custom-submenu creation) | `test_insert_menu_singleton.lua` / `test_submenu_safety.lua` |
| M4 | stop filtering ghosts from lists (materializer membership) | `test_ghost_isolation.lua` |
| M5 | atomic rename → direct write (atomic_writer) | `test_crash_pipeline.lua` |
| M6 | swallow persistence failure return (`saveOrder` returns true on commit error) | `test_io_failure_injection.lua`, `test_storage_resilience.lua` |
| M7 | allow committed-txn reuse (drop `self.discarded` guard) | `test_txn_concurrency.lua` T4/T5 |
| M8 | skip protected-item restoration (validator) | protection suite + N5 |
| M9 | allow multiple parents (remove single-parent filter) | SM I2 |
| M10 | remove sorting-hint guard (adapter) | `test_hint_migration.lua`, C6/C7 |
| M11 | stop writing/skipping `sequence_eras` | provider-identity + SM I6 |
| M12 | skip restart cache clearing (`reloadFromDisk` no-op invalidation) | `test_multiprocess_restart.lua` + SM I8 |
| M13 | make `_mirrorVisibility` recurse (pass `_mirrored=false` downstream) | mirroring suite + N8 |
| M14 | `minimizeIntent` drops records even when projection changes | N2 + `test_noop_and_sparse_purity.lua` |
| M15 | sidecar generation not bumped on write (staleness detection off) | `test_differential_fuzz` lagging-regeneration path |
| M16 | quarantine writes to /dev/null (corrupt bytes lost) | `test_corrupt_canonical_intent.lua` |
| M17 | empty-tab-bar repair removed (validator) | C-suite empty-bar case + SM I1 |
| M18 | `semantic_diff.infer_list_change` returns bulk for single move | `test_semantic_diff_unit.lua` + minimal-import |

Process requirements: run matrix on nightly only (each mutant = one killer suite run; ~20 min total at quick knobs); any SURVIVED row opens an issue naming the gap; mutants must fail **loudly** if their find-snippet drifts (currently prints STALE — make it exit 1 so drift can't silently empty the matrix).

## 9. Literal search-filtered drag (build it — highest-value UI gap)

New suite `test_search_flow.lua` driving the real dialogs (`showSearchDialog → showSearchResults → showItemActionDialog/showDestinationMenuChooser`):

Core scenario from the brief: underlying `A B C D E F`; query shows `B E`; drag/move E above B via dialog actions; clear search; save; restart; assert persisted order `…E B…` by ID.

Matrix around it:
- hidden row among results (`[Hidden]` branch → unhide path);
- query results go stale after an action (verify the re-search behavior is actually invoked — today safety rests on `showSearchResults` being re-called after each action);
- act → cancel dialog; act → discard-at-close; act → save;
- external native edit between action and save (import must win);
- duplicate display labels matching one query (two rows, distinct IDs — assert no cross-talk);
- search matching by ID vs by title (both branches of the `find` condition);
- RTL/Unicode query strings.

Assertion core: persisted records contain **IDs and anchors only** — grep the canonical section for any digit-index-derived artifact after each scenario.

## 10. UI state-machine testing

Screens: tab screen, item editor, submenu editor, search, hidden manager, preset dialog, destination chooser, dirty-close prompt. Two-layer approach rather than full random UI driving:

1. **Path-equivalence suite (deterministic, high value)**: for each semantic action, drive every entry point and compare resulting canonical sections byte-for-byte:
   - hide: checkbox tap vs hold-dialog Hide vs search-result Hide;
   - move: editor drag vs hold-dialog Move→chooser vs search→Move;
   - unhide: hidden-manager restore vs search→Unhide;
   - create submenu: hamburger flow vs submenu-editor "+" flow;
   - A→Z: widget-menu Sort vs sort-widget button.
   Any divergence = a bug class ("two UI paths that mean the same thing disagree").
2. **Random UI walk (nightly)**: reuse `sm_world` but route ops through the UI functions where headless-safe (existing suites already do this for editors — extend to chooser/search/hidden-manager). Compare canonical intent after each UI action against the equivalent data-layer verb applied to a twin world. Existing coverage proves checkbox-vs-hold for hide (test_ui_move_hide_plugin) — generalize it mechanically.

## 11. Input/display edge cases

Mostly covered for identity (L1–L5 localization suite, TITLE_POOL with Ångström/中文/long strings, duplicate-label tie-break). Gaps to add as one compact suite:
- emoji + ZWJ sequences + combining forms (é vs e+◌́) in titles **and** in custom submenu titles;
- RTL labels (Arabic/Hebrew) — assert stored IDs unaffected, rendering consumes real SortWidget (already possible headless per test_ui_robustness);
- long German/Finnish translations via a fake gettext catalog swap;
- tiny screen / XL font / portrait-landscape via CanvasContext overrides (affects paging math in editors, not persistence);
- root menu with many tabs; depth-N nesting (§13);
- **duplicate labels colliding in search results** (ties to §9).

Correctness stays ID-based everywhere — assert canonical bytes contain no title fragments.

## 12. A→Z collation

Confirmed: Sort A→Z calls stock `SortWidget:sortItems("natural")` — ordering follows **display text** through upstream's sorter, not locale collation.

Tests to add now (no production change):
- fixed set `A Å Ä Ö É e é ß 中` sorted A→Z and Z→A: assert **deterministic** result and **stable ID tie-break** for equal keys (two items titled identically must not swap between runs — currently guaranteed only by immigrant-append logic, not by the sort path);
- repeat sort twice ⇒ byte-identical sequence (sort idempotence — Lua `table.sort` is not stable!);
- sort containing separators ⇒ separators survive, positions defined;
- same test under a swapped language catalog ⇒ different order allowed, but still deterministic + tie-broken.

Recommendation: **document deterministic Unicode codepoint order** as the contract rather than implementing locale collation. Rationale: LuaJIT has no collator; embedding one (ICU) is disproportionate; KOReader itself doesn't expose one; and the actual user harm — unpredictability — is solved by determinism + tie-break. If sorting ever moves to translated titles at runtime (language switch changes order), add one metamorphic test asserting only *within-language* stability.

## 13. Deep/pathological trees

Generator-driven suite (synthetic defaults, no UI): depths 10/50/100/500 chains; 1,000-leaf single menu; 2,000 ghost records; 100 nested custom submenus; wide fan-out (one menu, 500 children).

Measure & assert:
- materialization + validation complete without stack overflow (LuaJIT default C stack kills deep *recursive* walks — validator's `reaches` and sm_world's `reaches` are recursive; convert or bound);
- cycle validation stays O(V·E)-bounded on adversarial chains;
- editor navigation and MenuSorter render time sane (<1 s @ depth 100);
- memory via `collectgarbage("count")` deltas.

**Recommend an explicit max custom depth (suggest 20–32) enforced at creation/import with a clear refusal toast**, plus a validator warning for imported deeper trees — turning a potential hard crash (C-stack) into a supported limit. Add the bound to N10.

## 14. Performance regression suite

New `tests/bench_pipeline.lua` (not part of pass/fail CI gates initially):

Synthetic states: 1,000 live IDs · 100 menus · 2,000 ghosts · 500 position overrides · 500 hidden · 100 custom submenus · 20 presets.

Micro-harness measures (os.clock, median of 5): registry build · resolve · validate · minimizeIntent · serialization (dump+write) · reloadFromDisk · preset apply.

Watch specifically: `minimizeIntent` is O(records × resolve) — quadratic by construction; `assembleMenuList` does repeated `indexOf` scans (quadratic in menu length); validator `reaches` is O(V²E) worst case. These are the accidental O(n²) traps the benchmark exists to catch.

CI thresholds: **ratio gates, not seconds** — e.g. fail if resolve(1000 IDs) > 40× resolve(100 IDs) (superlinear detector) or if any op exceeds 5× its rolling 10-nightly median. Absolute-time gates flake; scaling-shape gates don't.

## 15. Diagnostics — `explainItem`

Doesn't exist; build `explainItem(view, id)` in the manager returning a plain-data record:

```
{ provider, era_stamps={hidden:P,parent_override:P,seq_eras:{...}},
  default_parent, effective_parent, membership_source (default|override|custom|immigrant),
  anchors={after/before, applied?}, hidden_state, is_ghost, collision_state,
  resolved_parent, decision_trace={"user override wins (era matches)", ...},
  emitted_native_position, warnings[] }
```

Plus `World:explain(id)` in sm_world. Wire-in (cheap, immediate payoff): when any invariant check fails, auto-attach `explainItem` output for the offending ID(s) to the failure line and into the promoted fixture header comment. Failure reports become self-explaining ("X is under tools because parent_override stamped by plugin p1 still applies"), which shrinks triage of the 45-failure nightly runs to minutes.

## 16. Persistent invariant checker / repair logging

Current state is genuinely good: load-time `collectProblems` (malformed records/collections, dangling refs, inconsistent order, self-cycle, bad era), verbatim quarantine with timestamped backup, deterministic record-level repair, problems surfaced, healthy files never rewritten, `test_corrupt_canonical_intent.lua` corrupts collections individually.

Remaining recommendations:
1. **Repair journal**: append structured repair entries to `reorderingmenus_repairs.log` (timestamp, kind, view, collection, key, action). Today repairs live only in the returned problems table — invisible after load unless something reads it.
2. **Post-repair verification**: after `repairProblems`, run `collectProblems` again and require zero problems (repair completeness is currently assumed).
3. Extend the corruption generator: cross-collection inconsistencies (hidden record whose provider contradicts sequence_eras), duplicate parents across views, schema-version downgrade attempts — one test per collection *and* per cross-collection pair.
4. Surface the problems count in the plugin's own UI (Settings screen badge) — silent-but-backed-up is better than silent, observable is better still.

## 17. Coverage philosophy

Where assertion counts mislead here: the 24k "invariant checks" are dominated by I5 (double resolve) firing every step — cheap confidence, low marginal value per extra step. Meanwhile whole branches sat untouched until tonight (search flows, preset update/delete under random histories, IO-failure verbs).

Signal ranking **for this project specifically**:
1. **Randomized state machine at honest scale** — tonight it produced more real bug evidence in 8 minutes than months of handwritten suites (45 failures, 40 minimized fixtures). This is the project's crown jewel; feed it, don't prune it.
2. **Mutation testing** — the only technique that measures whether the suite would notice. With 17 safety mechanisms enumerated, it converts "we have tests" into "we have killers."
3. **Differential vs real MenuSorter** — the ultimate integration oracle, already strong; make inputs content-realistic.
4. **Reference-model differential** — best failure *explanations*, moderate setup cost; do after mutation matrix.
5. **Fault injection** — narrow but irreplaceable (crash windows, IO failures); mostly built.
6. Line/branch coverage (luacov) — useful only as a *gap finder* feeding the above; low standalone signal, worth wiring into nightly to list untouched branches, worthless as a target percentage.

---

## Prioritized roadmap

| P | Item | Effort | Payoff |
|---|---|---|---|
| **P0** | Triage the 2 live bug classes (reset_submenu-after-stage; cross-view-switch stale order) using the already-minimized fixtures | days | real user-visible bugs fixed |
| **P0** | Make CI actually run CI tier (`run_tests.sh` default → ci for gen2; fix env-export path in run_tests.sh) + fix gen1 `pairs()` nondeterminism | hours | the suite you have starts working at scale |
| **P1** | Fixture-retention policy: signature-checked retirement (§2.6); keep known-fail list bounded (≤25, force triage beyond) | hours | prevents known-fail normalization |
| **P1** | Mutation matrix M1–M18 + STALE→hard-fail | 1–2 d | measures the suite for the first time |
| **P1** | New invariants N2, N4, N5, N6, N7 (cheap, model-level) | 1–2 d | whole classes: silent repairs, era leaks, cross-view bleed |
| **P2** | Search-flow literal suite (§9) + path-equivalence suite (§10.1) | 2–3 d | closes the biggest UI blind spot; kills index-identity class |
| **P2** | Alphabet additions (preset CRUD, collisions, IO faults, GC verb, shape changes) | 2 d | random coverage of separately-coded paths |
| **P2** | Metamorphic wrapper suite (§7) incl. mirror involution, hide-cycle position | 2 d | property classes, near-zero maintenance |
| **P3** | `explainItem` + auto-attach on failure (§15) | 1–2 d | makes every future failure cheap to read |
| **P3** | Repair journal + post-repair verification (§16) | 1 d | observability of corruption handling |
| **P3** | Reference model (§5) wired into verb world | 3–5 d | strongest oracle + best diffs |
| **P3** | Deep-tree bounds + perf ratio gates (§13–14) + collation determinism tests (§12) | 2–3 d | crash-proofing + regression tripwires |
| **P4** | Nightly luacov gap report (§17) | hours | finds the next blind spot |

## Deliverable 10 — claims weaker than they appear (summary)

1. "**0 failures**" — true only at a tier that misses everything; 7 failures at CI, 45 at nightly.
2. "**Seeded/reproducible**" — gen1 isn't, across processes (`pairs()` order).
3. "**Mutation testing implemented**" — 1 mutant; matrix absent; snippet-drift is currently silent.
4. "**Search tested**" — open-and-close only; idx-passing flow unpinned.
5. "**24,567 invariant checks**" — mostly I5 double-resolves; count ≠ coverage breadth.
6. "**Restart equivalence verified**" — with a built-in retry-once that masks a known benign-but-unexplained recovery path; the note says the sidecar 'legitimately lags', which is itself an unfixed smell.
7. "**Regression fixtures are permanent**" — they're counted as passes and auto-retired without verifying the *same* bug still reproduces.
8. Known-fail fixtures skew heavily I7/I16 — evidence the I7 exemption set is drifting toward describing the implementation rather than constraining it.

---

### Repo hygiene note from this review

My scaled runs auto-promoted **40 fixture files** under `tests/fixtures/regression/` (all untracked). They are valuable — each is a minimized reproducer — but they should be triaged into the handful of distinct root causes before committing, otherwise the known-fail list balloons. Distinct signatures spotted: reset-after-stage (I7), reader/FM-switch stale siblings (I7), hide_tab I16 mismatch, external_native_edit divergence, delete_custom_submenu divergence.

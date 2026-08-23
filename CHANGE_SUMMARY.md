# Change Summary — Reordering Menus failure-mode hardening

Final state after three hardening rounds addressing the reviewed failure modes
(Errors A–J), the state/persistence review (semantic round-trips, minimal
external-import inference, malformed-native ingestion, schema versioning,
transaction concurrency, crash-window recovery, preset futures, reset
metamorphics, tombstone GC), and the accompanying test-strategy
recommendations. Tests were written alongside each fix and verified against
both new and pre-existing suites.

> **Round 3 (state/persistence) summary** — the additions below are documented
> in full in `README.md` § "State & persistence hardening". Headlines:
>
> * **Minimal semantic import** (`semantic_diff.lua`): external native edits
>   are diffed against our last emission (or stock defaults for keys absent
>   from sparse emissions) and reduced to the smallest intent — a single move
>   becomes one position anchor, never a frozen list. Separator-only changes
>   record nothing; genuinely new dividers record exactly one delta record.
> * **Schema versioning**: `SCHEMA_VERSION = 2` with v0/v1 → current migration,
>   idempotent re-stamping, quarantine (verbatim preservation) of files from
>   unsupported future versions, tolerance of unknown top-level fields.
> * **Optimistic transactions**: global + per-view generation counters bound
>   into sidecars; `stale_transaction` refusal with record-level three-way
>   rebase (`Transaction:mergeSection`) — no silent lost updates.
> * **Crash-window recovery**: intent-first commit ordering; sidecar records
>   carry `intent_gen`; generation-lag detection runs before external-import
>   classification so our own stale output can never be misread as a hand edit.
> * **Tombstone GC**: `Forget stale customizations` (`ghost_gc.lua`,
>   `MenuOrderManager:forgetStaleCustomizations`) drops records only for ids
>   no live provider serves; reinstall-after-forget lands at CURRENT provider
>   defaults.
> * **Preset hardening**: traversal-safe name sanitizing, case-collision
>   refusal, length cap, sparse-footprint apply verified under upstream drift.

---

## Overview

The sparse-intent pipeline (`registry → materializer → validator →
native_writer`) was hardened along four axes:

1. **Identity semantics** — untouched things follow the future, customized
   things follow the user. Provider-era records never migrate across
   providers; auto-generated bookkeeping (anchored pins) follows a live
   provider's changed default home instead of freezing it.
2. **Provider-aware ordering intent** — bulk sequences carry per-entry era
   stamps (`sequence_eras`) and manual anchors are provider-stamped, so a
   reused menu id can no longer inherit another provider's arrangement inside
   a shared menu.
3. **Persistence safety** — every persisted file goes through an atomic
   validate-then-rename pipeline; corruption regenerates from canonical
   intent; "we removed our own empty output" is distinguishable from "the
   user deleted everything"; failed durable writes roll back in-memory
   commits.
4. **Determinism** — simultaneous id collisions resolve by fixed policy, and
   a state-machine suite asserts seven global invariants after every random
   operation (~25k checks per full run).

## Key files changed

### New modules

| File | Purpose |
|---|---|
| `atomic_writer.lua` | Crash-safe Lua-table persistence: serialize → temp file in destination directory → parse back → shape-validate → atomic rename. Used for canonical intent, derived native orders and sidecars. |

### Core pipeline modules (modified)

| File | Changes |
|---|---|
| `materializer.lua` | Membership-gated override branch (no resurrection under stale parents); era-gated sequence entries via `sequence_eras`; provider-gated position anchors; neighbor-based slotting for update-introduced root tabs. |
| `menuorder_manager.lua` | Anchor release on same-provider hint/default changes with foreign-era records kept as inert tombstones; `deleteCustomSubmenu` blocks while hidden or ghosted occupants remain (no orphaning); `restoreItemDefault` accepts hinted plugin entries via their live registry home; `stageList` dual-form ordering (manual anchor for single drags vs era-stamped bulk sequence); `moveItemToMenu` / `restoreItemDefault` write provider-stamped position pins; **`ensureTxn` never reuses a committed transaction** (its staged table aliases `state.views` after commit — reuse silently mutated canonical state without persisting); `minimizeIntent` keeps era maps consistent. |
| `intent_store.lua` | New `sequence_eras` collection (schema, sanitize, transaction setters/cleaners); atomic persistence through `atomic_writer`; `Transaction:commit` rolls back the in-memory swap when the durable save fails. |
| `native_writer.lua` | Corrupt-file regeneration vs genuine-deletion revert (missing-file revert only when the last emission had content); previous-generation fingerprints so our own stale output rematerializes instead of being imported as a hand edit; external-edit import records cross-parent listings as explicit membership moves with deterministic customized-destination-wins tie-break; imports era-stamp sequences; atomic sidecar writes. |
| `koreader_adapter.lua` | Collision-aware registration collection: lexicographically smallest widget name deterministically owns provider *and* attributes of shared ids, collision reported on the record and logged; `nativeFileExists(view)` distinguishing deletion from unreadable content; atomic shape-validated native writes. |
| `registry.lua` | `addNode` returns the node; `collides` flag for simultaneously claimed ids. |
| `ui_screens.lua` | Same deterministic attribution policy in `_collectRegisteredMenuItems`. |
| `presets.lua` | Era stamps travel through view-preset application and submenu-preset sequencing. |
| `main.lua` | Call-once guard around `ui/plugin/insert_menu.add()` (KOReader offers no duplicate protection). |
| `patches/menusorter-sorting-hint-nil-guard.patch` | Ready-to-upstream defensive fix for stock KOReader's unguarded `sorting_hint` dereference (Error G). |

### Test suites added (13)

| Suite | Checks | Covers |
|---|---|---|
| `test_hint_migration.lua` | 24 | Errors A/B: table-driven plugin-hint upgrades (untouched follows, moves win, hides survive, unhide-after-upgrade lands at the new home, restore-default re-follows) and KOReader-update equivalents (relocated built-ins, in-menu reorder around manual anchors, neighbour-slotted new tabs) |
| `test_provider_identity.lua` | 28 | Error E: temporal id reuse inherits nothing; same-provider reinstall regains everything; deterministic collision attribution; id renames leave inert tombstones; mirror gating; era-stamped bulk slots and anchors (T7/T8) |
| `test_submenu_safety.lua` | 37 | Error F: self/descendant/indirect cycle rejection, corrupt cyclic models repaired deterministically, chaotic dense imports collapse to one parent, deletion policy never orphans children, leaf↔submenu shape changes preserve customization |
| `test_ghost_isolation.lua` | 28 | Errors C/D: ghost retention/inertness, imposter isolation, original-provider regain, 25 install/configure/uninstall cycles with per-cycle normalization checks |
| `test_storage_resilience.lua` | 33 | Error H: atomicity injection, five corruption classes, genuine-deletion revert, external edits under an open editor, stale-generation recovery |
| `test_self_absence_contract.lua` | 8 | Error G: stock crash reproduction without guards (release blocker), runtime-guard coverage, unknown-target fallback |
| `test_insert_menu_singleton.lua` | 3 | Error J: repeated module execution and repeated Reader/FM construction render exactly one entry |
| `test_koreader_contract.lua` | 17 | Adapter contract pinned to installed KOReader: settings parsing, overlay mutation, reference consumption, disabled handling, hint attachment; stock crash documented; **patch-context validated verbatim against `menusorter.lua`; patched sorter proven in sandbox (fixes crash, structurally identical on orphan-free input)** |
| `test_conditional_items.lua` | 29 | Layer 14: device-conditional entries (frontlight / keys / USB tab) across four capability states; customized conditionals keep records through absence and reactivate; render-safety throughout |
| `test_localization_identity.lua` | 8 | Layer 15: language switches never disturb moves/hides/bulk sequences; presets round-trip independent of translated strings; equal labels tie-break deterministically by ID |
| `test_io_failure_injection.lua` | 23 | Layer 8: injected write/rename/persist failures — baselines byte-identical, sidecar never advances on failure, no temp litter, direct-commit rollback verified, healthy retries succeed |
| `test_drag_index_mapping.lua` | 12 | Error I: drops adjacent to hidden rows anchor to visible siblings only (in-place and bottom-hidden modes), rows are ID-keyed and unique, restart equivalence |
| `error_g_stock_probe.lua` | expected failure | Raw reproduction of the Error G stock crash on unmodified KOReader; exits 1 by design, never part of pass/fail runs |
| `test_state_machine.lua` | 24,567 | Layer 16: seeded random op sequences (plugin lifecycle, user edits, upstream churn) over the pure pipeline with seven global invariants after EVERY step |

### Round-3 suites added (state/persistence review)

| Suite | Checks | Covers |
|---|---|---|
| `test_schema_migration.lua` | 14 | v0/v1 → current migration keeps records; version re-stamped; migration idempotent across repeated downgrade/reload cycles; restart-after-migration stable; future-version files quarantined verbatim (records preserved on disk, never loaded); unknown top-level fields tolerated AND preserved through resave |
| `test_txn_concurrency.lua` | 25 | Two txns from one base generation; sequential commit with record-level rebase (no lost update); same-item conflict = last explicit save wins; hide vs move both survive; non-reuse after commit/discard; stale refusal leaves canonical intact; external edit during open txn survives a rebased commit |
| `test_minimal_import.lua` | 13 | Single in-menu swap → exactly ONE position anchor and zero bulk sequences; front-move imported as minimal intent with resolved layout matching the edit; total reversal → era-stamped sequence; external hide via `KOMenu:disabled` records origin; unhide clears it; divider insertion records ≤1 separator delta and no ordering intent; unknown hand-added id preserved where placed; upstream deletion of an id creates NO record |
| `test_malformed_native.lua` | 50 | Syntactically-valid/structurally-hostile native files (list→string/boolean/table-of-tables, numeric ids, duplicate ids, duplicate root tabs, sparse arrays, map keys inside lists, cyclic tables, invalid disabled shape, empty lists, one id under several parents): import launch, save, and post-repair restart all survive |
| `test_preset_futures.lua` | 9 | Sparse preset apply restores ONLY what it captured (exactly the explicit records, nothing frozen); untouched levels stay sparse under upstream reorder; ghost + provider-change lifecycle around presets |
| `test_preset_robustness.lua` | 22 | Truncated/invalid-shape/future-version/wrong-format presets rejected without crash; path-traversal names (`../x`, `/x`, `a/b`, `.`, `..`) cannot escape the preset directory; case-collision refused (single file survives); hostile characters sanitized-or-refused; oversized names rejected; deleted-preset read fails soft |
| `test_reset_metamorphic.lua` | 10 | Pathological state (moves+hides+ghosts+custom submenus+preset) then Reset All → canonical empty, reset is a fixpoint, reinstall lands at CURRENT provider default (old placement not resurrected), preset file itself survives |
| `test_tombstone_gc.lua` | 10 | Retained ghost → reinstall restores customization; forgotten ghost → reinstall follows CURRENT provider default (even with changed hint); id reuse across providers inherits nothing before AND after GC; GC never touches live-id records; counting is read-only |
| `test_crash_pipeline.lua` (+ `run_crash_pipeline.sh`) | 2 | Genuine two-process crash injection (`os.exit(42)` between intent commit and native emission) — recovery yields old or new generation, never a hybrid; emitted file regenerated to match intent |

Runners:

```sh
bash tests/run_all.sh              # deterministic suites, summary + totals
bash tests/run_crash_pipeline.sh   # cross-process crash/recovery pair
```

> All suites share the KOReader settings directory
> (`DataStorage:getSettingsDir()`), so each must run in its own process
> (every runner above does). Suites that intentionally terminate their own
> process mid-run (`test_crash_pipeline`) are driven by wrapper scripts.

Legacy suites also updated: setup-time state wipes (`test_reordering`,
`test_koreader_integration`, `test_presets`, `test_ui_robustness`,
`test_custom_submenus`), failure-path stdout flushing in all assert helpers,
and one updated contract assertion (`test_restore_default_placement` R3) for
the new plugin-restore semantics.

## Major behavior changes

1. **Hint/default migration** — untouched or auto-anchored items follow a
   provider's changed `sorting_hint`; explicitly moved items always win;
   hides survive upgrades; restore-default re-follows the provider.
2. **Restore default for plugin entries** — hinted plugin items restorable to
   their provider default (previously refused); unknown ids still refused.
3. **Provider-aware ordering** — reused ids start at their own default slot
   inside shared menus; original slots reactivate on return; legacy unstamped
   data behaves exactly as before.
4. **Deletion policy** — hidden or ghosted occupants block custom-submenu
   deletion (previously invisible and orphaned).
5. **Crash-safe persistence** — no partial documents can be produced;
   corruption regenerates instead of wiping intent; deleting a content-bearing
   file still means full revert; failed writes roll back cleanly.
6. **Deterministic collisions** — smallest widget name wins provider and
   attributes; unstable identities receive no durable pin.
7. **Committed transactions are spent** — staging after a save opens a fresh
   transaction; uncommitted staging is discarded like a process restart.
8. **New tabs** slot near surviving default neighbours under curated bars
   (append remains the fallback).
9. **insert_menu call-once** — repeated module execution cannot duplicate the
   plugin's entry in either view.

## Tests and exact results

Run from the KOReader program directory with its bundled LuaJIT.

**Final validation was performed against UNMODIFIED stock KOReader** — no
KOReader source files are patched, modified, or replaced by this project
(stock file mtimes and content verified untouched), and no test depends on
the sorting_hint nil-guard patch being applied. The patch is only validated
textually against the installed source and executed in an in-memory sandbox.

**Final result (round 3): 43 deterministic suites — ~26.9k file-based
assertions, 0 failures across three consecutive full `run_all.sh` passes —
plus the randomized/multi-process suites: state machine 25.5k checks,
manager-verb state machine 360 checks ×6 seeds with restart-equivalence every
25 steps, menusorter differential fuzz 300 iterations ×0 failures, genuine
two-process crash-pipeline pair OK, and multi-process restart suite green.**

Exact commands:

```sh
cd /Applications/KOReader.app/Contents/koreader          # stock installation
for t in <suite names below>; do
  ./luajit /Users/nr/Development/ReorderingMenus/tests/$t.lua
done
SM_SEEDS=12 SM_STEPS=120 ./luajit \
  /Users/nr/Development/ReorderingMenus/tests/test_state_machine.lua
```

Pre-existing suites (all green):

| Suite | Result |
|---|---|
| test_reordering | 104 passed |
| test_koreader_integration | 32 passed |
| test_ui_robustness | 116 passed |
| test_presets | 47 passed |
| test_stale_editor_revert | 12 passed |
| test_ui_move_hide_plugin | 141 passed |
| test_persistence_restart | 26 passed |
| test_user_plugin_tab_hiding | 44 passed |
| test_protection_and_inactive | 43 passed |
| test_unsaved_close_prompt | 40 passed |
| test_menu_lifecycle_matrix | 62 passed |
| test_plugin_removal_lifecycle | 26 passed |
| test_preset_update_and_new_items | 38 passed |
| test_stock_slot_insertion | 18 passed |
| test_restore_default_placement | 27 passed |
| test_hidden_display_mode | 20 passed |
| test_custom_menu_lifecycle | 30 passed |
| test_custom_submenus | 120 passed |
| test_unhide_editor_flow | 26 passed |
| test_mirroring | 40 passed |
| **Legacy subtotal** | **1,012 passed, 0 failed** |

New suites:

| Suite | Result |
|---|---|
| test_hint_migration | 24 passed |
| test_provider_identity | 28 passed |
| test_submenu_safety | 37 passed |
| test_ghost_isolation | 28 passed |
| test_storage_resilience | 33 passed |
| test_self_absence_contract | 8 passed |
| test_insert_menu_singleton | 3 passed |
| test_koreader_contract | 17 passed |
| test_conditional_items | 29 passed |
| test_localization_identity | 8 passed |
| test_io_failure_injection | 23 passed |
| test_drag_index_mapping | 12 passed |
| **New subtotal** | **250 passed, 0 failed** |
| test_state_machine (SM_SEEDS=12 SM_STEPS=120) | 24,567 passed, 0 failed |

Repeat-run stability was spot-checked (provider identity and hint migration
suites executed multiple consecutive times with identical results; the state
machine was run three times at full scale).

## Separation: passing plugin tests vs the expected Error G failure

- **Passing (26,848 checks, 0 failures)** — every suite above runs against
  unmodified stock KOReader. Suites that exercise hint-hiding hazards do so
  through the plugin's own runtime guard (`require("main")`), which is part
  of this project, not of KOReader.
- **Expected Error G failure (not counted as a suite failure)** —
  `tests/error_g_stock_probe.lua` reproduces the raw stock crash with the
  plugin absent and no guards:

  ```sh
  ./luajit /Users/nr/Development/ReorderingMenus/tests/error_g_stock_probe.lua
  # exit status: 1 (by design)
  # frontend/ui/menusorter.lua:181: attempt to index a nil value
  ```

  This probe is intentionally NOT part of automated pass/fail runs; it
  exists to make the upstream blocker reproducible on demand.

**Harness changes needed for unmodified-stock runs: none.** The contract
suite already treats the crash as data (`pcall` in C6) rather than requiring
a patched KOReader; the patch is validated textually and executed only in an
in-memory sandbox. The probe file was added purely as documentation-in-code.

## Remaining issues

1. **Same-menu sequence inheritance for unstamped legacy data** — old
   configurations written before era stamping apply unconditionally (by
   design, for compatibility). Only newly written sequences are protected.
   A full multi-era per-provider record schema would remove even this caveat
   if ever needed. (Round 3 added a conservative inferred-stamp path for
   files that already carry a version field; fully-unstamped v0 sequences
   remain unconditional by design.)
2. **Editor A–Z collation uses display titles** — sorting inside editors
   orders by translated text; identity/tie-break behavior is covered, but
   locale-aware collation rules (e.g. locale-specific alphabets) are not
   implemented.
3. **Legacy suite depth** — hygiene (wipes, flushes) was applied
   mechanically; refactoring the oldest suites onto shared helper libraries
   remains future work.
4. **Search-filtered drag simulation** is covered indirectly (ID-keyed rows,
   hidden-row exclusion) rather than through a literal search UI flow.
5. **Randomized verb-suite strictness under heavy world drift**
   (`test_state_machine_verbs`, sibling-authored): when a preset frozen
   before many upstream additions is re-applied after the stock world grew,
   untouched-stock relative-order checks (I7) can flag healed placements.
   Current seeds pass; if it ever fires persistently, the checker's I7
   exemption for menus with position anchors (not just order_override)
   is the place to look.
6. **Shared settings directory across suites** — every suite wipes/uses the
   same KOReader settings dir, so suites are process-isolated by design and
   must not be `dofile`d into one interpreter. The runners enforce this;
   keep it that way when adding suites.

## Upstream blockers

**Error G — stock MenuSorter crash (release-blocking).**
`frontend/ui/menusorter.lua` dereferences the result of `findById` on an
orphaned item's `sorting_hint` without a nil check (line ~181). Any hinted
item whose target menu is unreachable — typically a hidden tab left behind in
`KOMenu:disabled` after Reordering Menus is disabled or uninstalled — crashes
the entire menu build on every launch. No plugin code can mitigate this while
the plugin itself is not loaded.

Status of mitigation shipped here:
- Runtime guard active whenever the plugin loads
  (`koreader_adapter.installSortingHintGuard`), contract-tested.
- `patches/menusorter-sorting-hint-nil-guard.patch` proposes the minimal
  upstream fix; its context is validated verbatim against the installed
  source and its semantics proven equivalent on orphan-free input
  (`test_koreader_contract.lua`, C7a–C7e).
- Until upstream merges it, arbitrary tab hiding carries this caveat, and the
  crash reproduction remains pinned in the contract suite so any KOReader
  change surfaces immediately.
- The raw crash is separately reproducible on unmodified stock at any time
  via `tests/error_g_stock_probe.lua` (exits 1 by design; see the separation
  section above).

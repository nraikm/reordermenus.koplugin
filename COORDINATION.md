# COORDINATION.md

**Status: PARALLEL PHASE ACTIVE (2026-08-27).** Multi-agent parallel
work resumed. Lane ownership for this phase:

- **ox-alpha P2 PURE/DERIVED MODEL LANE (2026-08-27).** Exclusive:
  `materializer.lua`, `validator.lua`, `menu_schema.lua`, `menu_titles.lua`,
  pure model determinism/benchmark tests (`tests/test_p2_pure_model.lua`).
  LANDED:
  (a) Strict cross-process determinism: eliminated `pairs()` ordering in
  validator warning generation and duplicate-row cleanup (`sortedKeys`);
  cross-process test confirms bit-for-bit identical outputs across 5
  independent LuaJIT processes.
  (b) Materializer efficiency: local O(1) `default_index` map and `sequenced_set`
  in `assembleMenuList` eliminate repeated linear scans and fix the
  table-entry vs string comparison flaw in position hint precedence; single-pass
  separator restoration; precomputed `default_tab_index` for newcomer tabs.
  (c) Removed dead code: legacy schema v2 redundant custom-parent loop in
  `Materializer.resolve` deleted; unused `isSubmenu` and `isTab` deleted from
  `MenuTitles`; unused `Validator.warn` and runtime `require("logger")` removed
  from `validator.lua`.
  (d) Live KOReader title preference: `MenuTitles:getTitle(id, live_items)`
  prioritizes live item `text` / `text_func` over static catalog fallbacks.
  (e) Schema centralization: `MenuSchema.SCHEMA_VERSION = 3`, `VIEWS`,
  `MAP_COLLECTIONS`, `SEQUENCE_FIELDS`, `ORDERING_MODE`, `NODE_TYPE`,
  `PROVIDER_STOCK`, `PROTECTED_ITEMS`, `PROTECTED_TABS`, and authoritative
  `MenuSchema.newCanonicalState()` / `newEmptyCanonicalState()`.
  (f) Purity & Immutability: `Validator.validate` constructs a fresh repaired
  graph copy without mutating input graph arrays in-place; zero input mutation.
  (g) Benchmarks: Realistic 105 µs/resolve, Medium 488 µs/resolve, Stress 2.49 ms.
  HANDOFF TO AGENT B / PERSISTENCE: `MenuSchema.newCanonicalState()` is available
  as the single authority for blank root canonical intent; `Validator.validate`
  continues returning `true, repaired_graph, warnings` with non-mutating guarantee.


- **ox-alpha P1B UI LANE (opened 2026-08-25 ~02:00).** Exclusive:
  `ui_screens.lua`, `ui_compat.lua`, UI/editor tests. Goals: thin UI
  (consume manager/adapter results), one editor lifecycle helper, unified
  close paths, single structured-save-result presentation, preset-UI
  consolidation per Agent B handoff above, dead-surface audit, private
  SortWidget patch audit + lazy install, `_window_stack` audit,
  feature-complexity table. Will NOT edit manager/presets/adapter/main.
  Handoffs consumed: drop post-loadPreset reconcile (B); adopt
  adapter requestRestart()/canRestart() (A). Deliverable tables +
  integration asks will be appended to this file when the lane closes.

- **P1B PRESET LANE (2026-08-25 ~01:15).** Exclusive: `presets.lua`,
  preset tests, new `reorderingmenus_plugin_prefs.lua`. LANDED:
  (a) footprint-once apply (`applyUserIntentPreset` builds one ID set;
  carry-over O(records+entries), identical semantics);
  (b) deterministic envelope serialization —
  `AtomicWriter.writeTable(path, tbl, validate, {sorted=true})` +
  `AtomicWriter.serializeSorted` (preset envelopes only; canonical store
  untouched); equivalent states now write byte-identical files;
  (c) view/type compatibility at ingress: builtin fragments tagged with
  `.view`, `Presets.checkViewCompatibility(view, envelope)` gates the
  manager load path; submenu envelopes carry `view`;
  (d) SUBMENU CAPTURE FIX: container homes now read from parent_override
  (schema v3 removed custom_menus.parent) — nested custom-in-custom presets
  restore fully; load recreates definitions+homes before child sequences;
  (e) built-in visibility moved to G_reader_settings namespace
  ("reorderingmenus") via plugin_prefs; legacy `.hidden_builtins.lua`
  imported once then deleted; NEW API `Presets.restoreBuiltinPresets(view)`;
  `hidden_in_place` presentation toggle also moved to plugin settings;
  mirroring STAYS in canonical meta (pinned Save/Discard coupling contract);
  (f) submenu listing memo keyed by dir mtime|size (no repeated parsing on
  menu redraws; no watchers);
  (g) registration-growth re-emission signal in reconcileRegisteredItems is
  the INTEGRATION lane's change I depend on for update-entry rendering.
  UI HANDOFF (Agent C): after full-view `loadPreset` you may DROP the
  extra `reconcileRegisteredItems(plugin, view, true)` — the funnel already
  committed+materialized (the call is harmless today but duplicates work);
  submenu-preset apply remains staging-into-open-txn BY CONTRACT (composes
  with editor draft; editor Save owns the single commit).
  New suite: `tests/test_p1b_preset_semantics.lua` (C1-C10, all green).

- **ox-alpha P1B KOReader-INTEGRATION lane (opened 2026-08-24 ~23:05;
  updated 2026-08-25 ~00:30).** Exclusive: `main.lua`,
  `koreader_adapter.lua`, `registry.lua`, KOReader integration/contract
  tests. LANDED so far:
  (a) reconciliation lifecycle rewritten — first-contact hinted items are
  NEVER pinned anymore (stock MenuSorter orphan handling places them live);
  REMOVAL TOMBSTONES added via previous-vs-current registry diff (one pin
  per disappearance, reinstall restores position); `reconcileRegisteredItems`
  now returns tombstoned-or-released. Fixes test_koreader_integration
  (32/0) while keeping test_plugin_removal_lifecycle green.
  (b) #14 native `random.uuid()` replaces /dev/urandom + hex + math.random
  for custom submenu ids; RNM_DETERMINISTIC_IDS hook preserved.
  (c) #5 dead `onShowFileManager` deleted from main.lua — ShowFileManager has
  ZERO emitters in the bundled KOReader tree; integration test rerouted to
  the init-equivalent reconcile call.
  (d) #12 adapter gained requestRestart() (UIManager:askForRestart) +
  canRestart() capability check; UI switch documented for merge agent.
  (e) #2/#8 collision metadata moved OUT of provider-owned entry tables:
  adapter returns a third `collisions` map; Registry.buildFromData takes it
  as 4th param; UI collector stores it on self._collisions instead of
  writing colliding_providers INTO widget entries (provider-table mutation
  bug fixed). Adapter's own registration records still carry the field
  (they are module-owned fresh tables; existing suites assert it there).
  (f) test_reordering Suite-6 tail converged to the implicit-anchoring
  contract (placement + no-record assertions; return-value/isCustomized
  over-strictness removed).
  STILL OPEN: #7 MenuSorter wrapper consolidation audit; #10 custom-submenu
  injection equivalence trial; #11 insert_menu removal trial; #13 live-reload
  decision (REPORT ONLY — needs product approval); #15 written inventory.

- **ox-alpha P1A INTEGRATION lane (opened 2026-08-24 ~19:10) — COMPLETE
  2026-08-24 ~19:55.** Integrated the three completed agent branches:
  (1) materializer `Materializer.shim` now delegates to `menu_schema`
  accessors (`orderedHiddenIds`, `getOrderRecord`, new
  `getParentOverrideRecord`/`getPositionOverrideRecord`/`customMenuTitles`);
  (2) native_writer has ONE checkpoint constructor (`setCheckpointRecord`,
  local), loaded-baseline immutability in `importExternalChanges` (derived
  `baseline` copy replaces the `last[menu_id]=...` sidecar mutation),
  `previous_structure` + `defaults_rev` + `setDefaultsIdentityProvider`
  deleted; hash recognition gated on writer_version; (3) manager stageList
  rewired onto `SemanticDiff.classify_permutation`/`is_noop_move` —
  singleRelocation, candidate probe loop, pure-default probe, per-anchor
  redundancy probes all DELETED; stageList now costs exactly 1 resolve
  (measured; was 2+L+A). KNOWN BEHAVIOR DELTA handed to the repair lane:
  `test_hint_migration.lua` K6 — canonical anchor tiebreak now picks "c
  after d" where the old probe-order picked "d after b" for the same drag;
  expectation in that suite needs a product ruling (suite NOT touched by
  this lane). Final quick tier from this lane's edits: 107 pass / 12 fail,
  every remaining failure pre-existing or repair-lane-owned. CI-tier state
  machine 40x200 PASS.

- **Projection lane (2026-08-24 ~19:00): materializer is HISTORY-FREE.**
  `Materializer.resolve(reg, intent)` takes exactly two arguments; the
  `prev_lists` third parameter, the manager's `getGraph` sidecar/
  last_graph seeding, and the whole `drop_history` invalidation discipline
  are REMOVED. Projection is a pure function of (current registry,
  canonical intent): cold == warm == post-restart, enforced by
  `tests/test_projection_determinism.lua` (52 checks, pure) and
  `tests/test_projection_restart_equivalence.lua` (32 checks, real write
  path). The ONLY canonical-record read seam is `Materializer.shim`
  (bottom of `reorderingmenus_materializer.lua`): when the schema
  representation changes, remap those five accessors and nothing else in
  projection. All XPASS regression fixtures (36 total) promoted to
  `tests/fixtures/promoted/`; `tests/fixtures/regression/` is empty —
  the known-bug bank is clear.
- **ox-alpha**: `reorderingmenus_semantic_diff.lua` exclusively — pure
  sequence/order algorithms, relocation detection, canonical anchor choice,
  no-op/equivalence logic, minimization primitives, focused ordering tests
  (`tests/test_semantic_diff_*.lua`). Schema-agnostic: consumes plain
  sequences, emits semantic results. Inspects (does not rewrite)
  `menuorder_manager.lua`.
- **Schema/materializer agent + integration agent**: canonical schema,
  materializer, and final `stageList` wiring. ox-alpha will NOT heavily edit
  the manager; a replacement plan for `stageList` is documented in
  `docs/semantic-diff-replacement-plan.md`.

Pure suites (no KOReader env, no settings-dir access) are used for this lane;
they cannot interfere with sibling sessions' hermetic runs.

**Lane status (ox-alpha): semantic layer COMPLETE 2026-08-24 evening.**
Public pure API live in `reorderingmenus_semantic_diff.lua` (legacy
`infer_list_change`/`lcs`/`diff_sequences`/`resolve_claims` preserved for
native_writer), tests `tests/test_semantic_ordering_unit.lua` (6287/0),
stageList replacement plan for the integration agent at
`docs/semantic-diff-replacement-plan.md`. Ready to wire.

---

**Historical note (superseded by the phase above): single-session ownership
(2026-08-24).** Between phases the multi-lane protocol below was retired and
ox-alpha owned all files.

## Historical lane log (retired 2026-08-24)

The full multi-session announcement history (2026-08-23/24: funnel,
storage-safety, editor-consistency slices, hermetic runner, fixture
enrollments, I13/I16 family tracking) has been condensed into the skill
references and test fixtures themselves:

- Pinned durability semantics: `references/reorderingmenus-harness.md`
- Determinism/fixture recipes: `references/cross-process-determinism.md`
- Known oracle families at the time of retirement: I6/I7/I16 — now owned
  by this session for production fixes (see the randomized-ladder work).

## P1A canonical-state lane (2026-08-24, ox-alpha) — ACTIVE

ox-alpha owns P1A: `reorderingmenus_menu_schema.lua`,
`reorderingmenus_intent_store.lua` (schema/migration/normalization/mutation
validation), canonical state definitions, and related migration tests.

Micro-edits outside that lane (each flagged in the P1A report, kept minimal,
mechanical adaptations to the new representation — NOT algorithm changes):

- `materializer.lua`: disabled-list assembly reads hidden records;
  `ctx.override`/era map read the combined order record; effectiveParent
  consults custom-menu parent authority.
- `presets.lua`: snapshot copy of the combined order record; footprint walk.
- `native_writer.lua`: kept-sequence rebuild after removal-import.
- `menuorder_manager.lua`: moveItemToMenu sequence-strip loop; isCustomized
  delegation to the typed canonical predicate.
- `tests/lib/sm_world.lua`: hidden-order oracle derives from records.

All other production lanes (ordering algorithms, materialization semantics,
UI) remain with the sibling agents per the P1A dispatch.

Disambiguation: the semantic-diff lane above is ALSO logged under the name
"ox-alpha" (all parallel sessions share the model identity). This session
does NOT touch `reorderingmenus_semantic_diff.lua` or
`docs/semantic-diff-replacement-plan.md`; the sibling does NOT touch the
schema/store files listed above. Both sides run tests hermetically
(per-suite KO_HOME) / pure respectively.

## Randomized-lane production fixes (2026-08-24 afternoon, ox-alpha)

Root causes found & fixed for the I6/I7 families + fuzz round-trip drift:

1. materializer seedSequence: prev_seq healing now requires
   effectiveParent(id) == menu_id (global members map let old menus reclaim
   re-homed rows -> I6 overrides silently lost).
2. loadPreset: invalidate(view, {drop_history=true}) - preset is a semantic
   reset; pre-apply drag permutations must not heal back over fresh intent.
3. getGraph: seeds prev_lists from the sidecar record ONLY when intent_gen ==
   current generation AND defaults_rev == current stamp (new provider
   NativeWriter.setDefaultsIdentityProvider). Preserves un-pinned positions
   across write->reload without defeating upstream hint migration.
4. appendImmigrants sorts candidates before slot insertion (process
   determinism; pairs() order was visible in multi-immigrant menus).

26 XPASS fixtures converted to tests/fixtures/promoted (must-pass forever).

Residuals (~4% of 200-step bank trajectories, was ~25%): rare I15 doubled-
divider after remove_separator+unhide on a minimized menu; I16 oracle ghost-
parent extras can double-count when an id carries both hidden and
parent_override records; occasional external_native_edit x preset corners;
fuzz round-trip ~1/8 quick batches. Each has its own repro pending.

— ox-alpha

# Reordering Menus — KOReader Integration Review (2026-08-23)

Scope: KOReader integration, plugin lifecycle, malformed plugin contributions,
runtime contexts, upstream compatibility, real-process behavior. All findings
verified empirically against the installed stock `menusorter.lua`
(v2025.10-43-g562fc11) and the working tree.

## 1. Newly discovered risks (ranked)

### R1 — Stale-container hint crash + airbag defeat (CRITICAL, fixed)
`classifyHintTarget` trusted the order graph alone: an id with a surviving
`order[X]` row but NO live item (provider changed shape, provider removed,
hand edit) classified as `reachable_container`. Empirically:
- If X is truly absent → stock crashes mid-orphan-loop (`menusorter.lua:181`),
  leaving item_table half-consumed AND polluted with orderedPairs'
  `__orderedIndex`. The airbag's sanitized retry then started from the
  wreckage — placed items lost, debris ingested as fake rows — and crashed
  again at `menusorter.lua:139`. Three defense layers, still fatal.
- If X arrives as a LEAF → the stale row silently reshapes it into an EMPTY
  submenu; its children reappear as "NEW:" orphans.
Fix: classifier now takes `item_table`, distinguishes live containers from
stale rows (`stale_container` class), and the custom-submenu synthesis counts
as live. Guard neutralizes before stock runs.

### R2 — Airbag retry input corruption (HIGH, fixed)
Even when the first pass crashes for unknown reasons, stock consumes placed
references from `item_table` before faulting. The airbag now snapshots
`item_table` BEFORE the first pass and rebuilds retry input from that
snapshot (original refs restored, run debris dropped, synthesized customs
kept, all remaining hints stripped). Verified: every original item renders
after recovery.

### R3 — Dormant intent deletion on collision lifecycle (HIGH, fixed)
`minimizeIntent` treated A's dormant tombstone as graph-invisible redundancy
whenever B served the same id, deleting it. That broke the reactivation
guarantee: after B/X churn, A's return no longer restored A's placement.
Fix: parent_override records whose provider differs from the live provider
are never minimization candidates. Proven by test_collision_lifecycle_full
(L1 reactivates, L2 B inherits nothing).

### R4 — Orphan→orphan hint nondeterminism (MEDIUM, guarded)
Stock resolves orphan hints in alphabetical id order: target sorts first →
attach; second → crash. Identical structure, different fate by id name.
Guard removes the nondeterminism (all classes stripped deterministically);
pinned by M3 chains (mutual, 3-ring, both alphabetical orders).

### R5 — Equal widget names defeat attribution tiebreak (MEDIUM, documented)
Two widgets with identical `.name`: strict `<` comparison never fires,
first-seen wins silently, no collision flagged. Real trigger: two plugin
directories shipping the same `_meta.lua` name. Recommendation below.

### R6 — Shared submenu table diamond (LOW, documented)
One table under two submenu ids produces two bar entries sharing one subtree
(diamond, NOT a cycle); findById survives because cycle nodes lack `.id`.
True self-referential sub_item_table hangs findById only if nodes carry
`.id`s — not producible from provider data alone; documented as hardening.

### R7 — boolean-false hint asymmetry (TRIVIAL, documented)
Stock's `if sorting_hint` treats `false` as absent; guard never sees it.
Same visible outcome (NEW: fallback); exempted from strip assertion.

## 2. Exact implementation changes

1. `koreader_adapter.lua` — classifyHintTarget(hint, order, self_id, item_table):
   new `stale_container` class; live-container check via item_table or
   custom-submenu registry; stale rows win over generic `listed` verdict;
   guard passes item_table through.
2. `koreader_adapter.lua` — sanitizeForRetry(snapshot, item_table, order):
   pre-pass snapshot semantics, string-keyed table entries only, drops
   `__orderedIndex`, keeps synthesized customs, strips remaining hints;
   airbag wrapper snapshots before first pass.
3. `koreader_adapter.lua` — Area 12: tabHidingSafety() ("safe"/"unsafe",
   cached, nil→unsafe) and prepareForPluginRemoval(Manager) restoring every
   hidden row in both views + save.
4. `menuorder_manager.lua` — minimizeIntent skips dormant tombstones
   (record.provider ~= live provider) with dbg log.
5. `ui_screens.lua` — file-scope KoreaderAdapter require; unsafe-mode one-
   time warning on tab-hide; "Prepare for plugin removal" ConfirmBox in BOTH
   dialog builders with applyLiveReload for reader+filemanager.
6. Test-only escape hatch `_probeSanitizeForRetry` exposed for probes.

## 3. New/updated suites (all green, repeatable ×3)
- tests/test_malformed_targets_and_airbag.lua — 69 checks: M1 crash-class
  matrix incl. disabled-target invisibility & control attach, M2 leaf-swallow
  + stale container, M3 orphan chains/rings both orders, M4 airbag snapshot
  recovery (all items render, no debris), M5 upstream-fix probe
  true/false/nil.
- tests/test_collision_lifecycle_full.lua — 14 checks: A/X↔B/X full lifecycle,
  deterministic min-name attribution, collision flagged, single-parent through
  winner change, reactivation of A's customization, B inherits nothing,
  submenu-X variant, contested TAB id (L6) incl. coherent hiding.
- tests/test_removal_safety_policy.lua — 13 checks: P1 verdict/caching/raw
  probe, P2 unhide-all restores, P3 post-unhide world builds under UNGUARDED
  stock code with hint attaching to the restored container, P4 UI wiring pins.
- tests/probe_sorting_hint_matrix.lua — evidence table: 11 shapes, stock
  verdict vs classifier vs landing site.
- Cleanup added so new suites don't poison the shared settings dir for later
  suites in the battery (root cause of phantom battery failures).

## 4. Malformed-plugin fixture designs (reusable patterns)
- makeWidget/make_stub(name, id, {submenu=}) — repo-convention stubs gated on
  ui.view absence; names feed attribution.
- Synthetic double-claim: two widgets same id different hints → assert
  providers[id]=="plugin_<min>" && colliding_providers sorted pair.
- Equal-name twins → documents first-seen-wins (see recommendations).
- Throwing text_func: menu_titles.getTitle already pcalls — covered.
- Same-table-under-two-ids: diamond verification (no hang) in probe files.

## 5. KOReader version / CI strategy
- Keep executing private sandbox copies of the installed menusorter.lua
  (upstreamHintGuardPresent pattern) — version-string sniffing is fragile.
- CI tiers against previous-stable / current-stable / master via
  KOREADER_DIR override (run_tests.sh supports it already); contract suite
  C0–C8 pins the exact hunk the patch rebases against.
- Battery hygiene: suites must wipe their state (now enforced in new suites);
  run order-independent by wiping shared settings between suites in CI.

## 6. Recommended policy for the Error-G blocker
Adopted: D-lite + C.
- Detect fix presence per install (tabHidingSafety). Safe → unrestricted.
- Unsafe → hiding stays allowed (runtime guards protect while installed),
  one-time warning pointing at mitigation, plus explicit "Prepare for plugin
  removal" action (unhide everything, persist, live-reload).
- Upstream patch remains shipped for ko_patcher users; detection executes a
  sandbox copy so a fixed nightly flips policy automatically.

## 7. Upstreamable to KOReader
1. The nil-guard patch (already written): fallback to NEW:-in-first-menu on
   unreachable hint target — byte-equivalent on orphan-free menus (C7e).
2. findById cycle hardening: visited-set keyed on node identity (+ skip when
   node lacks .id) — cheap, prevents future hangs.
3. insert_menu.add dedupe (documented C8 duplicates without guard).
4. PluginLoader identity: key disabled-state and display by resolved module
   name, warn on directory/module-name mismatch; document that plugins_disabled
   keys off DIRECTORY while sort/attribution use path/name respectively.

## 8. Additional recommendations (not implemented here)
- Attribution: treat equal widget.name from different paths as a collision
  (flag + deterministic path tiebreak) rather than silent first-seen-wins.
- Consider surfacing stale_container rows in the editor ("leftover placement")
  so users can prune residue after provider shape changes.

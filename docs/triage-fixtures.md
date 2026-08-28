# P1 — Generated-fixture triage (live document)

State: post-Bug-1/1b fix. 110 promoted fixtures collapsed to **68 XFAIL across
~20 signatures / 5 root-cause classes**; 48 retired as XPASS after fixes;
4 legacy-format fixtures migrated; 2 crash-class fixtures root-caused.

| Root cause | Invariant | Minimal history | Affected seeds | Status |
|---|---|---|---|---|
| **Bug 1a — reset resurrects erased arrangement** (`invalidate` snapshotted the staged graph into `last_graph`; healing walk replayed it over emptied intent) | I7 order | `stage_list_permutation` → `reset_submenu` (2 ops, seed 712710) | 27 seeds / 20 reset_submenu + 6 reset_view fixtures XPASS-retired | **FIXED** (`drop_history` in invalidate) |
| **Bug 1b — stale `last_graph` survives resets** (drop_history only skipped the snapshot; earlier invalidations had already poisoned `last_graph`) | I7 order | `stage_list_permutation` → `restore_item_default` → `reset_view` (3 ops, seed 110866) | 16 reset_view + assorted reader_fm_switch fixtures | **FIXED** (drop_history now clears `last_graph`) |
| Legacy fixture format drift: old world's `save_preset` args lacked `view` ⇒ replay crashed (`table index is nil`) | OPERROR | `save_preset` ×1 op (seeds 23757, 39595, 47514, 7919) | those 4 seeds | FIXED (fixtures migrated; world unchanged) |
| World op bug: `external_native_edit` picked a menu then crashed on `#list` when the menu vanished between pick and apply during replay | OPERROR | 1–4 ops ending `reader_fm_switch` (seed 7919) | 1 seed | FIXED (nil-guard in sm_world) |
| **Class C1 — cascade-disabled set disagrees with disabled list after upstream churn** (`upstream_add/remove`, `stage_list_permutation`, `sort_menu_az`, `hide_tab` triggers) | I16 mismatch | e.g. `stage_list_permutation` alone (seed 134623) | ~26 fixtures / 14 seeds | OPEN — sibling lane (P3-A) |
| **Class C2 — untouched sibling order broken by upstream reorder/add/remove without any user sequence** | I7 order | `upstream_reorder` / `upstream_add` + reset_view tails | ~21 fixtures / 15 seeds | OPEN — likely interaction between slot-alignment and frozen-menu detection |
| **Class C3 — unhide of cascade-disabled tab lands under nil** (`unhide_all`/`unhide_item` on validator-cascaded tabs) | I6 | `hide_tab` → `unhide_all` (seed 31676) | 3 fixtures | OPEN — unhide must restore cascaded tabs to the bar |
| **Class C4 — fabrication/render leaks** (`NEW:`-style rows after external edit + upstream_remove_tab; custom submenu id rendering) | I13 | 2–4 ops | 2 fixtures | OPEN — highest severity per user impact |

## Rules applied
- Same invariant ≠ same root cause: clusters were split by semantic divergence
  (which menu, which items, which trigger op chain), verified via targeted replays.
- XPASS fixtures were retired only after confirming a deterministic positive
  regression suite (`test_reset_after_stage_regression.lua`) covers Bug 1.

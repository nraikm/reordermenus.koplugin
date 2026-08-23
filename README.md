# Reordering Menus for KOReader

Reorder, hide, move, and group KOReader menu items in both Book view and the File Manager, using KOReader's native interface.

<p align="center">
  <img src="screenshots/01-menu-order.png" width="46%" alt="Reordering the Book view menus">
  <img src="screenshots/02-submenu-order.png" width="46%" alt="Reordering the Tools submenu">
</p>

<p align="center">
  <img src="screenshots/03-submenu-actions.png" width="46%" alt="Actions available for the Tools submenu">
  <img src="screenshots/04-submenu-presets.png" width="46%" alt="Preset management for the Tools submenu">
</p>

## Features

- Reorder the top menus in Book view and the File Manager independently.
- Open and reorder KOReader-defined nested submenus at any depth.
- Keep plugin-owned internal menu arrangements under that plugin's control.
- Show only items currently provided by KOReader or installed plugins.
- Pick up newly installed plugin items before they exist in a saved order.
- Keep hidden third-party items associated with their original menu so they can be shown again or restored by resetting that submenu.
- Show or hide items with the checkbox beside each entry.
- Move an item or a complete KOReader submenu to another menu; both editors refresh immediately, and destinations that would create a submenu cycle are excluded. The destination list puts the submenus of the current menu first, followed by its parent menus.
- Optionally mirror changes between Book view and Normal view (hamburger toggle in the tab screen): cross-menu moves and hide/show actions in one view are copied to the other view's saved configuration whenever the same item and destination exist there. Items unknown to the other view are skipped, so single-context entries never leak across; changes take effect when the other context next reloads.
- Insert, reposition, and remove separators.
- Create your own empty submenus in any menu: pick **Add submenu at bottom** (or mark a row first to insert below it) in the hamburger menu and give the new submenu a name, then move items into it. A created submenu can be deleted from its row's long-press dialog once it has been emptied.
- Sort the current menu from A to Z or Z to A.
- Reset the current Book or Normal menu, an individual submenu, or every menu.
- Save and load complete Book view and File Manager presets.
- Applying a preset keeps any submenus you created after saving it, including their names.
- Save presets for one submenu only, with optional nested submenu ordering.
- Preserve newly added plugin items when applying submenu presets.

## Architecture

The plugin implements **sparse declarative user intent**: it persists only
what you actually did — never a snapshot of resolved menus. Every menu is
derived at runtime from KOReader's *current* defaults combined with that
intent:

```
        current KOReader defaults
        current registered plugin contributions (+ sorting hints)
                    |
              BASE REGISTRY                      (registry.lua)
                    |
   User Intent  ----------------------->  MATERIALIZER     (materializer.lua)
                    |                     pure resolve()
                    v
          validated resolved menu graph         (validator.lua)
                    v
          minimal KOReader native overrides      (native_writer.lua)
                    v
                   stock MenuSorter
```

Production responsibilities are deliberately narrow:

| Module | Responsibility |
|---|---|
| `menu_schema.lua` | Plain constants, collection names, and fresh sections |
| `intent_store.lua` | Canonical sparse intent, migration, validation, transactions |
| `registry.lua` / `materializer.lua` / `validator.lua` | Pure domain pipeline |
| `native_writer.lua` | Sparse native emission, startup classification, hand-edit import |
| `koreader_adapter.lua` | KOReader files, registrations, MenuSorter guards, live rebuild |
| `presets.lua` | Intent snapshots and preset-file operations |
| `menuorder_manager.lua` | Stable editor-facing facade and orchestration |
| `ui_screens.lua` | KOReader dialogs; pure paging/identity helpers live in `ui_editor_model.lua` |

## State & persistence hardening

On top of the pipeline above, persistence follows four rules:

1. **Canonical intent is the source of truth.** Saves commit intent FIRST and
   emit the derived native file second; a crash between the two leaves a file
   that lags canonical state, which the next launch detects via the sidecar's
   bound `intent_gen` and regenerates — never the reverse (a stranded native
   file describing work canonical never recorded).
2. **Our own stale output is never mistaken for a hand edit.** Sidecar records
   carry fingerprints of the current and previous emission plus the generation
   they were derived from. Known fingerprints identify our output; generation
   comparison then detects when an otherwise-current derived file lags intent.
3. **External edits become minimal intent.** A hand-edited native file is
   diffed (`semantic_diff.lua`) against our last emission — or stock defaults
   when the key was absent from our sparse emission — so one moved row becomes
   one position anchor and untouched neighbours keep following upstream.
4. **Concurrent writers inside one session cannot silently lose updates.**
   Transactions stage against a base generation; commit refuses stale
   transactions (`stale_transaction`) and `saveOrder` rebases via record-level
   three-way merge (`Transaction:mergeSection`), preserving both writers'
   records with last-explicit-save-wins per record.

The generation check is an in-process transaction safeguard, not a general
multi-process locking protocol. KOReader normally has one settings writer.

Canonical files are versioned (`version`, currently **2**) with
lossless v0/v1 migration, idempotent re-stamping, and verbatim quarantine of
files written by unsupported future versions. Malformed-but-parseable native
files (cyclic tables, scalar lists, numeric/sparse arrays, duplicate ids) are
normalized at ingestion and regenerated from intent. An explicit
**Forget stale customizations** action (`MenuOrderManager:forgetStaleCustomizations`)
drops records only for ids no live provider serves, so reinstalling later
starts from CURRENT provider defaults instead of resurrecting old placements.

What this buys you:

- **Untouched menus stay untouched on disk.** A menu list is written to
  KOReader's `reader_menu_order.lua` / `filemanager_menu_order.lua` only when
  its derived content differs from stock. A KOReader update can therefore
  reshape any menu you never customized with zero reconciliation.
- **Identity is `(id, provider)`.** Records are stamped with the provider
  that was serving an id when you acted ("stock" or "plugin:<name>"). If a
  plugin is uninstalled and another one later contributes the same menu id,
  it does not inherit the old customization; reinstalling the original
  restores it exactly. Auto-anchored placements follow their provider's
  current default home, so an untouched item migrates when a plugin update
  changes its `sorting_hint` — while explicitly moved items always stay put.
- **Only user actions persist — in two deliberate forms, both
  provider-aware.** Single drags are stored as manual anchors
  (`position_override`), so untouched neighbours keep following upstream
  changes; bulk operations like A–Z sorts store an explicit ordered sequence
  with per-entry era stamps (`sequence_eras`). A reused menu id starts at its
  own provider's default slot instead of inheriting another plugin's
  arrangement; the original provider's slot reactivates on return.
- **Crash-safe persistence.** Every persisted table file (canonical intent, derived
  native orders, sidecars) is written through serialize → temp file → parse →
  validate → atomic rename with a unique staging name, so stock KOReader's unprotected `dofile()` never
  sees a half-written document. Corrupted files regenerate from canonical
  intent; a stale generation left by a crash between per-view writes is
  recognized via previous-generation fingerprints and rematerialized rather
  than misread as a hand edit. Native output and its sidecar are independently
  atomic files; startup recovery handles a crash between those writes.
- **Deterministic collision policy.** When several plugins contribute the same
  menu id at once, attribution goes to the lexicographically smallest widget
  name (provider *and* attributes), the collision is logged, and no durable
  pin is written for an identity that unstable.
- **Hand edits stay supported.** The exact structure of the last generated
  file is recorded in a noncanonical sidecar. On startup the native file is
  compared against it: unchanged means nothing to do; externally edited means
  the diff is imported back as explicit intent; anything unrepresentable is
  kept verbatim via a scoped raw override.
- **Presets are portable across updates** because they capture records, not
  layouts: whatever a preset snapshot never mentions keeps following the
  current defaults.

Canonical state lives in `reorderingmenus_intent.lua`; the noncanonical
last-materialization record lives in `reorderingmenus_materialization.lua`.
Both (plus the older `reorderingmenus_state.lua`) migrate/import
automatically on first run.

## Installation

1. Download the latest `reorderingmenus.koplugin.zip` from the [Releases](https://github.com/nraikm/ReorderingMenus/releases) page.
2. Unpack it.
3. Move the `reorderingmenus.koplugin` folder into your KOReader `plugins` directory (the same one as your other plugins).
4. Restart KOReader.

## Usage

Open:

```text
Tools → More tools → Reorder menus
```

- Drag entries to change their order.
- Tap a checkbox to show or hide an entry.
- Tap a submenu once to select it, then tap it again to open it. You can also long-press it and choose **Edit submenu contents**.
- Open the hamburger menu for sorting, separators, creating your own submenus, moving items, presets, and reset actions.
- Tap the checkmark at the bottom to save the current order.

Book view and File Manager layouts are stored separately. The screen title identifies the layout currently being edited as **Book view** or **Normal view**.

## Presets

The top-level hamburger menu contains presets for the complete current view, including several built-in layouts and any custom layouts you save.

Each submenu has its own preset collection under **Presets for _menu name_…**:

- **Save this menu order…** stores only the direct order of the current submenu.
- **Save with nested submenu orders…** also stores the order of every submenu below it.
- `[Direct]` and `[Nested]` prefixes identify the preset scope when loading or deleting presets.

Submenu presets affect ordering only. They do not replace visibility settings, and menu entries introduced by newly installed plugins are retained and appended after the saved order.

## Notes

- Changes are written to KOReader's standard `reader_menu_order.lua` and `filemanager_menu_order.lua` settings files — but only for menus whose derived layout deviates from stock, so those files stay minimal.
- Created submenus and their titles are stored inside the same order file under `KOMenu:custom_submenus`; they render in KOReader's menus without editing any core files.
- The plugin's canonical customization state lives in `reorderingmenus_intent.lua`; a small noncanonical record of the last generated files (`reorderingmenus_materialization.lua`) powers hand-edit import. Legacy sidecar state is migrated automatically.
- Presets are stored under `settings/menu_order_presets/` in the KOReader data directory. New presets capture sparse intent; older dense preset files keep working and are converted against the current defaults when loaded.
- A live reload is attempted after changes; KOReader may still request a restart when a complete refresh is needed.
- Third-party plugins can add or remove menu entries. Missing entries in an older submenu preset are ignored, while newly available entries remain accessible.
- Existing menu-order files containing the same item under multiple parents are repaired automatically, preferring a customized destination over the stock location.

## Development

Run the tests with the LuaJIT bundled with KOReader. From the KOReader program directory:

```sh
PLUGIN_DIR=/path/to/ReorderingMenus

./luajit "$PLUGIN_DIR/tests/test_reordering.lua"
./luajit "$PLUGIN_DIR/tests/test_koreader_integration.lua"
./luajit "$PLUGIN_DIR/tests/test_ui_robustness.lua"
./luajit "$PLUGIN_DIR/tests/test_presets.lua"
./luajit "$PLUGIN_DIR/tests/test_stale_editor_revert.lua"
./luajit "$PLUGIN_DIR/tests/test_ui_move_hide_plugin.lua"
./luajit "$PLUGIN_DIR/tests/test_persistence_restart.lua"
./luajit "$PLUGIN_DIR/tests/test_user_plugin_tab_hiding.lua"
./luajit "$PLUGIN_DIR/tests/test_protection_and_inactive.lua"
./luajit "$PLUGIN_DIR/tests/test_unsaved_close_prompt.lua"
./luajit "$PLUGIN_DIR/tests/test_menu_lifecycle_matrix.lua"
./luajit "$PLUGIN_DIR/tests/test_plugin_removal_lifecycle.lua"
./luajit "$PLUGIN_DIR/tests/test_unhide_editor_flow.lua"
./luajit "$PLUGIN_DIR/tests/test_preset_update_and_new_items.lua"
./luajit "$PLUGIN_DIR/tests/test_stock_slot_insertion.lua"
./luajit "$PLUGIN_DIR/tests/test_restore_default_placement.lua"
./luajit "$PLUGIN_DIR/tests/test_hidden_display_mode.lua"
./luajit "$PLUGIN_DIR/tests/test_custom_menu_lifecycle.lua"
./luajit "$PLUGIN_DIR/tests/test_custom_submenus.lua"
./luajit "$PLUGIN_DIR/tests/test_hint_migration.lua"
./luajit "$PLUGIN_DIR/tests/test_provider_identity.lua"
./luajit "$PLUGIN_DIR/tests/test_submenu_safety.lua"
./luajit "$PLUGIN_DIR/tests/test_ghost_isolation.lua"
./luajit "$PLUGIN_DIR/tests/test_storage_resilience.lua"
./luajit "$PLUGIN_DIR/tests/test_self_absence_contract.lua"
./luajit "$PLUGIN_DIR/tests/test_insert_menu_singleton.lua"
./luajit "$PLUGIN_DIR/tests/test_koreader_contract.lua"
./luajit "$PLUGIN_DIR/tests/test_conditional_items.lua"
./luajit "$PLUGIN_DIR/tests/test_localization_identity.lua"
./luajit "$PLUGIN_DIR/tests/test_io_failure_injection.lua"
./luajit "$PLUGIN_DIR/tests/test_drag_index_mapping.lua"
SM_SEEDS=12 SM_STEPS=120 ./luajit "$PLUGIN_DIR/tests/test_state_machine.lua"
./luajit "$PLUGIN_DIR/tests/test_staged_exit_and_commit_crash.lua"
./luajit "$PLUGIN_DIR/tests/test_native_deletion_while_disabled.lua"
./luajit "$PLUGIN_DIR/tests/test_reset_all_gc.lua"
```

Or run the whole deterministic set (plus randomized/multi-process suites
separately) with the bundled runners:

```sh
bash "$PLUGIN_DIR/tests/run_all.sh"              # 43 deterministic suites + totals
bash "$PLUGIN_DIR/tests/run_crash_pipeline.sh"   # cross-process crash/recovery
SM_SEEDS=6 SM_STEPS=60 SM_RESTART_EVERY=25 \
  ./luajit "$PLUGIN_DIR/tests/test_state_machine_verbs.lua"
./luajit "$PLUGIN_DIR/tests/test_menusorter_differential_fuzz.lua"
./luajit "$PLUGIN_DIR/tests/test_multiprocess_restart.lua"
./luajit "$PLUGIN_DIR/tests/test_semantic_diff_unit.lua"
./luajit "$PLUGIN_DIR/tests/test_schema_migration.lua"
./luajit "$PLUGIN_DIR/tests/test_txn_concurrency.lua"
./luajit "$PLUGIN_DIR/tests/test_minimal_import.lua"
./luajit "$PLUGIN_DIR/tests/test_malformed_native.lua"
./luajit "$PLUGIN_DIR/tests/test_preset_futures.lua"
./luajit "$PLUGIN_DIR/tests/test_preset_robustness.lua"
./luajit "$PLUGIN_DIR/tests/test_reset_metamorphic.lua"
./luajit "$PLUGIN_DIR/tests/test_tombstone_gc.lua"
./luajit "$PLUGIN_DIR/tests/test_corrupt_canonical_intent.lua"
```

Set `KO_HOME` to a separate KOReader data directory when you want an isolated development or test environment.

All suites run against **unmodified stock KOReader**; nothing in this project
patches or modifies the installation. The one known stock defect that this
plugin cannot fix while absent is documented as an explicit expected-failure
probe — it intentionally exits non-zero and must never be part of automated
pass/fail runs:

```sh
./luajit "$PLUGIN_DIR/tests/error_g_stock_probe.lua"
# expected: exit 1, "frontend/ui/menusorter.lua:181: attempt to index a nil value"
```

The regular suites pin that same crash safely as data via `pcall`
(`test_koreader_contract.lua` C6) and prove the runtime guard neutralizes it
while the plugin is loaded (`test_self_absence_contract.lua`).

The UI-flow suites drive the real widgets (SortWidget editors, hold dialogs, destination chooser):

- `test_stale_editor_revert.lua` — moving an item while another editor of the source or destination menu is still open must not revert or resurrect the move.
- `test_ui_move_hide_plugin.lua` — cross-menu moves (including into a parent menu whose editor is open underneath), hide/show of items and submenus via checkbox and hold dialog, and pickup of newly installed plugins, verified against both the saved configuration and KOReader's rebuilt live menu tree.
- `test_persistence_restart.lua` — performs moves, hides, and a plugin installation, then simulates a full KOReader restart by dropping every in-memory cache and rebuilding from disk before verifying that everything survived.
- `test_user_plugin_tab_hiding.lua` — user plugins that anchor entries with a sorting hint (e.g. Anna's Archive in Search): hiding that tab must keep the top menu openable across restarts (even when the item was never persisted), hinted items hide with their tab without leaking elsewhere, and a reset returns hidden plugin items to the editor immediately.
- `test_protection_and_inactive.lua` — the plugin's own "Reorder menus" entry refuses every interactive hide path (checkbox, hold dialog, search action) while staying movable and recoverable from legacy configurations; configured entries that KOReader cannot render because no installed widget provides them are kept out of the editors entirely while remaining persisted, so reinstalling the provider restores them at their configured position.
- `test_unsaved_close_prompt.lua` — the editors' title-bar X detects staged reordering and unsaved visibility toggles and offers Save / Discard changes / Cancel (Cancel keeps editing; Discard reloads the working order from disk, reverting even immediate-but-unsaved toggles), while the bottom check icon keeps saving directly and the bottom exit icon keeps closing without ever prompting.
- `test_menu_lifecycle_matrix.lua` — post-configuration entries never degrade into "NEW: ..." orphans: plugins installed later are anchored via their hints (recreating missing hint menus from defaults, with the unknown-hint stock fallback as the only documented exception), moved items stay put across restarts without being re-anchored, hidden items are never resurrected, editor round-trips preserve anchored positions, and a simulated KOReader update heals aged configuration files - restoring aged-out stock entries and appending brand-new core entries and whole new top-level tabs at their default places while preserving every customization.
- `test_plugin_removal_lifecycle.lua` — removing a plugin degrades gracefully: its stale entry stays persisted at its configured position (moved and hidden states included) so reinstalling restores it exactly, with a single parent and zero "NEW:" orphans; removed entries disappear from the editors immediately; removal combined with a hidden anchor tab keeps the top menu building cleanly.
- `test_unhide_editor_flow.lua` — visibility toggles update the editor model immediately: unhiding moves the row out of the dimmed hidden section into the visible block (with a confirmation toast) instead of leaving it looking unchanged, hiding relocates it back, both directions register as unsaved changes for the X prompt, and every path (checkbox, hold dialog restore/hide) persists correctly.
- `test_preset_update_and_new_items.lua` — applying a saved preset after new entries appeared (newly installed plugins, KOReader-update entries) preserves them: they are appended to the same menu they currently live under, keeping their hidden state, while the rest of the layout is restored exactly; also covers `updatePreset`, which overwrites an existing user preset with the current layout (long-press a preset row), refuses built-ins and unknown names, and captures moves plus hidden state.
- `test_stock_slot_insertion.lua` — healed update entries land at their curated stock slot instead of end-of-list: the reconciler aligns the saved list against the updated defaults and emits each unknown entry right before its next known sibling (user-moved items untouched, hidden entries neither resurrected nor blocking their slot, trailing additions still append, repeated launches idempotent).
- `test_restore_default_placement.lua` — a single entry can be reverted to its stock parent and curated slot in one action: unhides first when needed, detaches from custom locations, refuses provider-less entries without half-applied state, lets you restore the plugin's own entry (protection gates hiding only), and is offered both in editor hold dialogs and search-result actions.
- `test_hidden_display_mode.lua` — editors offer a display toggle for hidden entries: "preserve location" (default) keeps each dimmed hidden row at the position it occupied, anchored to its previous visible sibling with safe bottom-fallback when that anchor never renders; "bottom" collects them into the trailing section. The toggle lives in the tab-screen hamburger, persists across restarts, and visibility checkboxes respect whichever mode is active.
- `test_custom_menu_lifecycle.lua` — structural custom menus survive the full plugin lifecycle: More tools moved under Settings is captured by a preset; plugins installed afterwards anchor into the relocated list; disabling them ghost-hides their entries without breaking anything; reinstalling restores the exact spot; applying the older preset keeps both the custom placement and the plugin entry; hiding inside the custom menu survives preset application; and `updatePreset` + reset + reapply brings the whole customized world back.
- `test_mirroring.lua` — the live mirroring toggle: it persists across restarts, an FM move appears in the Reader file (and vice versa), disabling stops every cross-write, hide/unhide mirror symmetrically in both directions with per-view origin records, and items or destination menus unknown to the other view are skipped silently without creating ghost entries.
- `test_custom_submenus.lua` — creating submenus from the hamburger menu (at the bottom or below the selection, staging pending edits into the same atomic save), their titles surviving sanitize/disk reloads and rendering in KOReader's rebuilt menus, deletion rules for created submenus (empty-only), destination-chooser prioritization of same-menu submenus and parent menus, and reset behavior (parent reset keeps them, full reset clears them).

### Migration & identity suites

- `test_hint_migration.lua` — the governing rules ("untouched things follow the future; customized things follow the user") locked down as a table-driven matrix: plugin hint upgrades (untouched follows the new hint, explicit moves win, hides survive, unhide-after-upgrade lands at the new home, restore-default re-follows) and KOReader-update equivalents (relocated built-ins, upstream in-menu reorder flowing around single manual anchors, new tabs slotting near their surviving default neighbours).
- `test_provider_identity.lua` — identity is `(id, provider)`: temporal id reuse across different providers inherits nothing (visibility, placement, or disabled state), same-provider reinstall regains everything, simultaneous live collisions are attributed deterministically (smallest widget name wins, collision reported, no pin for unstable identities), provider id renames leave inert tombstones, and mirroring never transfers unknown ids across views.
- `test_submenu_safety.lua` — submenu moves into self or any descendant rejected (including indirect ring closures A→B→C→A), corrupt cyclic models repaired deterministically at the data layer and proven render-safe under the real MenuSorter, chaotic dense imports collapse to a single authoritative parent, deletion policy never orphans children (visible, hidden, or ghosted occupants all block deletion), and leaf↔submenu shape changes preserve customization.
- `test_ghost_isolation.lua` — absent-provider ghosts keep exactly one preserved parent, hidden ghosts render nowhere, ghosts don't disturb resets/sorting/slot healing, imposter providers get clean defaults while originals regain customization on return, plus 25 install/configure/uninstall cycles asserting normalized state after every cycle.
- `test_storage_resilience.lua` — atomic write pipeline (serialize → temp → parse → validate → rename; destination never holds a partial document; invalid shapes refused before commit), truncated/empty/malformed native files regenerate from canonical intent instead of wiping it, genuine deletions still revert, external edits under an open editor merge without silent overwrites, and a stale generation of our own output (crash between per-view writes) is recognized via previous-generation fingerprints and rematerialized.
- `test_self_absence_contract.lua` — documents the release-blocking stock KOReader crash when an orphaned sorting_hint targets an unreachable menu with this plugin absent (`patches/menusorter-sorting-hint-nil-guard.patch` proposes the upstream fix), and proves the runtime guard neutralizes exactly that input while installed.
- `test_insert_menu_singleton.lua` — repeated module execution and repeated Reader/FM construction render the plugin's own entry exactly once despite `ui/plugin/insert_menu`'s call-once contract.
- `test_state_machine.lua` — seeded random operation sequences (plugin install/uninstall/upgrade, user moves/hides/restores, upstream add/remove/reorder) against the pure pipeline with seven global invariants after every step: render-safety under the real MenuSorter, single-parent, hidden-isolation, acyclicity, determinism, user-wins, and default-wins. ~25,000 checks per full run; failures print seed and step for exact reproduction.
- `test_koreader_contract.lua` — pins every adapter assumption to the installed KOReader: settings parsing, mergeAndSort overlay mutation, reference consumption, disabled handling, reachable-hint attachment; documents the stock unreachable-hint crash (Error G); validates that the shipped upstream patch (`patches/menusorter-sorting-hint-nil-guard.patch`) still matches the installed `menusorter.lua` verbatim and proves in a sandbox that the patched sorter fixes the crash while remaining structurally identical on orphan-free input.
- `test_conditional_items.lua` — device-conditional entries (frontlight / physical keys / USB tab) across four capability states: untouched entries track capabilities exactly, customized ones keep their records through absence (ghost policy) and reactivate on return, conditional submenus carry adopted children back, render-safety holds throughout.
- `test_localization_identity.lua` — language switches change display titles but never customization: moves, hides and bulk sequences survive; presets round-trip independent of translated strings; equal localized labels tie-break deterministically by ID across restarts.
- `test_io_failure_injection.lua` — injected write/rename/persist failures: previous files stay byte-identical, sidecar baselines never advance on failure, no temp litter leaks, failed intent commits roll back the in-memory swap (and staged records are discarded like a process restart), healthy retries succeed afterwards.
- `test_drag_index_mapping.lua` — Error I at the editor layer: drops adjacent to hidden rows anchor to visible siblings only (in-place and bottom-hidden modes), rows are ID-keyed and unique, boundary drops in bottom mode cannot anchor into the hidden block, saved arrangements reload identically.

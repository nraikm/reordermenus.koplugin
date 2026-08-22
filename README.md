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

- Changes are written to KOReader's standard `reader_menu_order.lua` and `filemanager_menu_order.lua` settings files.
- Created submenus and their titles are stored inside the same order file under `KOMenu:custom_submenus`; they render in KOReader's menus without editing any core files.
- The plugin records the original menu of hidden items in `reorderingmenus_state.lua`; it removes this small sidecar automatically when no such items remain hidden.
- Presets are stored under `settings/menu_order_presets/` in the KOReader data directory.
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
```

Set `KO_HOME` to a separate KOReader data directory when you want an isolated development or test environment.

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

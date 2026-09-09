# KOReader compatibility

The automated integration baseline is
`v2025.10-43-g562fc11_2025-11-28`. Other releases may work, but must pass the same
suite before the support window expands. Capability probes are used where
KOReader exposes them; some private integration points still require wrappers.

## Integration map

| Boundary | Implementation | Purpose |
|---|---|---|
| Unreachable sorting hints | `lib/koreader_adapter.lua` | Prevent a nil dereference when a plugin points to a hidden or unreachable destination. |
| Submenu tap navigation | `lib/ui_compat.lua` | Add editor drill-down to sortable rows, scoped to active editor sessions. |
| Custom submenu injection | `lib/koreader_adapter.lua` | Supply user-created containers before stock sorting. |
| Dynamic submenu titles | `lib/ui_screens.lua` | Restore labels lost when stock sorting relocates dynamic submenus. |
| Restart fallback | `lib/koreader_adapter.lua` | Request a restart when live refresh fails, including on older KOReader versions. |
| Repeat registration | `main.lua` | Place the plugin through a sorting hint without duplicate shared-table insertions. |
| Live registration capture | `lib/koreader_adapter.lua` | Collect current IDs, providers, and sorting hints from registered widgets. |

## Workarounds and removal conditions

### Unreachable sorting hints

Stock `MenuSorter:sort` can dereference a missing `findById` result when a
third-party item's sorting hint points to a hidden or unreachable menu. The
adapter installs a nil-safe sorting wrapper.

Remove this guard only when supported KOReader versions handle missing hint
destinations safely, as proposed in
[`menusorter-sorting-hint-nil-guard.patch`](../patches/menusorter-sorting-hint-nil-guard.patch):

- Verify the upstream check in `frontend/ui/menusorter.lua` and its fallback.
- Remove `KoreaderAdapter.installMenuSorterGuards()` and its call in `main.lua`.
- Remove the patch file once upstream covers it.
- Run `./run_tests.sh tests/test_self_absence_contract.lua`.

### Submenu tap navigation

Stock `SortWidget` lacks a row-activation callback for opening submenu editors.
The plugin installs tap support lazily, reference-counts open editors, and
restores the original behavior after the last editor closes.

When supported versions expose a native row-tap or activation hook, replace the
integration and remove `UICompat.installSortWidgetSubmenuTap` and
`UICompat.releaseSortWidgetSubmenuTap` from `lib/ui_compat.lua` and their calls in
`lib/ui_screens.lua`. Verify navigation and editor teardown with the replacement.

### Custom submenu injection

User-created menus have no stock module registration. The adapter wraps
`MenuSorter.sort` to synthesize `KOMenu:custom_submenus` containers before sorting.
Replace this only when KOReader offers a dynamic provider API that can register
these containers and preserve their contents.

### Dynamic submenu titles

Stock sorting can copy static `text` while dropping `text_func` when relocating
a submenu. `UIScreens:sanitizeLiveMenuTree` repairs live labels after rebuilds
using cycle-safe traversal.

Remove the sanitizer only when upstream preserves dynamic title functions and
generators during menu rebuilding. Verify relocated dynamic submenus before
removing the method and its calls in `lib/ui_screens.lua`.

### Restart fallback

If live refresh fails or leaves stale caches, the UI offers a restart.
`KoreaderAdapter.requestRestart()` uses `UIManager:askForRestart` when available
and otherwise broadcasts a `Restart` event. Remove the fallback once the minimum
supported version provides the native API.

### Repeat registration

Reader/File Manager transitions can register the plugin more than once.
`main.lua` uses `sorting_hint = "more_tools"` and implicit placement instead of
repeatedly inserting into shared tables. Keep this defensive practice; it does
not need an upstream replacement.

### Live registration capture

`collectLiveRegistrations` replays registered widgets' `addToMainMenu` callbacks
when refreshing the registry. This captures provider identities and current
sorting hints, with deterministic collision handling.

Replace callback replay when KOReader exposes a revisioned, read-only registry
containing item IDs, providers, and sorting hints.

After changing an integration boundary, run its targeted coverage and the
appropriate suite tier from the [testing guide](testing.md).

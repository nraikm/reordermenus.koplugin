# KOReader Compatibility Matrix & Workaround-Removal Checklist

This document details all upstream KOReader compatibility boundaries, runtime defensive workarounds, and the exact upstream conditions required to safely remove each workaround.

---

## 1. Upstream Compatibility Matrix

| Workaround | Why Needed | Missing Upstream KOReader Capability | Detection Mechanism | Remove When |
|---|---|---|---|---|
| **MenuSorter Unreachable Sorting-Hint Guard** (`koreader_adapter.lua`) | Stock `MenuSorter:sort` attempts `sorting_hint_menu = self:findById(...)` and dereferences `.sub_item_table` without a nil check. If a third-party plugin item points to an unreachable or hidden tab, KOReader crashes at boot. | `MenuSorter` lacks defensive nil checks on `findById` results when resolving orphaned `sorting_hint` destinations. | Runtime patch installs a nil-safe wrapper in `MenuSorter:sort`. | Upstream KOReader merges `patches/menusorter-sorting-hint-nil-guard.patch` or adds `if sorting_hint_menu then ...` before inserting. |
| **SortWidget Submenu Tap Navigation** (`ui_compat.lua`) | Stock `SortWidget` only supports reordering drag interactions; tapping a submenu row does not open that submenu's editor. | `SortWidget` does not expose a row-tap event or drill-down callback interface for submenu entries. | Installed lazily and ref-counted during active Reordering Menus editor sessions; restored on editor close. | Upstream `SortWidget` natively provides an `on_tap` / `on_activate` hook for sortable rows. |
| **Custom Submenu Virtual Injection** (`koreader_adapter.lua`) | User-created submenus do not correspond to stock KOReader module registrations and would otherwise be rejected by `MenuSorter`. | KOReader lacks a dynamic runtime registry for user-defined menu categories. | Wraps `MenuSorter.sort` and synthesizes the canonical `KOMenu:custom_submenus` containers before stock sorting. | Upstream KOReader provides an extensible menu provider API allowing plugins to register custom submenu containers dynamically. |
| **Live Menu Tree Dynamic Title Sanitizer** (`ui_screens.lua`) | When a submenu with dynamic `text_func` is relocated by a custom order, stock `MenuSorter` copies only static `.text`, causing the row label to render as `nil`. | `MenuSorter` drops `text_func` during submenu position mapping. | Iterative cycle-safe live tree sanitizer (`sanitizeLiveMenuTree`) runs after live menu rebuilds. | Upstream `MenuSorter` preserves `text_func` and dynamic generators when rebuilding menus. |
| **Clean Restart API Fallback** (`koreader_adapter.lua`) | Immediate in-session live refresh may fail or leave stale layout caches. | Older KOReader versions do not expose `UIManager:askForRestart`. | Prompts via `ConfirmBox`; on confirmation, `KoreaderAdapter.requestRestart()` uses native `UIManager:askForRestart` when available, falling back to a broadcast `Restart` event. | When the minimum supported KOReader version includes `UIManager:askForRestart`. |
| **Single-Insertion Registration Guard** (`main.lua`) | `menu.registerToMainMenu` can be invoked multiple times across Reader/FileManager transitions or restarts. | KOReader's plugin loader does not deduplicate repeat registrations on `addToMainMenu`. | Uses `sorting_hint = "more_tools"` with implicit placement rather than mutating shared tables. | Permanent defensive practice; no upstream change needed. |
| **Live Registration Callback Replay** (`koreader_adapter.lua`) | Provider identity and current sorting hints are available only by asking registered widgets to populate a captured menu table. | KOReader exposes no revisioned, read-only registration snapshot. | `collectLiveRegistrations` replays each registered widget's `addToMainMenu` when a registry refresh is requested; collisions are resolved deterministically. | Upstream exposes a revisioned registration registry containing IDs, providers, and sorting hints. |

---

## 2. Workaround-Removal Checklist

For future maintainers: when upstream KOReader adds relevant capabilities, use this checklist to remove private workarounds:

### Checklist: Deleting the `MenuSorter` Sorting-Hint Guard
- [ ] Verify that the installed KOReader version includes a nil check in `frontend/ui/menusorter.lua`:
  ```lua
  local sorting_hint_menu = self:findById(menu_table["KOMenu:menu_buttons"], sorting_hint)
  if sorting_hint_menu then
      sorting_hint_menu = sorting_hint_menu.sub_item_table or sorting_hint_menu
      table.insert(sorting_hint_menu, v)
  else
      -- fallback to unknown hint or root
  end
  ```
- [ ] Remove `KoreaderAdapter.installMenuSorterGuards()` in `main.lua` and `koreader_adapter.lua`.
- [ ] Remove `patches/menusorter-sorting-hint-nil-guard.patch`.
- [ ] Verify with `./run_tests.sh tests/test_self_absence_contract.lua`.

### Checklist: Deleting the `SortWidget` Tap Enhancement
- [ ] Verify that stock `frontend/ui/widget/sortwidget.lua` supports row tapping or sub-item editing.
- [ ] Remove `UICompat.installSortWidgetSubmenuTap` and `UICompat.releaseSortWidgetSubmenuTap` in `ui_compat.lua` and `ui_screens.lua`.

### Checklist: Deleting Dynamic Submenu Title Repair
- [ ] Verify that `MenuSorter` copies `text_func` alongside `.text` during item ordering:
  ```lua
  sub_menu_position.text_func = sub_menu_content.text_func
  ```
- [ ] Remove `UIScreens:sanitizeLiveMenuTree` in `ui_screens.lua`.

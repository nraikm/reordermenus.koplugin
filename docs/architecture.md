# Architecture

Reordering Menus stores **explicit user choices**, then combines them with current
KOReader defaults and live plugin registrations to build each view's menus.
Untouched items follow upstream changes; customized items retain their recorded
placement, order, and visibility.

## Data flow

```text
KOReader defaults + live plugin registrations and sorting hints
                            │
                      registry.lua
                            │
Canonical intent ──► materializer.lua
                            │
                       validator.lua
                            │
                     native_writer.lua
                            │
                 KOReader's stock MenuSorter
```

`Materializer.resolve(registry, intent)` is pure and history-free: the same
inputs produce the same graph on cold start, reload, or restart. Previous
resolved graphs do not influence the result.

Resolution creates custom containers, applies parent changes and ordering
anchors, places untouched items using their defaults or sorting hints, and
handles visibility and dividers. Validation checks and repairs the graph before
native output is written. Only menu levels that differ from current defaults
are emitted.

## Module map

Plugin-local modules live under `lib/` and are required with dotted
`lib.*` names (`lib.menuorder_manager` resolves to
`lib/menuorder_manager.lua` through the plugin loader's package.path
template). `main.lua` and `_meta.lua` keep the loader-contract names at
the plugin root.

| Responsibility | Modules |
|---|---|
| Plugin entry point and KOReader integration | `main.lua`, `lib/koreader_adapter.lua` |
| Public operations used by editors and tests | `lib/menuorder_manager.lua` |
| Registry, resolution, and graph validation | `lib/registry.lua`, `lib/materializer.lua`, `lib/validator.lua` |
| Shared placement and visibility rules | `lib/placement.lua`, `lib/visibility.lua` |
| Canonical state, transactions, and migrations | `lib/intent_store.lua` |
| Commit, derived writes, and live reload | `lib/commit_pipeline.lua` |
| Native output and external-edit reconciliation | `lib/native_writer.lua`, `lib/semantic_diff.lua` |
| Safe loading and atomic file replacement | `lib/data_loader.lua`, `lib/atomic_writer.lua` |
| View and submenu presets | `lib/presets.lua` |
| Editor screens, helpers, and open-editor tracking | `lib/ui_screens.lua`, `lib/ui_editor_model.lua`, `lib/ui_editor_registry.lua` |
| Scoped SortWidget integration | `lib/ui_compat.lua` |

The manager translates editing operations into intent transactions. The commit
pipeline centralizes persistence and refresh, so callers can distinguish a
failed save from saved intent that still needs regeneration or a restart.

## Stored state

All paths below are relative to KOReader's `settings/` directory.

| File | Role |
|---|---|
| `reorderingmenus_intent.lua` | **Canonical customization state**, separated by view. Commit this first. |
| `reader_menu_order.lua`, `filemanager_menu_order.lua` | Derived overrides consumed by stock `MenuSorter`; regenerated when missing, invalid, or behind intent. |
| `reorderingmenus_materialization.lua` | Disposable checkpoint containing emission fingerprints and `intent_gen`; distinguishes plugin output from external edits. |
| `settings.reader.lua`, under `reorderingmenus` | Plugin preferences, including hidden-entry display and hidden built-in presets. |

Canonical intent contains sparse collections. An absent customization means
“follow the current default.” Display labels are never persistent identities.

| Collection | Records |
|---|---|
| `hidden` | Explicit hiding, with provider identity and hide order. |
| `parent_override` | Parent changes for items and custom containers. |
| `position_override` | Single-item placement relative to neighboring IDs. |
| `order_override` | Explicit menu sequences with a provider stamp on each entry. |
| `custom_menus` | Custom submenu IDs and titles. |
| `separators` | Anchored divider positions. |
| `raw_override` | Native edits that cannot be represented losslessly as semantic intent. |
| `tab_order` | Top-level tab sequence. |

## Rules that changes must preserve

### Placement and ownership

Each live item has at most one parent, and the menu hierarchy must be acyclic.
A submenu cannot move into itself or a descendant. Custom submenu IDs use
`custom_sub_<uuid>` and are registered under `KOMenu:custom_submenus`; deletion
requires the submenu to contain no visible or hidden items.

Top-level tabs always belong to `KOMenu:menu_buttons`. Users can reorder or hide
them, but cannot nest them inside ordinary menus: nested rows cannot render tab
icons and callbacks correctly. `Placement.canPlace` is the shared authority for
editor moves, preset/import paths, and resolution. Materializer fallback and
`Validator.removeNestedTabs` also repair unsupported tab nesting at runtime.
See [migration policy](migration-policy.md) for legacy placement recovery.

### Provider identity and missing items

Customizations identify an item by ID and provider (`stock` or `plugin:<name>`).
If that provider disappears, its records remain dormant and reactivate when it
returns. Another provider reusing the ID does not inherit stamped records.
Legacy records without a provider stamp match any provider.

A missing ordinary container also leaves its customization dormant until the
home returns. Explicitly unhiding an item can repair a stale home by choosing a
valid parent.

### Visibility

Explicit hiding differs from being inside a hidden ancestor, having no valid
parent, or belonging to an absent provider. `getVisibilityStatus` reports:

- `visible`: reachable in the active tree.
- `explicitly_hidden`: hidden by an applicable intent record.
- `hidden_by_ancestor`: inside a hidden or unreachable ancestor.
- `unplaced`: no valid parent.
- `provider_absent`: the contributing provider is unavailable.

Hidden items stay out of the active native tree through `KOMenu:disabled` or
menu-local hidden records. Intent retains their parent association.
`revealHiddenPath` unhides only ancestors on the item's path; restoring a row
must not claim success while it remains unreachable or reveal unrelated items.

### Ordering and raw edits

Bulk sequences carry provider stamps per entry; dividers live in anchored
`separators` records. A raw override exclusively owns its menu level, so load
and mutation paths remove conflicting semantic order and divider records.
External native edits are imported as semantic intent when possible, with raw
fallback for changes that cannot be represented losslessly.

## Saving and recovery

The write order is **commit intent, then derive native files**:

1. Stage a transaction against the current generation.
2. Serialize canonical intent to a unique temporary file, validate it, and
   atomically rename it into place.
3. Resolve and validate changed views, write their minimal native overrides,
   and checkpoint the emitted generation and fingerprints.
4. Reload requested live menus. Report whether the change is fully applied,
   needs regeneration, or requires a restart.

If execution stops after the canonical commit, the next launch detects the
checkpoint's generation mismatch and regenerates derived files. Atomic
replacement prevents readers from seeing partial files; it does not guarantee
hardware durability after a battery pull because it does not claim `fsync`.

Malformed canonical data is preserved before repair. Future schema versions
remain write-protected rather than being silently replaced. Version-specific
rules belong in the [migration policy](migration-policy.md).

## UI and compatibility boundaries

Editors provide reordering, visibility, valid moves, custom submenus, sorting,
scoped resets, and presets. Search and hidden-item tools are in editor menus.
**Advanced…** contains mirroring, hidden-entry display preferences, the read-only
resolved-override viewer, and removal preparation.

Mirroring applies to visibility changes and cross-menu moves when the item and
destination exist in both views. Reordering, dividers, tab order, restores, and
resets remain per-view. SortWidget tap support is scoped and reference-counted
while editors are open.

See the [compatibility guide](compatibility-matrix.md) for upstream workarounds,
the [testing guide](testing.md) for validation, and the [README](../README.md)
for user workflows.

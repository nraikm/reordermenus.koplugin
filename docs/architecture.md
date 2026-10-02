# Architecture

Reordering Menus stores **explicit user choices**, then combines them with current
KOReader defaults and live plugin registrations to build each view's menus.
Untouched items follow upstream changes; customized items retain their recorded
placement, order, and visibility.

## Data flow

```text
Native snapshot (shipped stock + live adoption, adapter-owned)
      +
Saved intent (sparse canonical records, store-owned)
      ↓
Optional draft (one staged transaction: base_revision + draft_intent)
      ↓
Resolver (single effective model + visibility + diagnostics)
   ↙      ↘
Editor   Native projection (disposable files + emission checkpoint)
             ↓
      KOReader's stock MenuSorter
```

External native edits enter through one semantic import boundary
(`IntentOps`: same ordering/membership/visibility/divider semantics as the
editor); hand-authored levels that are not losslessly representable keep a
verbatim raw passthrough. Previous resolved graphs never influence the
result: resolution is a pure function of (snapshot, intent).

`Resolver.resolve(registry, intent)` is the single effective entry: it
composes the pure `Materializer` placement/ordering pass, the `Validator`
render-safety repairs (single parent, acyclicity, hidden containment,
reachable tabs), and per-id `Visibility` reasons, returning ordered
lists, one effective parent per row, divider arrangement (incl.
dormant/unknown references), visibility reasons, and diagnostics.
Materializer/Validator/Visibility remain as its pure helpers, not separate
truths.

Resolution creates custom containers, applies parent changes and ordering
anchors, places untouched items using their defaults or sorting hints, and
handles visibility and dividers. Only menu levels that differ from current
defaults are emitted.

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
| One shared semantic mutation vocabulary | `lib/intent_ops.lua` (ordering, membership, visibility, dividers, customs, opaque) |
| One effective model (owns invariants, visibility, diagnostics) | `lib/resolver.lua` (composes the three below; they are helpers, not truths) |
| Registry, resolution, and graph validation | `lib/registry.lua`, `lib/materializer.lua`, `lib/validator.lua` |
| Shared placement and visibility rules | `lib/placement.lua`, `lib/visibility.lua` |
| Canonical state, transactions, and migrations | `lib/intent_store.lua` |
| Commit, derived writes, and live reload | `lib/commit_pipeline.lua` |
| Native output and external-edit reconciliation | `lib/native_writer.lua`, `lib/semantic_diff.lua` |
| Historical ordering API compatibility | `lib/semantic_diff_legacy.lua` |
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
| `separators` | Divider state per menu: normal anchored rows, per-slot removal marks (`removed`), or one explicit-empty sentinel (`zero_dividers`). |
| `raw_override` | Native edits that cannot be represented losslessly as semantic intent. |
| `tab_order` | Top-level tab sequence. |

Divider state per menu is exactly one of: absent (follow stock), a complete
explicit row list (replacement), removal marks for deleted stock slots only,
or explicit empty. Editor, native import, and legacy import share this model
through `IntentOps.setDividerArrangement`; tool-added file levels without a
baseline stay verbatim raw instead of guessed customs.

Statement rule (which staged lists author dividers): the editor writes
divider records only when the staged list carries divider rows, or when a
divider-free staged list matches both the current and the default items
(explicit clear). Items-only bulk sorts and reversals therefore never freeze
divider-free snapshots — dividers keep tracking stock across updates — while
divider verbs (insert/remove/SEP-row drags) stay exact. Import records both
halves when a hand file changes both (a file has no verb channel; dropping
either half would destroy user bytes).

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

## Synchronization boundaries

Exactly four mutating boundaries exist; everything else is pure:

- **Startup synchronization** (`Manager:startupSync`, also the lazy
  one-time trigger inside session creation): classifies each view's native
  file against its checkpoint (ours / external / missing / interrupted) and
  imports, regenerates, or reverts with a structured
  `{ changed, mode, committed, error }` result. After it reports synced,
  reads are pure until an explicit refresh, commit, or invalidation.
- **External refresh** (`reloadFromDisk`/`dropSessionState` for native files,
  `refreshRegistry` for provider drift): forces re-classification or derived
  re-emission. Never rewrites canonical intent (registry drift only marks
  derived output stale).
- **Commit** (`saveOrder`/`commitStaged` → `commit_pipeline`): canonical
  intent first in one durable write, then per-view derived projections and
  checkpoint updates, with per-view failure isolation.
- **Projection refresh** (`invalidate`): drops cached effective models.
  No I/O, no intent writes.

Reads (`loadOrder`, `getMenuItems`, `getTabs`, `isCustomized`, `stagedView`,
`peekTransaction`, second `startupSync`) perform no imports, writes,
regeneration, or UI refresh.

## Native snapshot definition

“KOReader's current arrangement before this plugin's customization” is one
object owned by the adapter: shipped stock bytes plus live adoption
(plugin tabs, reachable provider-backed menu trees, third-party insertions
at live slots) with per-id provider stamps. The shipped copy (`pristine`)
is captured once and never overwritten by adoption; the live module table
(which MenuSorter pollutes with our own emissions) is read-only order data
for adoption, and callback replay runs against an empty table, never
against it. `Manager.default_orders` is a test-only injection of replacement
shipped bytes (simulated KOReader updates); injected stock flows through the
same live-adoption pipeline as shipped stock and is fingerprinted by content,
so in-place mutation counts as an update too. Production always flows through
the adapter.

## UI and compatibility boundaries

Editors provide reordering, visibility, valid moves, custom submenus, sorting,
scoped resets, and presets. Search and hidden-item tools are in editor menus.
**Advanced…** contains mirroring, hidden-entry display preferences, the read-only
resolved-override viewer, and removal preparation.

Mirroring applies to visibility changes and cross-menu moves when the item and
destination exist in both views. Reordering, dividers, tab order, restores, and
resets remain per-view. SortWidget tap support is scoped and reference-counted
while editors are open.

Staging immediacy boundary: every verb that affects other levels or views
stages into the shared draft immediately (cross-menu moves at chooser time,
tabs via the reorder verb, menu-action moves with their save, visibility,
customs, resets, presets). Same-menu free-drag arrangement stays widget
interaction state until save — it is invisible elsewhere, and staging it per
keypress would let a nested save silently commit a parent's unconfirmed drags
past a later Discard. Dirty tracking therefore has two honest levels:
interaction (widget rows vs saved model) and staged (draft vs canonical).

See the [compatibility guide](compatibility-matrix.md) for upstream workarounds,
the [testing guide](testing.md) for validation, and the [README](../README.md)
for user workflows.

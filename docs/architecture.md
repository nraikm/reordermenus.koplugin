# Developer Architecture Documentation

This document describes the runtime architecture, domain model, persistence semantics, and structural invariants of the **Reordering Menus** plugin for KOReader.

---

## 1. Governing Principle: Sparse Declarative User Intent

Reordering Menus persists **only explicit user intent** — never an absolute snapshot of resolved menus. 

Menus are materialized at runtime as a pure function of:
1. Current KOReader stock menu defaults;
2. Currently registered plugin contributions and sorting hints;
3. Canonical user intent stored by the plugin.

```
       Current KOReader defaults (reader_menu_order / filemanager_menu_order defaults)
       Current live plugin contributions (+ sorting hints)
                         │
                         ▼
                   BASE REGISTRY                      (reorderingmenus_registry.lua)
                         │
      User Intent ───────┼───────────────────────────► MATERIALIZER (reorderingmenus_materializer.lua)
 (reorderingmenus_intent.lua)                          Pure resolve(registry, intent)
                         │
                         ▼
              VALIDATED MENU GRAPH                    (reorderingmenus_validator.lua)
                         │
                         ▼
          MINIMAL NATIVE OVERRIDES                    (reorderingmenus_native_writer.lua)
   (reader_menu_order.lua / filemanager_menu_order.lua)
                         │
                         ▼
                Stock KOReader MenuSorter
```

When KOReader or a third-party plugin updates:
- **Untouched menus and items follow future upstream changes automatically** without migration or drift.
- **Customized items follow the user's explicit instructions** (anchored placement or custom sequence).

---

## 2. Canonical vs Derived State

| Tier | File / Storage Location | Role & Authority | Mutability & Lifecycle |
|---|---|---|---|
| **Canonical Intent** | `settings/reorderingmenus_intent.lua` | **Authoritative source of truth**. Contains sparse user operations (moves, anchors, visibility toggles, created submenus, sequence eras). | Committed first on user action via atomic replacement. |
| **Derived Native Overrides** | `settings/reader_menu_order.lua`<br>`settings/filemanager_menu_order.lua` | **Derived projection** consumed by KOReader's stock `MenuSorter`. Contains only menus that deviate from stock. | Generated from canonical intent + current registry. Regenerated if missing, corrupt, or lagging. |
| **Reconciliation Metadata** | `settings/reorderingmenus_materialization.lua` | **Non-canonical cache & checkpoint**. Stores previous emission fingerprints and bound `intent_gen` to distinguish plugin emissions from hand edits. | Ephemeral checkpoint. Can be safely deleted; regenerated on next run. |
| **Plugin Preferences** | `settings/settings.reader.lua` (`["reorderingmenus"]`) | Presentation toggles (e.g., `hidden_in_place`, hidden built-in presets). | Independent user UI preferences. |

---

## 3. The Materialization Pipeline

### Pure Resolution
`Materializer.resolve(reg, intent)` is a **history-free, pure domain function**:
$$\text{Graph} = \text{resolve}(\text{Registry}, \text{Intent})$$
- Cold start, warm reload, and post-restart materializations are byte-for-byte identical.
- No cached "previous graphs" or stateful seeds leak across runs.

### Pipeline Stages
1. **Base Registry (`reorderingmenus_registry.lua`)**: Collects stock menu items and live plugin contributions via KOReader's `menu.registerToMainMenu` entries and sorting hints.
2. **Materializer (`reorderingmenus_materializer.lua`)**:
   - Applies custom submenu definitions and parent overrides.
   - Places explicitly moved items into their destination menus.
   - Evaluates single-item anchors (`position_override`) relative to surviving neighbor items.
   - Applies bulk sequence eras (`sequence_eras`) for sorted or staged lists.
   - Attaches uncustomized items to their default homes or hint destinations (implicit anchoring).
   - Isolates hidden items into `KOMenu:disabled` or menu-local hidden records.
3. **Validator (`reorderingmenus_validator.lua`)**: Checks structural invariants before any commit or disk write.
4. **Native Writer (`reorderingmenus_native_writer.lua`)**: Emits minimal native Lua tables only for menus that differ from stock defaults.

---

## 4. Structural Invariants

The materializer and validator strictly enforce the following invariants:

1. **Single Parent Rule**: Every live item belongs to at most one parent menu in the resolved hierarchy. No item may appear in multiple menus simultaneously.
2. **Acyclicity**: The submenu graph is strictly a directed acyclic graph (tree/forest). A submenu cannot be moved into itself or any of its descendants. Cyclic references are rejected or pruned during ingest.
3. **Hidden Isolation**: Hidden items are removed from the active native menu tree so KOReader does not render them. Their association with their original parent menu is preserved in canonical intent.
4. **Provider Identity `(id, provider)`**:
   - Customizations are stamped with the identity of the provider that served the item (`"stock"` or `"plugin:<name>"`).
   - If a plugin is uninstalled, its customized records become dormant **ghost records**. They do not contaminate or block new plugins that contribute the same ID.
   - Reinstalling the original plugin seamlessly restores the customized placement.
5. **Custom Submenu Ownership**: User-created submenus are registered under `KOMenu:custom_submenus` with unique IDs (`custom_sub_<uuid>`). Deleting a custom submenu is permitted only when it is completely empty of visible and hidden items.
6. **Raw vs Semantic Exclusivity**: If an external hand edit cannot be losslessly translated into semantic anchors, it is preserved as an isolated scoped override rather than corrupting canonical intent.

---

## 5. Persistence & Durability: Atomic Replacement

Persistence follows a strict **commit-first, derive-second** order:

1. **Transaction Stage**: Changes stage in memory against the current generation (`intent_gen`).
2. **Canonical Commit**: Canonical intent (`reorderingmenus_intent.lua`) is serialized, written to a unique temporary file (`*.tmp.*`), validated, and atomically renamed onto destination.
   > **Note on Durability**: Persistence uses **atomic replacement** (file replacement via `os.rename`). It guarantees that readers never observe partially written or truncated files. It does not claim battery-pull fsync hardware durability.
3. **Derived Native Output**: Minimal native override files (`reader_menu_order.lua`, `filemanager_menu_order.lua`) and sidecar metadata (`reorderingmenus_materialization.lua`) are written via atomic replacement.
4. **Crash Recovery**: If the system terminates between canonical commit and native write, the next launch detects the generation mismatch via the sidecar's `intent_gen` and rematerializes the native files automatically.

---

## 6. Feature Surface Taxonomy

To maintain simplicity and stability, features are classified into four clear categories:

### Core Features (Primary User Surface)
- Drag-and-drop item reordering in Book view and File Manager.
- Showing / hiding items and submenus via checkbox.
- Moving items and submenus to any valid destination menu.
- Creating and deleting custom submenus.
- Natural A–Z / Z–A sorting.
- Explicit scoped resets (item, submenu, Book view, File Manager, both views).
- Sparse view presets and direct/nested submenu presets.

### Advanced Features (`Tools → More tools → Reorder menus → Hamburger → Advanced…`)
- **Mirror changes (Book & File Manager)**: Bi-directional synchronization of moves and visibility toggles across both views.
- **Keep hidden entries in position**: Display toggle to keep hidden entries dimmed in-place versus collected at the bottom.
- **Manage hidden items**: Direct catalog of all hidden entries across menus.
- **Search menu items**: Unicode case-folded search across all menu titles and IDs.
- **Prepare for plugin removal**: Unhides all items across both views before uninstalling to ensure stock KOReader compatibility.

### Diagnostics Surface (`Advanced… → View resolved menu override`)
- **Resolved KOReader menu override**: Read-only text viewer displaying the exact derived Lua table written for KOReader's native `MenuSorter`. Separated from user editing surfaces.

### Deprecated / Removed Features
- **Dense full-tree snapshots**: Replaced by sparse intent presets. Legacy dense presets are converted on load.
- **File-path preset references**: Replaced by named descriptors and deterministic envelopes.
- **Global SortWidget monkey-patching**: Replaced by scoped, ref-counted tap installation active only while Reordering Menus editors are open.

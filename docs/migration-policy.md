# Migration & Version Support Policy

This document defines the versioning guarantees, migration pathways, and compatibility boundaries for Reordering Menus configurations and preset files.

---

## 1. Supported Schema & File Versions

### Canonical Intent (`reorderingmenus_intent.lua`)
- **Version 3 (Current)**: Sparse declarative intent. Provider identity for a bulk sequence lives on each `order_override.entries[]` record. Divider placement lives only in anchored `separators` records; `raw_override` is mutually exclusive with semantic order and divider records for its level.
- **Version 2**: Used menu-level `sequence_eras` and could contain inline separator tokens. It is normalized to v3 on load.
- **Version 1**: Pre-era canonical schema with flat sequence arrays. It is migrated through the same deterministic normalization path.
- **Version 0 / legacy `reorderingmenus_state.lua`**: Early persisted state. Automatically migrated to v3 canonical intent and superseded on startup.
- **Future Versions (`version > 3`)**: Refused and quarantined verbatim as an `*.unsupported*` artifact. The store remains write-protected until the user explicitly resets/imports, preventing an older build from overwriting newer data.

### Presets (`settings/menu_order_presets/`)
- **Format 2 (Current; independent of canonical schema v3)**: Captures only explicit intent (moves, hides, created submenus). View-typed (`view = "reader"` or `"filemanager"`) and forward-compatible across KOReader updates.
- **Format 1 (Dense Array Presets)**: Full-tree arrays from earlier versions. Fully supported on load; automatically converted against current stock defaults into sparse intent.

### Materialization Checkpoint (`reorderingmenus_materialization.lua`)
- **Writer Version 2**: Stores hash fingerprints and bound `intent_gen` per view. Ephemeral derived metadata; rebuilt automatically if absent or invalid.

---

## 2. Ingest Normalization & Lossless Recovery

1. **Automatic Format Upgrade**: Older configurations and presets are upgraded losslessly on first launch.
2. **Malformed Native Input Repair**: If a user hand-edits `reader_menu_order.lua` or `filemanager_menu_order.lua` into an invalid shape (cyclic trees, sparse arrays, duplicate IDs), the ingest pipeline normalizes the structure safely and preserves valid changes via minimal semantic diffing. Current-version contradictory canonical modes also converge on load: raw passthrough wins for its level, while historical inline dividers become anchored separator records.
3. **Provider Ghost Lifecycle**: Customizations for uninstalled plugins remain safely dormant. Reinstalling a plugin restores its previous configuration without user intervention.
4. **Stale Customization Cleanup**: The **Forget stale customizations** action (`MenuOrderManager:forgetStaleCustomizations`) discards dormant records for plugins that are no longer installed, allowing future reinstalls to adopt clean provider defaults.

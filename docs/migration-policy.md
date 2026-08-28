# Migration & Version Support Policy

This document defines the versioning guarantees, migration pathways, and compatibility boundaries for Reordering Menus configurations and preset files.

---

## 1. Supported Schema & File Versions

### Canonical Intent (`reorderingmenus_intent.lua`)
- **Version 2 (Current)**: Sparse declarative intent schema with provider-scoped records (`position_override`, `parent_override`, `hidden`, `custom_menus`, `sequence_eras`).
- **Version 1**: Pre-era canonical schema with flat sequence arrays. Losslessly migrated to v2 on load.
- **Version 0 (Legacy `reorderingmenus_state.lua`)**: Early sidecar state. Automatically migrated to v2 canonical intent and superseded on startup.
- **Future Versions (`version > 2`)**: Refused and quarantined verbatim (`*.corrupt-*`) to protect newer data from accidental downgrade corruption by older plugin releases.

### Presets (`settings/menu_order_presets/`)
- **Format 2 (Sparse Intent Envelopes)**: Captures only explicit intent (moves, hides, created submenus). View-typed (`view = "reader"` or `"filemanager"`) and forward-compatible across KOReader updates.
- **Format 1 (Dense Array Presets)**: Full-tree arrays from earlier versions. Fully supported on load; automatically converted against current stock defaults into sparse intent.

### Materialization Checkpoint (`reorderingmenus_materialization.lua`)
- **Writer Version 2**: Stores hash fingerprints and bound `intent_gen` per view. Ephemeral derived metadata; rebuilt automatically if absent or invalid.

---

## 2. Ingest Normalization & Lossless Recovery

1. **Automatic Format Upgrade**: Older configurations and presets are upgraded losslessly on first launch.
2. **Malformed Native Input Repair**: If a user hand-edits `reader_menu_order.lua` or `filemanager_menu_order.lua` into an invalid shape (cyclic trees, sparse arrays, duplicate IDs), the ingest pipeline normalizes the structure safely and preserves valid changes via minimal semantic diffing.
3. **Provider Ghost Lifecycle**: Customizations for uninstalled plugins remain safely dormant. Reinstalling a plugin restores its previous configuration without user intervention.
4. **Stale Customization Cleanup**: The **Forget stale customizations** action (`MenuOrderManager:forgetStaleCustomizations`) discards dormant records for plugins that are no longer installed, allowing future reinstalls to adopt clean provider defaults.

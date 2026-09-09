# Migration and version policy

Canonical intent, presets, and materialization checkpoints have independent
versions. Migrations preserve supported customization data; invalid structures
are repaired deterministically, and unsupported future data is protected.

## File versions

| File or format | Current version | Older data |
|---|---|---|
| `reorderingmenus_intent.lua` | Schema **3** | Unversioned/v0, v1, and v2 intent is normalized to v3; legacy `reorderingmenus_state.lua` is migrated on startup. |
| View and submenu presets in `settings/menu_order_presets/` | Envelope **2** | Legacy dense tables have neither `format` nor `version`; they are converted against current defaults on load. |
| `reorderingmenus_materialization.lua` | Writer **2** | Disposable fingerprints and per-view `intent_gen`; rebuilt when absent or invalid. |

Schema v3 puts provider stamps on individual `order_override.entries`, hide
order in `hidden[id].ordinal`, and custom-menu parents in `parent_override`.
Dividers use anchored `separators` records. It consolidates the older parallel
fields and removes derived UI bookkeeping.

Preset envelope v2 is the first versioned envelope, not canonical schema v2.
View presets capture sparse intent for `reader` or `filemanager`; submenu
presets capture direct or nested sequences and custom submenu titles. Dense
full-tree snapshots are a legacy input format, not the current storage model.

## Unsupported or malformed input

- **Future canonical schema (`version > 3`):** preserve the original at its
  canonical path and make a verbatim `*.unsupported*` backup. Refuse writes
  while the unsupported file remains, until an explicit reset/import or
  external replacement removes the protection.
- **Future preset envelope:** reject before applying anything and leave the
  source file unchanged. A format marker without a version, or a version
  without a format marker, is not treated as a legacy dense preset.
- **Malformed canonical intent:** preserve the original bytes before repair
  and report deterministic repairs. If preservation fails, do not overwrite
  the only surviving copy.
- **Malformed native overrides:** normalize cycles, sparse arrays, and duplicate
  IDs, then preserve representable edits through semantic diffing. Use a scoped
  raw override when a change cannot be represented losslessly.

At each raw-owned menu level, raw passthrough wins over contradictory semantic
order and divider records. Historical inline dividers become anchored separator
records during normalization.

## Missing providers and containers

Customizations for absent plugins remain dormant and resume when the same
provider returns. `MenuOrderManager:forgetStaleCustomizations` deliberately
discards stale records so a later reinstall can use provider defaults.

Missing ordinary containers are not reassigned during ingest: their intent
stays dormant until the home returns. Explicit unhiding can repair a stale home
to a valid parent.

## Legacy nested tabs

Older presets or native edits may place a top-level tab, such as Bookshelf,
inside an ordinary submenu. KOReader cannot render that placement correctly.
Preset application, dense import, and external import therefore:

1. Keep the tab in `KOMenu:menu_buttons`, retaining its children and callbacks.
2. Remove the unsupported nested sequence entry.
3. Filter `tab_order` to live tabs.

The source preset is never rewritten, so its original bytes remain recoverable.
`Materializer.effectiveParent` and `Validator.removeNestedTabs` provide runtime
fallback and repair for data that reaches resolution without normalization.

See [architecture](architecture.md) for persistence and identity rules, and
[testing](testing.md) for historical inputs and regression coverage.

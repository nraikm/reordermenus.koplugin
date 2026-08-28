# Reordering Menus for KOReader

Reorder, hide, move, and group KOReader menu items in both **Book view** and the **File Manager**, using KOReader's native interface.

<p align="center">
  <img src="screenshots/01-menu-order.png" width="46%" alt="Reordering the Book view menus">
  <img src="screenshots/02-submenu-order.png" width="46%" alt="Reordering the Tools submenu">
</p>

<p align="center">
  <img src="screenshots/03-submenu-actions.png" width="46%" alt="Actions available for the Tools submenu">
  <img src="screenshots/04-submenu-presets.png" width="46%" alt="Preset management for the Tools submenu">
</p>

## Features

- **Independent Layouts**: Customize top menus and submenus in Book view and File Manager independently.
- **Deep Reordering**: Open and reorder KOReader-defined nested submenus at any depth.
- **Show / Hide**: Toggle visibility of any item with a single tap on its checkbox.
- **Move Items & Submenus**: Move any item or complete submenu to another parent menu with cycle prevention.
- **Custom Submenus**: Create empty submenus anywhere in the hierarchy, name them, and organize items into them.
- **Mirroring (Optional)**: Mirror changes between Book view and File Manager automatically whenever the same items exist in both contexts.
- **Presets**: Save and restore complete view layouts or focused submenu presets (direct or nested).
- **Explicit Resets**: Reset a single item, an individual submenu, the current view (Book view or File Manager), or both views back to stock defaults.
- **Safe Upstream Updates**: Uncustomized menus and items follow future KOReader and plugin updates automatically without breaking your custom placements.

---

## Installation

1. Download the latest `reorderingmenus-v<version>.zip` from the [Releases](https://github.com/nraikm/ReorderingMenus/releases) page.
2. Unpack the zip file.
3. Copy the `reorderingmenus.koplugin` folder into your KOReader `plugins/` directory (e.g. `koreader/plugins/reorderingmenus.koplugin`).
4. Restart KOReader.

---

## Basic Workflow

Open the editor from the main menu:

```text
Tools → More tools → Reorder menus
```

- **Reorder**: Drag entries up or down to change their order.
- **Hide / Show**: Tap the checkbox next to any entry to hide or restore it.
- **Open a Submenu**: Tap a submenu row to select it, then tap it again (or choose **Edit submenu contents** in the hold dialog) to enter its editor.
- **Submenu Actions & Reset**: Tap the hamburger menu icon (top-left) to sort A–Z / Z–A, manage presets, create custom submenus, or reset the menu.
- **Save Changes**: Tap the checkmark icon in the bottom-right corner to save your changes.
- **Discard Changes**: Tap the title-bar `X` to prompt Save / Discard / Cancel, or use the bottom exit icon to leave without saving unsaved drag changes.

---

## Presets

### View Presets
The top-level hamburger menu (**Presets…**) lets you save the complete current layout (Book view or File Manager) as a named preset or restore built-in presets.

### Submenu Presets
Inside any submenu editor, open **Presets for _menu name_…**:
- **Save this menu order…** (`[Direct]`): Captures only the immediate item sequence of the current submenu.
- **Save with nested submenu orders…** (`[Nested]`): Captures the current submenu order plus all submenus nested within it.

Applying a preset updates item sequences while keeping your existing visibility settings and custom-created submenus intact.

---

## Important Safety & Plugin Removal Note

If you have hidden any top-level menus or tabs and plan to **disable or uninstall** Reordering Menus, use the removal preparation tool first:

```text
Tools → More tools → Reorder menus → Hamburger → Advanced… → Prepare for plugin removal…
```

This unhides all items across both views, ensuring that stock KOReader and other third-party plugins can find their default menu destinations without issue when Reordering Menus is no longer active.

---

## Supported KOReader Versions

- Compatible with current stable releases and nightly builds of KOReader.
- Works entirely within user settings (`settings/reader_menu_order.lua`, `settings/filemanager_menu_order.lua`, `settings/reorderingmenus_intent.lua`) without patching core KOReader application files.

---

## Developer Documentation

For architecture details, structural invariants, compatibility matrices, and developer workflows:

- [Developer Architecture Documentation](docs/architecture.md) — Explains the canonical sparse user intent model, materialization pipeline, validation, and persistence semantics.
- [KOReader Compatibility Matrix](docs/compatibility-matrix.md) — Documents runtime defensive workarounds and their exact removal conditions.
- [Migration & Version Policy](docs/migration-policy.md) — Details schema versioning and upgrade guarantees.

### Running Tests

Run the test suite with the LuaJIT bundled with your KOReader installation:

```bash
./run_tests.sh
```

To run a specific test suite or test tier:
```bash
./run_tests.sh tests/test_ui_flows.lua
TIER=ci ./run_tests.sh
```

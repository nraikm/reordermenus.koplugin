-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 63352,
  signature = "I7|untouched stock terminal",
  history = {
    { op = "apply_preset", args = { ["name"] = "default", } },
    { op = "upstream_reorder", args = { ["i"] = 1, ["menu"] = "navigation", ["view"] = "filemanager", } },
    { op = "io_fault_save", args = {} },
    { op = "save_preset", args = { ["name"] = "sm63352_1", ["view"] = "filemanager", } },
    { op = "save_submenu_preset", args = { ["menu"] = "navigation", ["name"] = "sub63352_1", ["view"] = "filemanager", } },
    { op = "upstream_add_tab", args = { ["id"] = "ntab1", ["view"] = "filemanager", } },
    { op = "insert_separator", args = { ["idx"] = 3, ["menu"] = "taps_and_gestures", } },
    { op = "restore_item_default", args = { ["id"] = "screenshot", } },
    { op = "plugin_install", args = { ["hint"] = "setting", ["id"] = "xitem1", ["name"] = "p1", ["view"] = "filemanager", } },
    { op = "insert_separator", args = { ["idx"] = 7, ["menu"] = "setting", } },
    { op = "move_item_to_menu", args = { ["dest"] = "device", ["from"] = "more_tools", ["id"] = "patch_management", } },
    { op = "hide_tab", args = { ["id"] = "search", } },
    { op = "restore_item_default", args = { ["id"] = "device_status_alarm", } },
    { op = "restart", args = {} },
    { op = "external_native_edit", args = { ["menu"] = "navigation", ["view"] = "filemanager", } },
    { op = "restart", args = {} },
  },
}
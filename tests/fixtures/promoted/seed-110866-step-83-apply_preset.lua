-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 110866,
  signature = "I7|order",
  history = {
    { op = "save_preset", args = { ["name"] = "sm110866_1", ["view"] = "filemanager", } },
    { op = "toggle_mirroring", args = { ["enabled"] = true, } },
    { op = "move_item_to_menu", args = { ["dest"] = "search", ["from"] = "navigation", ["id"] = "physical_buttons_setup", } },
    { op = "stage_list_permutation", args = { ["menu"] = "more_tools", ["seq"] = { [1] = "battery_statistics", [2] = "terminal", [3] = "patch_management", [4] = "plugin_management", [5] = "synchronize_time", [6] = "book_shortcuts", [7] = "doc_setting_tweak", [8] = "auto_frontlight", [9] = "developer_options", [10] = "keep_alive", [11] = "advanced_settings", }, } },
    { op = "apply_preset", args = { ["name"] = "sm110866_1", } },
  },
}
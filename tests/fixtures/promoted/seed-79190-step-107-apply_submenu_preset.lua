-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 79190,
  signature = "I7|order",
  history = {
    { op = "external_native_edit", args = { ["menu"] = "more_tools", ["view"] = "filemanager", } },
    { op = "delete_native_file", args = { ["view"] = "filemanager", } },
    { op = "save_submenu_preset", args = { ["menu"] = "more_tools", ["name"] = "sub79190_1", ["view"] = "filemanager", } },
    { op = "move_item_in_menu", args = { ["from"] = 9, ["menu"] = "more_tools", ["to"] = 5, } },
    { op = "apply_submenu_preset", args = { ["menu"] = "more_tools", ["preset"] = "submenu_sub79190_1", ["view"] = "filemanager", } },
  },
}
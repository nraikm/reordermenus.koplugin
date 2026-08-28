-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 427626,
  signature = "I16|disabled mismatch",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "move_item_to_menu", args = { ["dest"] = "filemanager", ["from"] = "tools", ["id"] = "move_to_archive", } },
    { op = "hide_tab", args = { ["id"] = "filemanager", } },
  },
}
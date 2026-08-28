-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 364274,
  signature = "I16|disabled mismatch",
  history = {
    { op = "move_item_to_menu", args = { ["dest"] = "plus_menu", ["from"] = "device", ["id"] = "units", } },
    { op = "hide_tab", args = { ["id"] = "plus_menu", } },
  },
}
-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 134623,
  signature = "I16|disabled mismatch",
  history = {
    { op = "move_item_to_menu", args = { ["dest"] = "plus_menu", ["from"] = "navigation", ["id"] = "android_volume_keys", } },
    { op = "hide_tab", args = { ["id"] = "plus_menu", } },
  },
}
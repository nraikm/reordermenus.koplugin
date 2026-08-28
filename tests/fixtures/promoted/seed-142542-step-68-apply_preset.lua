-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 142542,
  signature = "I7|order",
  history = {
    { op = "hide_item", args = { ["id"] = "vocabbuilder", ["parent"] = "search", } },
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "save_preset", args = { ["name"] = "sm142542_1", ["view"] = "reader", } },
    { op = "move_item_in_menu", args = { ["from"] = 5, ["menu"] = "tools", ["to"] = 1, } },
    { op = "apply_preset", args = { ["name"] = "sm142542_1", } },
  },
}
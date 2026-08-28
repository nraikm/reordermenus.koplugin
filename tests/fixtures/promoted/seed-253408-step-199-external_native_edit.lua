-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 253408,
  signature = "I16|disabled mismatch",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "insert_separator", args = { ["idx"] = 13, ["menu"] = "navi", } },
    { op = "save_order", args = {} },
    { op = "upstream_add", args = { ["id"] = "nitem4", ["menu"] = "navi", ["view"] = "reader", } },
    { op = "move_item_in_menu", args = { ["from"] = 19, ["menu"] = "navi", ["to"] = 6, } },
    { op = "restart", args = {} },
    { op = "upstream_remove_tab", args = { ["id"] = "navi", ["view"] = "reader", } },
    { op = "external_native_edit", args = { ["menu"] = "filemanager", ["view"] = "reader", } },
  },
}
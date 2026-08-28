-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 150461,
  signature = "I16|disabled mismatch",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "external_native_edit", args = { ["menu"] = "navi_settings", ["view"] = "reader", } },
    { op = "external_native_edit", args = { ["menu"] = "exit_menu", ["view"] = "reader", } },
    { op = "external_native_edit", args = { ["menu"] = "navi_settings", ["view"] = "reader", } },
    { op = "upstream_remove_tab", args = { ["id"] = "navi", ["view"] = "reader", } },
    { op = "external_native_edit", args = { ["menu"] = "search_settings", ["view"] = "reader", } },
  },
}
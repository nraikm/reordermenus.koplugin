-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 31676,
  signature = "I16|disabled mismatch",
  history = {
    { op = "create_submenu", args = { ["parent"] = "navigation", ["title"] = "Tools", } },
    { op = "copy_layout", args = {} },
    { op = "reset_view", args = {} },
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "upstream_remove_tab", args = { ["id"] = "setting", ["view"] = "reader", } },
    { op = "external_native_edit", args = { ["menu"] = "exit_menu", ["view"] = "reader", } },
  },
}
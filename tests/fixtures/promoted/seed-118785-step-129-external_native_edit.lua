-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 118785,
  signature = "I16|disabled mismatch",
  history = {
    { op = "upstream_add", args = { ["id"] = "nitem1", ["menu"] = "typeset", ["view"] = "reader", } },
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "create_submenu", args = { ["parent"] = "typeset", ["title"] = "中文菜单", } },
    { op = "save_order", args = {} },
    { op = "upstream_remove_tab", args = { ["id"] = "typeset", ["view"] = "reader", } },
    { op = "external_native_edit", args = { ["menu"] = "search", ["view"] = "reader", } },
  },
}
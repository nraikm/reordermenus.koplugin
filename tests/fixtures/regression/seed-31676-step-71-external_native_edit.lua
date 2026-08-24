-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
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
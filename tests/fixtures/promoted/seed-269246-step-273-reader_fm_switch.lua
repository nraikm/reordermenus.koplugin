-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 269246,
  signature = "I16|disabled mismatch&&I7|untouched stock terminal",
  history = {
    { op = "hide_item", args = { ["id"] = "terminal", ["parent"] = "more_tools", } },
    { op = "upstream_add", args = { ["id"] = "nitem17", ["menu"] = "exit_menu", ["view"] = "reader", } },
  },
}
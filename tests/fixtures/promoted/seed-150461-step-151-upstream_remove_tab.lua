-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 150461,
  signature = "I16|disabled mismatch&&I7|untouched stock statistics",
  history = {
    { op = "hide_item", args = { ["id"] = "statistics", ["parent"] = "tools", } },
    { op = "upstream_add", args = { ["id"] = "nitem1", ["menu"] = "help", ["view"] = "reader", } },
  },
}
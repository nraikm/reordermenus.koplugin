-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 47514,
  signature = "I16|disabled mismatch&&I7|untouched stock language_support",
  history = {
    { op = "hide_item", args = { ["id"] = "language_support", ["parent"] = "document", } },
    { op = "upstream_remove", args = { ["id"] = "network_restore", ["menu"] = "network", ["view"] = "reader", } },
  },
}
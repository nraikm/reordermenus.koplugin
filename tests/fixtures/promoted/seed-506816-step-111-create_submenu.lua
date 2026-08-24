-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 506816,
  signature = "I16|disabled mismatch&&I7|untouched stock mass_storage_actions",
  history = {
    { op = "hide_item", args = { ["id"] = "mass_storage_actions", ["parent"] = "main", } },
    { op = "upstream_add_tab", args = { ["id"] = "ntab4", ["view"] = "reader", } },
  },
}
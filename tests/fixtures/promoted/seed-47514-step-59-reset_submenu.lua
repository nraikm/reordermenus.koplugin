-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 47514,
  signature = "I7|untouched stock navigation",
  history = {
    { op = "hide_item", args = { ["id"] = "navigation", ["parent"] = "setting", } },
    { op = "upstream_remove", args = { ["id"] = "handmade_hidden_flows", ["menu"] = "navi_settings", ["view"] = "reader", } },
  },
}
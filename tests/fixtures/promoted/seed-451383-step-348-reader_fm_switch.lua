-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 451383,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 1, ["menu"] = "screen", ["to"] = 5, } },
    { op = "upstream_reorder", args = { ["i"] = 1, ["menu"] = "more_tools", ["view"] = "reader", } },
  },
}
-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 31676,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 3, ["menu"] = "help", ["to"] = 8, } },
    { op = "remove_separator", args = { ["idx"] = 8, ["menu"] = "more_tools", } },
  },
}
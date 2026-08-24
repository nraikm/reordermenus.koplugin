-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 744386,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 2, ["menu"] = "search_settings", ["to"] = 1, } },
    { op = "remove_separator", args = { ["idx"] = 8, ["menu"] = "more_tools", } },
  },
}
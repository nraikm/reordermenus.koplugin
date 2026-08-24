-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 39595,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 1, ["menu"] = "main", ["to"] = 9, } },
    { op = "upstream_add", args = { ["id"] = "nitem2", ["menu"] = "help", ["view"] = "reader", } },
  },
}
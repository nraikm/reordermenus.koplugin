-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 142542,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 10, ["menu"] = "network", ["to"] = 4, } },
    { op = "upstream_remove_tab", args = { ["id"] = "typeset", ["view"] = "reader", } },
  },
}
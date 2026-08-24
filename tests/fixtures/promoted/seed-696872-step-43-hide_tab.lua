-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 696872,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 1, ["menu"] = "more_tools", ["to"] = 5, } },
    { op = "upstream_add", args = { ["id"] = "nitem3", ["menu"] = "device", ["view"] = "reader", } },
  },
}
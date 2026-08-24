-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 593925,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 17, ["menu"] = "device", ["to"] = 1, } },
    { op = "external_native_edit", args = { ["menu"] = "search", ["view"] = "reader", } },
  },
}
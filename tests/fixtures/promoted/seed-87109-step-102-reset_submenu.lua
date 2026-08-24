-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 87109,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 3, ["menu"] = "more_tools", ["to"] = 7, } },
    { op = "delete_native_file", args = { ["view"] = "reader", } },
  },
}
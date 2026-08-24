-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 388031,
  signature = "I7|order",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "move_item_in_menu", args = { ["from"] = 3, ["menu"] = "help", ["to"] = 5, } },
    { op = "move_item_in_menu", args = { ["from"] = 10, ["menu"] = "search", ["to"] = 11, } },
  },
}
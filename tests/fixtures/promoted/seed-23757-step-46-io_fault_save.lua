-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 23757,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 5, ["menu"] = "document", ["to"] = 2, } },
    { op = "io_fault_save", args = {} },
  },
}
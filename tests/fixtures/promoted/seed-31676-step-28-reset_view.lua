-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 31676,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 2, ["menu"] = "device", ["to"] = 17, } },
    { op = "hide_item", args = { ["id"] = "system_statistics", ["parent"] = "help", } },
    { op = "reset_view", args = {} },
  },
}
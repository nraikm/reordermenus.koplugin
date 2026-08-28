-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 530573,
  signature = "I7|order",
  history = {
    { op = "hide_item", args = { ["id"] = "battery_statistics", ["parent"] = "more_tools", } },
    { op = "move_item_in_menu", args = { ["from"] = 1, ["menu"] = "more_tools", ["to"] = 2, } },
    { op = "unhide_item", args = { ["id"] = "battery_statistics", } },
  },
}
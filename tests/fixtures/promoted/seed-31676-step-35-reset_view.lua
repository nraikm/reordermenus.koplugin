-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 31676,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 8, ["menu"] = "help", ["to"] = 9, } },
    { op = "hide_item", args = { ["id"] = "plugin_management", ["parent"] = "more_tools", } },
    { op = "reset_view", args = {} },
  },
}
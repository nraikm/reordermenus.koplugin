-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 23757,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 1, ["menu"] = "navigation", ["to"] = 5, } },
    { op = "create_submenu", args = { ["parent"] = "more_tools", ["title"] = "Tools", } },
  },
}
-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 356355,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 11, ["menu"] = "more_tools", ["to"] = 7, } },
    { op = "create_submenu", args = { ["parent"] = "exit_menu", ["title"] = "Tools", } },
  },
}
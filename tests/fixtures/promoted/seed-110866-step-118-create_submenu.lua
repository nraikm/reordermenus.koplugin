-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 110866,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 2, ["menu"] = "document", ["to"] = 1, } },
    { op = "create_submenu", args = { ["parent"] = "more_tools", ["title"] = "Tools", } },
  },
}
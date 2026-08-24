-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 79190,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 6, ["menu"] = "tools", ["to"] = 5, } },
    { op = "create_submenu", args = { ["parent"] = "device", ["title"] = "Notes", } },
  },
}
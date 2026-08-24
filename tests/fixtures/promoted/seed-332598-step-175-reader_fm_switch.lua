-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 332598,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 8, ["menu"] = "help", ["to"] = 7, } },
    { op = "upstream_add", args = { ["id"] = "nitem5", ["menu"] = "reorderingmenus:user:2a11637386d91b311c8ea1b178fc94a2", ["view"] = "reader", } },
  },
}
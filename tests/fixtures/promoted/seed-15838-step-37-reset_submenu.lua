-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 15838,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 11, ["menu"] = "setting", ["to"] = 5, } },
    { op = "upstream_remove", args = { ["id"] = "autoturn", ["menu"] = "navi", ["view"] = "reader", } },
  },
}
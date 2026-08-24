-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 39595,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 1, ["menu"] = "search_settings", ["to"] = 2, } },
    { op = "external_native_edit", args = { ["menu"] = "more_tools", ["view"] = "reader", } },
  },
}
-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 253408,
  signature = "I7|order",
  history = {
    { op = "sort_menu_za", args = { ["menu"] = "search_settings", ["seq"] = { [1] = "wikipedia_settings", [2] = "dictionary_settings", }, } },
    { op = "move_item_in_menu", args = { ["from"] = 5, ["menu"] = "tools", ["to"] = 5, } },
  },
}
-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 39595,
  signature = "I7|order",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "search_settings", ["seq"] = { [1] = "wikipedia_settings", [2] = "dictionary_settings", }, } },
    { op = "move_item_in_menu", args = { ["from"] = 5, ["menu"] = "device", ["to"] = 5, } },
  },
}
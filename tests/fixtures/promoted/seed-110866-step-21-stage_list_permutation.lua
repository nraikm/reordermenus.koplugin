-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 110866,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 9, ["menu"] = "filemanager_settings", ["to"] = 7, } },
    { op = "stage_list_permutation", args = { ["menu"] = "search_settings", ["seq"] = { [1] = "dictionary_settings", [2] = "wikipedia_settings", }, } },
  },
}
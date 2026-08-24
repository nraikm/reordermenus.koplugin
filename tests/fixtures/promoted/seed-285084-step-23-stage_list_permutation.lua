-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 285084,
  signature = "I7|order",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "search_settings", ["seq"] = { [1] = "wikipedia_settings", [2] = "dictionary_settings", }, } },
    { op = "stage_list_permutation", args = { ["menu"] = "search_settings", ["seq"] = { [1] = "dictionary_settings", [2] = "wikipedia_settings", }, } },
  },
}
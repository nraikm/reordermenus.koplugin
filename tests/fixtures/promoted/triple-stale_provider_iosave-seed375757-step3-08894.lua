-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 375757,
  signature = "I7|order",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "stage_list_permutation", args = { ["menu"] = "search_settings", ["seq"] = { [1] = "fulltext_search_settings", [2] = "translation_settings", [3] = "dictionary_settings", [4] = "wikipedia_settings", }, } },
    { op = "stage_list_permutation", args = { ["menu"] = "search_settings", ["seq"] = { [1] = "dictionary_settings", [2] = "wikipedia_settings", [3] = "translation_settings", [4] = "fulltext_search_settings", }, } },
  },
}
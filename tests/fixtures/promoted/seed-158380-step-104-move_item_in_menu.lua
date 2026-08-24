-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 158380,
  signature = "I7|order",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "search_settings", ["seq"] = { [1] = "translation_settings", [2] = "fulltext_search_settings", [3] = "wikipedia_settings", [4] = "dictionary_settings", }, } },
    { op = "upstream_remove", args = { ["id"] = "toc_items_font_size", ["menu"] = "navi_settings", ["view"] = "reader", } },
  },
}
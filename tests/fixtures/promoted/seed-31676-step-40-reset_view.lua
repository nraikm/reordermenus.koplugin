-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 31676,
  signature = "I7|order",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "search_settings", ["seq"] = { [1] = "wikipedia_settings", [2] = "dictionary_settings", [3] = "nitem1", }, } },
    { op = "hide_item", args = { ["id"] = "document_metadata_location", ["parent"] = "document", } },
    { op = "reset_view", args = {} },
  },
}
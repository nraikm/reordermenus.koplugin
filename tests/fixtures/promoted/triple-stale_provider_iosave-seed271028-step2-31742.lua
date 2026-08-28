-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 271028,
  signature = "I7|order",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "search", ["seq"] = { [1] = "vocabbuilder", [2] = "wikipedia_lookup", [3] = "opds", [4] = "dictionary_lookup_history", [5] = "file_search_results", [6] = "find_book_in_calibre_catalog", [7] = "search_settings", [8] = "file_search", [9] = "dictionary_lookup", [10] = "wikipedia_history", }, } },
    { op = "io_fault_save", args = {} },
  },
}
-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 480486,
  signature = "I7|order",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "search", ["seq"] = { [1] = "opds", [2] = "dictionary_lookup_history", [3] = "dictionary_lookup", [4] = "wikipedia_lookup", [5] = "file_search", [6] = "vocabbuilder", [7] = "wikipedia_history", [8] = "search_settings", [9] = "file_search_results", [10] = "find_book_in_calibre_catalog", }, } },
    { op = "io_fault_save", args = {} },
  },
}
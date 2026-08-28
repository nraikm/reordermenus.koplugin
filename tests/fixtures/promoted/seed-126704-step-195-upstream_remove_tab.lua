-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 126704,
  signature = "I6|progress_sync",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "reorder_tabs", args = { ["tabs"] = { [1] = "tools", [2] = "main", [3] = "search", [4] = "typeset", }, } },
    { op = "stage_list_permutation", args = { ["menu"] = "search", ["seq"] = { [1] = "wikipedia_lookup", [2] = "vocabbuilder", [3] = "dictionary_lookup", [4] = "translate_current_page", [5] = "progress_sync", [6] = "find_book_in_calibre_catalog", [7] = "wikipedia_history", [8] = "search_settings", [9] = "fulltext_search_findall_results", [10] = "dictionary_lookup_history", [11] = "bookmark_search", [12] = "fulltext_search", }, } },
    { op = "save_order", args = {} },
    { op = "upstream_remove_tab", args = { ["id"] = "search", ["view"] = "reader", } },
  },
}
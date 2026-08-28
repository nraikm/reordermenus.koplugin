-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 530573,
  signature = "I6|physical_buttons_setup",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "save_order", args = {} },
    { op = "external_native_edit", args = { ["menu"] = "taps_and_gestures", ["view"] = "reader", } },
    { op = "stage_list_permutation", args = { ["menu"] = "search", ["seq"] = { [1] = "bookmark_search", [2] = "vocabbuilder", [3] = "dictionary_lookup", [4] = "wikipedia_history", [5] = "fulltext_search", [6] = "find_book_in_calibre_catalog", [7] = "fulltext_search_findall_results", [8] = "search_settings", [9] = "xitem5", [10] = "translate_current_page", [11] = "dictionary_lookup_history", [12] = "wikipedia_lookup", }, } },
    { op = "save_order", args = {} },
    { op = "upstream_remove_tab", args = { ["id"] = "search", ["view"] = "reader", } },
    { op = "move_item_to_menu", args = { ["dest"] = "search", ["from"] = "navigation", ["id"] = "physical_buttons_setup", } },
  },
}
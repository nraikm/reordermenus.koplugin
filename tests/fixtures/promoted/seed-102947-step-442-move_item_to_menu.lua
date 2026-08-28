-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 102947,
  signature = "I6|patch_management",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "stage_list_permutation", args = { ["menu"] = "search", ["seq"] = { [1] = "vocabbuilder", [2] = "translate_current_page", [3] = "fulltext_search", [4] = "dictionary_lookup", [5] = "bookmark_search", [6] = "search_settings", [7] = "wikipedia_lookup", [8] = "find_book_in_calibre_catalog", [9] = "fulltext_search_findall_results", [10] = "dictionary_lookup_history", [11] = "wikipedia_history", }, } },
    { op = "save_order", args = {} },
    { op = "upstream_remove_tab", args = { ["id"] = "search", ["view"] = "reader", } },
    { op = "reorder_tabs", args = { ["tabs"] = { [1] = "navi", [2] = "typeset", [3] = "filemanager", [4] = "search", [5] = "tools", [6] = "ntab2", }, } },
    { op = "move_item_to_menu", args = { ["dest"] = "search", ["from"] = "more_tools", ["id"] = "patch_management", } },
  },
}
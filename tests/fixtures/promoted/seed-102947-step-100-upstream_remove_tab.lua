-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 102947,
  signature = "I6|read_timer",
  history = {
    { op = "sort_menu_az", args = { ["menu"] = "search", ["seq"] = { [1] = "dictionary_lookup", [2] = "dictionary_lookup_history", [3] = "file_search", [4] = "file_search_results", [5] = "find_book_in_calibre_catalog", [6] = "nitem1", [7] = "opds", [8] = "search_settings", [9] = "vocabbuilder", [10] = "wikipedia_lookup", }, } },
    { op = "save_order", args = {} },
    { op = "move_item_to_menu", args = { ["dest"] = "search", ["from"] = "tools", ["id"] = "read_timer", } },
    { op = "external_native_edit", args = { ["menu"] = "help", ["view"] = "filemanager", } },
    { op = "upstream_remove_tab", args = { ["id"] = "search", ["view"] = "filemanager", } },
  },
}
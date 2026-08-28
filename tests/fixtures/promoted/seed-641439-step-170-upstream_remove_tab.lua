-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 641439,
  signature = "I6|collections",
  history = {
    { op = "sort_menu_za", args = { ["menu"] = "search", ["seq"] = { [1] = "wikipedia_lookup", [2] = "wikipedia_history", [3] = "vocabbuilder", [4] = "search_settings", [5] = "opds", [6] = "find_book_in_calibre_catalog", [7] = "file_search", [8] = "dictionary_lookup_history", [9] = "dictionary_lookup", }, } },
    { op = "reorder_tabs", args = { ["tabs"] = { [1] = "ntab1", [2] = "ntab2", [3] = "main", [4] = "tools", [5] = "ntab5", [6] = "plus_menu", [7] = "search", }, } },
    { op = "copy_layout", args = {} },
    { op = "toggle_mirroring", args = { ["enabled"] = true, } },
    { op = "move_item_to_menu", args = { ["dest"] = "search", ["from"] = "main", ["id"] = "collections", } },
    { op = "save_order", args = {} },
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "upstream_remove_tab", args = { ["id"] = "search", ["view"] = "reader", } },
  },
}
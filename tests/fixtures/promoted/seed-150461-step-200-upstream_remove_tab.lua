-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 150461,
  signature = "I6|document_settings",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "save_order", args = {} },
    { op = "stage_list_permutation", args = { ["menu"] = "navi", ["seq"] = { [1] = "book_map", [2] = "bookmark_browsing_mode", [3] = "go_to", [4] = "page_browser", [5] = "autoturn", [6] = "go_to_next_location", [7] = "go_to_previous_location", [8] = "skim_to", [9] = "hide_nonlinear_flows", [10] = "table_of_contents", [11] = "bookmarks", [12] = "navi_settings", [13] = "toggle_bookmark", }, } },
    { op = "external_native_edit", args = { ["menu"] = "more_tools", ["view"] = "reader", } },
    { op = "move_item_to_menu", args = { ["dest"] = "navi", ["from"] = "typeset", ["id"] = "document_settings", } },
    { op = "save_order", args = {} },
    { op = "upstream_remove_tab", args = { ["id"] = "navi", ["view"] = "reader", } },
  },
}
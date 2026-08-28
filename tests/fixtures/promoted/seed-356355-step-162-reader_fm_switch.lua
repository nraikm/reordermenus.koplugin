-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 356355,
  signature = "I6|favorites",
  history = {
    { op = "sort_menu_za", args = { ["menu"] = "navi", ["seq"] = { [1] = "toggle_bookmark", [2] = "table_of_contents", [3] = "skim_to", [4] = "page_browser", [5] = "navi_settings", [6] = "highlight_options", [7] = "hide_nonlinear_flows", [8] = "go_to_previous_location", [9] = "go_to_next_location", [10] = "go_to", [11] = "bookmarks", [12] = "bookmark_browsing_mode", [13] = "book_map", [14] = "autoturn", }, } },
    { op = "reorder_tabs", args = { ["tabs"] = { [1] = "tools", [2] = "ntab2", [3] = "typeset", [4] = "setting", [5] = "search", [6] = "navi", [7] = "main", [8] = "filemanager", }, } },
    { op = "move_item_to_menu", args = { ["dest"] = "navi", ["from"] = "main", ["id"] = "favorites", } },
  },
}
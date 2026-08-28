-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 110866,
  signature = "I6|collections",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "navi", ["seq"] = { [1] = "bookmarks", [2] = "toggle_bookmark", [3] = "autoturn", [4] = "page_browser", [5] = "go_to_next_location", [6] = "navi_settings", [7] = "go_to_previous_location", [8] = "skim_to", [9] = "bookmark_browsing_mode", [10] = "table_of_contents", [11] = "hide_nonlinear_flows", [12] = "go_to", [13] = "book_map", }, } },
    { op = "reorder_tabs", args = { ["tabs"] = { [1] = "typeset", [2] = "filemanager", [3] = "main", [4] = "navi", [5] = "tools", [6] = "setting", [7] = "search", }, } },
    { op = "move_item_to_menu", args = { ["dest"] = "navi", ["from"] = "main", ["id"] = "collections", } },
  },
}
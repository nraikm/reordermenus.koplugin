-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 514735,
  signature = "I16|disabled mismatch",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "navi", ["seq"] = { [1] = "book_map", [2] = "autoturn", [3] = "bookmark_browsing_mode", [4] = "page_browser", [5] = "go_to_next_location", [6] = "go_to", [7] = "hide_nonlinear_flows", [8] = "table_of_contents", [9] = "go_to_previous_location", [10] = "toggle_bookmark", [11] = "skim_to", [12] = "navi_settings", [13] = "bookmarks", }, } },
    { op = "reorder_tabs", args = { ["tabs"] = { [1] = "main", [2] = "tools", [3] = "setting", [4] = "filemanager", [5] = "search", [6] = "navi", [7] = "typeset", }, } },
    { op = "create_submenu", args = { ["parent"] = "navi", ["title"] = "Tools", } },
  },
}
-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 514735,
  signature = "I6|pageturn_power",
  history = {
    { op = "reorder_tabs", args = { ["tabs"] = { [1] = "setting", [2] = "main", [3] = "search", [4] = "typeset", [5] = "filemanager", [6] = "tools", }, } },
    { op = "sort_menu_az", args = { ["menu"] = "filemanager", ["seq"] = { [1] = "pageturn_power", [2] = "xitem1", }, } },
  },
}
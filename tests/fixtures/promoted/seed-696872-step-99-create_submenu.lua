-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 696872,
  signature = "I7|untouched stock back_to_exit",
  history = {
    { op = "move_item_to_menu", args = { ["dest"] = "setting", ["from"] = "navigation", ["id"] = "back_to_exit", } },
    { op = "reorder_tabs", args = { ["tabs"] = { [1] = "main", [2] = "tools", [3] = "filemanager", [4] = "ntab1", [5] = "typeset", [6] = "setting", [7] = "search", [8] = "navi", }, } },
    { op = "upstream_reorder", args = { ["i"] = 7, ["menu"] = "device", ["view"] = "reader", } },
  },
}
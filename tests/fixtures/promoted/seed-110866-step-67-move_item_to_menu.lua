-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 110866,
  signature = "I6|profiles",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "setting", ["seq"] = { [1] = "taps_and_gestures", [2] = "screen", [3] = "navigation", [4] = "language", [5] = "night_mode", [6] = "network", [7] = "device", [8] = "frontlight", [9] = "document", }, } },
    { op = "reorder_tabs", args = { ["tabs"] = { [1] = "tools", [2] = "main", [3] = "ntab3", [4] = "setting", [5] = "plus_menu", [6] = "search", }, } },
    { op = "save_order", args = {} },
    { op = "upstream_remove_tab", args = { ["id"] = "setting", ["view"] = "filemanager", } },
    { op = "move_item_to_menu", args = { ["dest"] = "setting", ["from"] = "tools", ["id"] = "profiles", } },
  },
}
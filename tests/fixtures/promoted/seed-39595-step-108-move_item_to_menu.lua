-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 39595,
  signature = "I6|cloud_storage",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "setting", ["seq"] = { [1] = "network", [2] = "taps_and_gestures", [3] = "screen", [4] = "night_mode", [5] = "device", [6] = "navigation", [7] = "language", }, } },
    { op = "reorder_tabs", args = { ["tabs"] = { [1] = "main", [2] = "setting", [3] = "plus_menu", [4] = "search", [5] = "tools", }, } },
    { op = "save_order", args = {} },
    { op = "upstream_remove_tab", args = { ["id"] = "setting", ["view"] = "filemanager", } },
    { op = "move_item_to_menu", args = { ["dest"] = "setting", ["from"] = "tools", ["id"] = "cloud_storage", } },
  },
}
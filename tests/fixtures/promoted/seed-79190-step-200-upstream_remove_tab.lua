-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 79190,
  signature = "I6|file_search",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "setting", ["seq"] = { [1] = "network", [2] = "screen", [3] = "taps_and_gestures", [4] = "device", [5] = "night_mode", [6] = "language", [7] = "document", [8] = "frontlight", [9] = "navigation", }, } },
    { op = "move_item_to_menu", args = { ["dest"] = "setting", ["from"] = "search", ["id"] = "file_search", } },
    { op = "save_order", args = {} },
    { op = "external_native_edit", args = { ["menu"] = "search_settings", ["view"] = "filemanager", } },
    { op = "upstream_remove_tab", args = { ["id"] = "setting", ["view"] = "filemanager", } },
  },
}
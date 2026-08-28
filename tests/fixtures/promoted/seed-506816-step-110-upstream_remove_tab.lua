-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 506816,
  signature = "I6|dictionary_lookup",
  history = {
    { op = "sort_menu_az", args = { ["menu"] = "setting", ["seq"] = { [1] = "device", [2] = "document", [3] = "frontlight", [4] = "language", [5] = "navigation", [6] = "network", [7] = "night_mode", [8] = "screen", [9] = "taps_and_gestures", }, } },
    { op = "save_order", args = {} },
    { op = "move_item_to_menu", args = { ["dest"] = "setting", ["from"] = "search", ["id"] = "dictionary_lookup", } },
    { op = "external_native_edit", args = { ["menu"] = "device", ["view"] = "filemanager", } },
    { op = "upstream_remove_tab", args = { ["id"] = "setting", ["view"] = "filemanager", } },
  },
}
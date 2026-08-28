-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 150461,
  signature = "I6|exit_menu",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "setting", ["seq"] = { [1] = "exit_menu", [2] = "navigation", [3] = "screen", [4] = "device", [5] = "status_bar", [6] = "document", [7] = "language", [8] = "night_mode", [9] = "network", }, } },
    { op = "restart", args = {} },
    { op = "external_native_edit", args = { ["menu"] = "search_settings", ["view"] = "filemanager", } },
    { op = "upstream_remove_tab", args = { ["id"] = "setting", ["view"] = "filemanager", } },
  },
}
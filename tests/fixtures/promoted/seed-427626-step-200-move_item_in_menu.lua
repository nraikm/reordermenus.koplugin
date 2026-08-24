-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 427626,
  signature = "I7|order",
  history = {
    { op = "sort_menu_az", args = { ["menu"] = "filemanager_settings", ["seq"] = { [1] = "filemanager_display_mode", [2] = "reverse_sorting", [3] = "show_filter", [4] = "sort_by", [5] = "sort_mixed", [6] = "start_with", }, } },
    { op = "move_item_in_menu", args = { ["from"] = 1, ["menu"] = "filemanager_settings", ["to"] = 1, } },
  },
}
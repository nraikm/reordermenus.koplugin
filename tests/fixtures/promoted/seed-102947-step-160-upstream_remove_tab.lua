-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 102947,
  signature = "I6|cloud_storage",
  history = {
    { op = "sort_menu_za", args = { ["menu"] = "filemanager_settings", ["seq"] = { [1] = "start_with", [2] = "sort_mixed", [3] = "sort_by", [4] = "show_filter", [5] = "reverse_sorting", [6] = "filemanager_display_mode", [7] = "filebrowser_settings", }, } },
    { op = "reorder_tabs", args = { ["tabs"] = { [1] = "search", [2] = "plus_menu", [3] = "tools", [4] = "setting", [5] = "filemanager_settings", }, } },
    { op = "move_item_to_menu", args = { ["dest"] = "filemanager_settings", ["from"] = "tools", ["id"] = "cloud_storage", } },
    { op = "save_order", args = {} },
    { op = "upstream_remove_tab", args = { ["id"] = "filemanager_settings", ["view"] = "filemanager", } },
  },
}
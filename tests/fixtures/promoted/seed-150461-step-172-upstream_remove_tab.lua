-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 150461,
  signature = "I6|language&&I6|opening_page_location_stack",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "filemanager_settings", ["seq"] = { [1] = "sort_mixed", [2] = "ext_unknown_item", [3] = "sort_by", [4] = "nitem1", [5] = "opening_page_location_stack", [6] = "reverse_sorting", [7] = "language", [8] = "filemanager_display_mode", [9] = "show_filter", [10] = "start_with", [11] = "filebrowser_settings", }, } },
    { op = "save_order", args = {} },
    { op = "external_native_edit", args = { ["menu"] = "exit_menu", ["view"] = "filemanager", } },
    { op = "upstream_remove_tab", args = { ["id"] = "filemanager_settings", ["view"] = "filemanager", } },
  },
}
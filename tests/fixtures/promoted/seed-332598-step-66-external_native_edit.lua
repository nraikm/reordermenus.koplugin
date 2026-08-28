-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 332598,
  signature = "I16|disabled mismatch",
  history = {
    { op = "upstream_add", args = { ["id"] = "nitem1", ["menu"] = "filemanager_settings", ["view"] = "filemanager", } },
    { op = "stage_list_permutation", args = { ["menu"] = "filemanager_settings", ["seq"] = { [1] = "show_filter", [2] = "sort_by", [3] = "filebrowser_settings", [4] = "nitem1", [5] = "sort_mixed", [6] = "start_with", [7] = "reverse_sorting", [8] = "filemanager_display_mode", }, } },
    { op = "save_order", args = {} },
    { op = "upstream_remove_tab", args = { ["id"] = "filemanager_settings", ["view"] = "filemanager", } },
    { op = "external_native_edit", args = { ["menu"] = "network", ["view"] = "filemanager", } },
  },
}
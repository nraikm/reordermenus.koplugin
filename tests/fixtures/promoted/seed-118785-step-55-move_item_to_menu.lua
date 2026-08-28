-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 118785,
  signature = "I16|disabled mismatch",
  history = {
    { op = "sort_menu_az", args = { ["menu"] = "filemanager_settings", ["seq"] = { [1] = "filebrowser_settings", [2] = "filemanager_display_mode", [3] = "reverse_sorting", [4] = "show_filter", [5] = "sort_by", [6] = "sort_mixed", [7] = "start_with", }, } },
    { op = "save_order", args = {} },
    { op = "external_native_edit", args = { ["menu"] = "taps_and_gestures", ["view"] = "filemanager", } },
    { op = "copy_layout", args = {} },
    { op = "save_order", args = {} },
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "create_submenu", args = { ["parent"] = "filemanager_settings", ["title"] = "Tools", } },
  },
}
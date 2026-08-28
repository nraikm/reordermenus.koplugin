-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 87109,
  signature = "I16|disabled mismatch",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "upstream_add", args = { ["id"] = "nitem2", ["menu"] = "document", ["view"] = "reader", } },
    { op = "sort_menu_az", args = { ["menu"] = "document", ["seq"] = { [1] = "document_auto_save", [2] = "document_end_action", [3] = "document_metadata_location", [4] = "language_support", [5] = "nitem2", [6] = "partial_rerendering", }, } },
    { op = "copy_layout", args = {} },
    { op = "restart", args = {} },
    { op = "reader_fm_switch", args = { ["view"] = "filemanager", } },
    { op = "upstream_remove_tab", args = { ["id"] = "setting", ["view"] = "filemanager", } },
    { op = "external_native_edit", args = { ["menu"] = "help", ["view"] = "filemanager", } },
  },
}
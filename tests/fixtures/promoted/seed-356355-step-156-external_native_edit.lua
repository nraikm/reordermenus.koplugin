-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 356355,
  signature = "I16|disabled mismatch",
  history = {
    { op = "upstream_add_tab", args = { ["id"] = "ntab1", ["view"] = "filemanager", } },
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "move_item_to_menu", args = { ["dest"] = "setting", ["from"] = "navi_settings", ["id"] = "handmade_hidden_flows", } },
    { op = "save_order", args = {} },
    { op = "copy_layout", args = {} },
    { op = "delete_native_file", args = { ["view"] = "reader", } },
    { op = "reader_fm_switch", args = { ["view"] = "filemanager", } },
    { op = "upstream_remove_tab", args = { ["id"] = "setting", ["view"] = "filemanager", } },
    { op = "external_native_edit", args = { ["menu"] = "ntab1", ["view"] = "filemanager", } },
  },
}
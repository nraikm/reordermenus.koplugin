-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 332598,
  signature = "I16|disabled mismatch",
  history = {
    { op = "create_submenu", args = { ["parent"] = "document", ["title"] = "中文菜单", } },
    { op = "external_native_edit", args = { ["menu"] = "exit_menu", ["view"] = "filemanager", } },
    { op = "upstream_remove_tab", args = { ["id"] = "setting", ["view"] = "filemanager", } },
    { op = "external_native_edit", args = { ["menu"] = "help", ["view"] = "filemanager", } },
  },
}
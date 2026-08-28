-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 609763,
  signature = "I16|disabled mismatch",
  history = {
    { op = "external_native_edit", args = { ["menu"] = "document", ["view"] = "filemanager", } },
    { op = "upstream_remove_tab", args = { ["id"] = "setting", ["view"] = "filemanager", } },
    { op = "external_native_edit", args = { ["menu"] = "more_tools", ["view"] = "filemanager", } },
  },
}
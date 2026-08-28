-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 356355,
  signature = "I16|disabled mismatch",
  history = {
    { op = "upstream_add_tab", args = { ["id"] = "ntab1", ["view"] = "filemanager", } },
    { op = "external_native_edit", args = { ["menu"] = "help", ["view"] = "filemanager", } },
    { op = "external_native_edit", args = { ["menu"] = "ntab1", ["view"] = "filemanager", } },
    { op = "upstream_remove_tab", args = { ["id"] = "ntab1", ["view"] = "filemanager", } },
    { op = "external_native_edit", args = { ["menu"] = "main", ["view"] = "filemanager", } },
  },
}
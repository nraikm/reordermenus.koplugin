-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 332598,
  signature = "I16|disabled mismatch",
  history = {
    { op = "hide_item", args = { ["id"] = "start_content_selection", ["parent"] = "typeset", } },
    { op = "unhide_item", args = { ["id"] = "start_content_selection", } },
    { op = "external_native_edit", args = { ["menu"] = "typeset", ["view"] = "reader", } },
    { op = "plugin_install", args = { ["hint"] = "search", ["id"] = "xitem9", ["name"] = "p9", ["view"] = "reader", } },
    { op = "external_native_edit", args = { ["menu"] = "document", ["view"] = "filemanager", } },
  },
}
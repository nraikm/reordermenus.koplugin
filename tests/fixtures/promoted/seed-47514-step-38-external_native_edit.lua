-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 47514,
  signature = "I16|disabled mismatch",
  history = {
    { op = "external_native_edit", args = { ["menu"] = "screen", ["view"] = "filemanager", } },
    { op = "upstream_remove", args = { ["id"] = "find_book_in_calibre_catalog", ["menu"] = "search", ["view"] = "filemanager", } },
    { op = "hide_tab", args = { ["id"] = "search", } },
    { op = "external_native_edit", args = { ["menu"] = "more_tools", ["view"] = "filemanager", } },
  },
}
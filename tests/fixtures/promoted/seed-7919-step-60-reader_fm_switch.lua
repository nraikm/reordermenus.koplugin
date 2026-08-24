-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 7919,
  signature = "I16|disabled mismatch&&I7|untouched stock bookmarks_settings",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "hide_item", args = { ["id"] = "bookmarks_settings", ["parent"] = "navi_settings", } },
    { op = "external_native_edit", args = { ["menu"] = "search_settings", ["view"] = "filemanager", } },
  },
}
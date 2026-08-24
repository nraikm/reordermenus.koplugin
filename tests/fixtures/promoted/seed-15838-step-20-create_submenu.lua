-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 15838,
  signature = "I7|order",
  history = {
    { op = "hide_item", args = { ["id"] = "history", ["parent"] = "main", } },
    { op = "restart", args = {} },
    { op = "external_native_edit", args = { ["menu"] = "filemanager_settings", ["view"] = "filemanager", } },
    { op = "upstream_reorder", args = { ["i"] = 17, ["menu"] = "device", ["view"] = "filemanager", } },
    { op = "create_submenu", args = { ["parent"] = "more_tools", ["title"] = "Notes", } },
  },
}
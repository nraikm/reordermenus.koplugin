-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 55433,
  signature = "I7|untouched stock ota_update",
  history = {
    { op = "toggle_mirroring", args = { ["enabled"] = true, } },
    { op = "hide_item", args = { ["id"] = "ota_update", ["parent"] = "main", } },
    { op = "unhide_item", args = { ["id"] = "filebrowser_settings", } },
    { op = "upstream_remove_tab", args = { ["id"] = "search", ["view"] = "filemanager", } },
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
  },
}
-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 15838,
  signature = "I7|untouched stock network",
  history = {
    { op = "toggle_mirroring", args = { ["enabled"] = true, } },
    { op = "hide_item", args = { ["id"] = "network", ["parent"] = "setting", } },
    { op = "hide_tab", args = { ["id"] = "filemanager_settings", } },
    { op = "upstream_add_tab", args = { ["id"] = "ntab1", ["view"] = "filemanager", } },
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
  },
}
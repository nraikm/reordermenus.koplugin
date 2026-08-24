-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 31676,
  signature = "I16|disabled mismatch",
  history = {
    { op = "hide_item", args = { ["id"] = "filemanager_display_mode", ["parent"] = "filemanager_settings", } },
    { op = "copy_layout", args = {} },
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "unhide_item", args = { ["id"] = "filemanager_display_mode", } },
  },
}
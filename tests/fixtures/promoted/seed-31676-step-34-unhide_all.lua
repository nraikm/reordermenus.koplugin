-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 31676,
  signature = "I16|disabled mismatch",
  history = {
    { op = "hide_item", args = { ["id"] = "filemanager_display_mode", ["parent"] = "filemanager_settings", } },
    { op = "save_order", args = {} },
    { op = "upstream_remove_tab", args = { ["id"] = "filemanager_settings", ["view"] = "filemanager", } },
    { op = "unhide_all", args = { ["ids"] = { [1] = "filemanager_display_mode", [2] = "taps_and_gestures", [3] = "gesture_intervals", [4] = "gesture_manager", [5] = "gesture_overview", [6] = "ignore_hold_corners", [7] = "menu_activate", [8] = "screen_disable_double_tap", }, } },
  },
}
-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 364274,
  signature = "I7|order",
  history = {
    { op = "save_preset", args = { ["name"] = "sm364274_2", ["view"] = "filemanager", } },
    { op = "apply_preset", args = { ["name"] = "sm364274_2", } },
    { op = "sort_menu_za", args = { ["menu"] = "taps_and_gestures", ["seq"] = { [1] = "screen_disable_double_tap", [2] = "menu_activate", [3] = "ignore_hold_corners", [4] = "gesture_overview", [5] = "gesture_manager", [6] = "gesture_intervals", }, } },
    { op = "apply_preset", args = { ["name"] = "sm364274_2", } },
  },
}
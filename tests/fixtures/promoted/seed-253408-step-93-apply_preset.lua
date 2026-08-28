-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 253408,
  signature = "I7|order",
  history = {
    { op = "save_preset", args = { ["name"] = "sm253408_4", ["view"] = "filemanager", } },
    { op = "apply_preset", args = { ["name"] = "sm253408_4", } },
    { op = "sort_menu_za", args = { ["menu"] = "taps_and_gestures", ["seq"] = { [1] = "menu_activate", [2] = "ignore_hold_corners", [3] = "gesture_overview", [4] = "gesture_manager", [5] = "gesture_intervals", }, } },
    { op = "apply_preset", args = { ["name"] = "sm253408_4", } },
  },
}
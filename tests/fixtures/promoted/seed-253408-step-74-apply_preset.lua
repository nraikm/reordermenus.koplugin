-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 253408,
  signature = "I7|order",
  history = {
    { op = "save_preset", args = { ["name"] = "sm253408_3", ["view"] = "filemanager", } },
    { op = "apply_preset", args = { ["name"] = "sm253408_3", } },
    { op = "stage_list_permutation", args = { ["menu"] = "screen", ["seq"] = { [1] = "screen_rotation", [2] = "autowarmth", [3] = "autodim", [4] = "screen_notification", [5] = "color_rendering", [6] = "screen_timeout", [7] = "screen_dpi", [8] = "fullscreen", [9] = "screen_eink_opt", [10] = "screensaver", }, } },
    { op = "apply_preset", args = { ["name"] = "sm253408_3", } },
  },
}
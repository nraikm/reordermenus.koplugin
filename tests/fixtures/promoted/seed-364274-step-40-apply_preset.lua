-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 364274,
  signature = "I7|order",
  history = {
    { op = "save_order", args = {} },
    { op = "save_preset", args = { ["name"] = "sm364274_1", ["view"] = "filemanager", } },
    { op = "stage_list_permutation", args = { ["menu"] = "screen", ["seq"] = { [1] = "autodim", [2] = "color_rendering", [3] = "screen_eink_opt", [4] = "autowarmth", [5] = "screen_timeout", [6] = "screen_notification", [7] = "fullscreen", [8] = "screensaver", [9] = "screen_rotation", }, } },
    { op = "apply_preset", args = { ["name"] = "sm364274_1", } },
  },
}
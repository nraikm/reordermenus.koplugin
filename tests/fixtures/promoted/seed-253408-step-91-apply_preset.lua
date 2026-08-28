-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 253408,
  signature = "I7|order",
  history = {
    { op = "save_preset", args = { ["name"] = "sm253408_4", ["view"] = "filemanager", } },
    { op = "apply_preset", args = { ["name"] = "sm253408_4", } },
    { op = "sort_menu_za", args = { ["menu"] = "screen", ["seq"] = { [1] = "screen_timeout", [2] = "screen_rotation", [3] = "screen_notification", [4] = "screen_eink_opt", [5] = "screen_dpi", [6] = "fullscreen", [7] = "color_rendering", [8] = "autowarmth", }, } },
    { op = "apply_preset", args = { ["name"] = "sm253408_4", } },
  },
}
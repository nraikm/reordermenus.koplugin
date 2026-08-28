-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 55433,
  signature = "I7|order",
  history = {
    { op = "save_preset", args = { ["name"] = "sm55433_1", ["view"] = "filemanager", } },
    { op = "apply_preset", args = { ["name"] = "sm55433_1", } },
    { op = "stage_list_permutation", args = { ["menu"] = "help", ["seq"] = { [1] = "search_menu", [2] = "system_statistics", [3] = "report_bug", [4] = "about", [5] = "quickstart_guide", [6] = "version", }, } },
    { op = "apply_preset", args = { ["name"] = "sm55433_1", } },
  },
}
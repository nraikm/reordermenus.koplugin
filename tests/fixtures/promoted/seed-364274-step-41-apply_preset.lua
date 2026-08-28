-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 364274,
  signature = "I7|order",
  history = {
    { op = "save_order", args = {} },
    { op = "save_preset", args = { ["name"] = "sm364274_1", ["view"] = "filemanager", } },
    { op = "stage_list_permutation", args = { ["menu"] = "exit_menu", ["seq"] = { [1] = "sleep", [2] = "reboot", [3] = "start_bq", [4] = "restart_koreader", [5] = "exit", [6] = "poweroff", }, } },
    { op = "apply_preset", args = { ["name"] = "sm364274_1", } },
  },
}
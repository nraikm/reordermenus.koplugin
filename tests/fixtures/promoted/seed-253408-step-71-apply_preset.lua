-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 253408,
  signature = "I7|order",
  history = {
    { op = "save_preset", args = { ["name"] = "sm253408_3", ["view"] = "filemanager", } },
    { op = "restart", args = {} },
    { op = "stage_list_permutation", args = { ["menu"] = "network", ["seq"] = { [1] = "network_powersave", [2] = "network_restore", [3] = "ssh", [4] = "network_before_wifi_action", [5] = "network_after_wifi_action", [6] = "network_dismiss_scan", [7] = "network_info", [8] = "network_wifi", [9] = "network_proxy", }, } },
    { op = "apply_preset", args = { ["name"] = "sm253408_3", } },
  },
}
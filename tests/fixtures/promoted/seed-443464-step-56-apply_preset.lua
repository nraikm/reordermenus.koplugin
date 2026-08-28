-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 443464,
  signature = "I7|order",
  history = {
    { op = "restart", args = {} },
    { op = "save_preset", args = { ["name"] = "sm443464_1", ["view"] = "filemanager", } },
    { op = "stage_list_permutation", args = { ["menu"] = "network", ["seq"] = { [1] = "network_proxy", [2] = "network_restore", [3] = "network_before_wifi_action", [4] = "network_dismiss_scan", [5] = "ssh", [6] = "network_info", [7] = "network_powersave", [8] = "network_wifi", [9] = "network_after_wifi_action", }, } },
    { op = "apply_preset", args = { ["name"] = "sm443464_1", } },
  },
}
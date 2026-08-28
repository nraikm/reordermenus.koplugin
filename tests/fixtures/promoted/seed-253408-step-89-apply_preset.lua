-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 253408,
  signature = "I7|order",
  history = {
    { op = "save_preset", args = { ["name"] = "sm253408_4", ["view"] = "filemanager", } },
    { op = "apply_preset", args = { ["name"] = "sm253408_4", } },
    { op = "sort_menu_za", args = { ["menu"] = "network", ["seq"] = { [1] = "ssh", [2] = "network_wifi", [3] = "network_restore", [4] = "network_proxy", [5] = "network_powersave", [6] = "network_info", [7] = "network_dismiss_scan", [8] = "network_before_wifi_action", [9] = "network_after_wifi_action", }, } },
    { op = "apply_preset", args = { ["name"] = "sm253408_4", } },
  },
}
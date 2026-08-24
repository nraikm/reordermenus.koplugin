-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 15838,
  signature = "I7|order",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "network", ["seq"] = { [1] = "network_proxy", [2] = "network_after_wifi_action", [3] = "network_before_wifi_action", [4] = "network_info", [5] = "network_dismiss_scan", [6] = "network_powersave", [7] = "network_restore", [8] = "ssh", [9] = "network_wifi", }, } },
    { op = "unhide_item", args = { ["id"] = "dictionary_lookup_history", } },
    { op = "reset_view", args = {} },
  },
}
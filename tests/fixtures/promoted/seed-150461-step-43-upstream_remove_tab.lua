-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 150461,
  signature = "I7|order",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "help", ["seq"] = { [1] = "report_bug", [2] = "version", [3] = "search_menu", [4] = "about", [5] = "system_statistics", [6] = "quickstart_guide", }, } },
    { op = "upstream_reorder", args = { ["i"] = 5, ["menu"] = "tools", ["view"] = "reader", } },
  },
}
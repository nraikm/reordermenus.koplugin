-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 55433,
  signature = "I7|order",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "help", ["seq"] = { [1] = "about", [2] = "system_statistics", [3] = "search_menu", [4] = "quickstart_guide", [5] = "report_bug", [6] = "version", }, } },
    { op = "upstream_remove_tab", args = { ["id"] = "setting", ["view"] = "reader", } },
  },
}
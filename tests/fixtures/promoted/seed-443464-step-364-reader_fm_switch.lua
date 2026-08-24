-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 443464,
  signature = "I7|order",
  history = {
    { op = "sort_menu_az", args = { ["menu"] = "help", ["seq"] = { [1] = "about", [2] = "nitem9", [3] = "quickstart_guide", [4] = "report_bug", [5] = "search_menu", [6] = "system_statistics", [7] = "version", }, } },
    { op = "upstream_reorder", args = { ["i"] = 1, ["menu"] = "navi", ["view"] = "reader", } },
  },
}
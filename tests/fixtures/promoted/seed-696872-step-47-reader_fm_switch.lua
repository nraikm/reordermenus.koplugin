-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 696872,
  signature = "I13|rendered id reorderingmenus",
  history = {
    { op = "create_submenu", args = { ["parent"] = "taps_and_gestures", ["title"] = "中文菜单", } },
    { op = "upstream_remove", args = { ["id"] = "quickstart_guide", ["menu"] = "help", ["view"] = "reader", } },
  },
}
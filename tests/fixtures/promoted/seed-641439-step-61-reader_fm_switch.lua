-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 641439,
  signature = "I13|rendered id reorderingmenus",
  history = {
    { op = "create_submenu", args = { ["parent"] = "taps_and_gestures", ["title"] = "Tools", } },
    { op = "upstream_reorder", args = { ["i"] = 9, ["menu"] = "navi_settings", ["view"] = "reader", } },
  },
}
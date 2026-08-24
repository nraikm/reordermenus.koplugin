-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 87109,
  signature = "I13|rendered id reorderingmenus",
  history = {
    { op = "create_submenu", args = { ["parent"] = "exit_menu", ["title"] = "Notes", } },
    { op = "upstream_remove_tab", args = { ["id"] = "setting", ["view"] = "reader", } },
  },
}
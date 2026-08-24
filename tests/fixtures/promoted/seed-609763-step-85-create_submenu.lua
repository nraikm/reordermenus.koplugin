-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 609763,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 1, ["menu"] = "tools", ["to"] = 9, } },
    { op = "create_submenu", args = { ["parent"] = "search_settings", ["title"] = "Tools", } },
  },
}
-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 221732,
  signature = "I16|disabled mismatch",
  history = {
    { op = "move_item_to_menu", args = { ["dest"] = "plus_menu", ["from"] = "help", ["id"] = "system_statistics", } },
    { op = "hide_tab", args = { ["id"] = "plus_menu", } },
  },
}
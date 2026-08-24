-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 364274,
  signature = "I16|disabled mismatch",
  history = {
    { op = "move_item_to_menu", args = { ["dest"] = "plus_menu", ["from"] = "device", ["id"] = "units", } },
    { op = "hide_tab", args = { ["id"] = "plus_menu", } },
  },
}
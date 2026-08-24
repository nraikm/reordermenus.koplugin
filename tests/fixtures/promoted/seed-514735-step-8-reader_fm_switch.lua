-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 514735,
  signature = "I7|untouched stock restart_koreader",
  history = {
    { op = "move_item_to_menu", args = { ["dest"] = "setting", ["from"] = "exit_menu", ["id"] = "restart_koreader", } },
    { op = "upstream_add", args = { ["id"] = "nitem1", ["menu"] = "document", ["view"] = "reader", } },
  },
}
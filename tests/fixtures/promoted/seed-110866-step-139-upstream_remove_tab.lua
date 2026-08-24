-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 110866,
  signature = "I7|order&&I7|untouched stock synchronize_time",
  history = {
    { op = "sort_menu_az", args = { ["menu"] = "exit_menu", ["seq"] = { [1] = "exit", [2] = "poweroff", [3] = "reboot", [4] = "restart_koreader", [5] = "sleep", [6] = "start_bq", [7] = "synchronize_time", }, } },
    { op = "conditional_capability", args = { ["id"] = "frontlight", ["menu"] = "setting", ["view"] = "reader", } },
  },
}
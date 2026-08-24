-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 768143,
  signature = "I7|order",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "device", ["seq"] = { [1] = "font_ui_fallbacks", [2] = "ignore_battery_optimizations", [3] = "pageturn_power", [4] = "autostandby", [5] = "device_status_alarm", [6] = "charging_led", [7] = "autosuspend", [8] = "cover_events", [9] = "autoshutdown", [10] = "ignore_sleepcover", [11] = "external_keyboard", [12] = "screenshot", [13] = "file_ext_assoc", [14] = "mass_storage_settings", [15] = "time", [16] = "keyboard_layout", [17] = "ignore_open_sleepcover", [18] = "units", }, } },
    { op = "upstream_reorder", args = { ["i"] = 8, ["menu"] = "more_tools", ["view"] = "reader", } },
  },
}
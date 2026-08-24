-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 134623,
  signature = "I7|order",
  history = {
    { op = "sort_menu_az", args = { ["menu"] = "device", ["seq"] = { [1] = "autoshutdown", [2] = "autostandby", [3] = "autosuspend", [4] = "charging_led", [5] = "cover_events", [6] = "device_status_alarm", [7] = "external_keyboard", [8] = "file_ext_assoc", [9] = "font_ui_fallbacks", [10] = "ignore_battery_optimizations", [11] = "ignore_open_sleepcover", [12] = "ignore_sleepcover", [13] = "mass_storage_settings", [14] = "pageturn_power", [15] = "screenshot", [16] = "time", [17] = "units", }, } },
    { op = "upstream_reorder", args = { ["i"] = 1, ["menu"] = "navigation", ["view"] = "reader", } },
  },
}
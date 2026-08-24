-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 7919,
  signature = "I7|order",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "device", ["seq"] = { [1] = "external_keyboard", [2] = "autoshutdown", [3] = "time", [4] = "device_status_alarm", [5] = "units", [6] = "file_ext_assoc", [7] = "cover_events", [8] = "ignore_sleepcover", [9] = "ignore_open_sleepcover", [10] = "font_ui_fallbacks", [11] = "autosuspend", [12] = "mass_storage_settings", [13] = "screenshot", [14] = "charging_led", [15] = "pageturn_power", [16] = "keyboard_layout", [17] = "autostandby", [18] = "ignore_battery_optimizations", }, } },
    { op = "upstream_reorder", args = { ["i"] = 7, ["menu"] = "main", ["view"] = "reader", } },
  },
}
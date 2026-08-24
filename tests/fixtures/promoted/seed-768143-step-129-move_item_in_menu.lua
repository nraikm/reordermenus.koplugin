-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 768143,
  signature = "I7|order",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "device", ["seq"] = { [1] = "file_ext_assoc", [2] = "font_ui_fallbacks", [3] = "ignore_open_sleepcover", [4] = "screenshot", [5] = "autostandby", [6] = "autoshutdown", [7] = "time", [8] = "ignore_sleepcover", [9] = "device_status_alarm", [10] = "units", [11] = "pageturn_power", [12] = "cover_events", [13] = "ignore_battery_optimizations", [14] = "mass_storage_settings", [15] = "charging_led", [16] = "keyboard_layout", [17] = "external_keyboard", [18] = "autosuspend", }, } },
    { op = "upstream_reorder", args = { ["i"] = 1, ["menu"] = "setting", ["view"] = "reader", } },
  },
}
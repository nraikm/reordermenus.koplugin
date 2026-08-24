-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 356355,
  signature = "I7|order",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "device", ["seq"] = { [1] = "device_status_alarm", [2] = "units", [3] = "cover_events", [4] = "ignore_open_sleepcover", [5] = "font_ui_fallbacks", [6] = "autosuspend", [7] = "mass_storage_settings", [8] = "nitem8", [9] = "charging_led", [10] = "ignore_battery_optimizations", [11] = "file_ext_assoc", [12] = "autoshutdown", [13] = "screenshot", [14] = "time", [15] = "autostandby", [16] = "external_keyboard", }, } },
    { op = "upstream_add", args = { ["id"] = "nitem18", ["menu"] = "screen", ["view"] = "reader", } },
  },
}
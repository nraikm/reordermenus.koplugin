-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 118785,
  signature = "I15|order_override of setting",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "external_native_edit", args = { ["menu"] = "help", ["view"] = "reader", } },
    { op = "external_native_edit", args = { ["menu"] = "screen", ["view"] = "reader", } },
    { op = "external_native_edit", args = { ["menu"] = "document", ["view"] = "reader", } },
    { op = "upstream_remove_tab", args = { ["id"] = "setting", ["view"] = "reader", } },
    { op = "sort_menu_za", args = { ["menu"] = "setting", ["seq"] = { [1] = "taps_and_gestures", [2] = "status_bar", [3] = "screen", [4] = "night_mode", [5] = "network", [6] = "navigation", [7] = "language", [8] = "document", [9] = "device", }, } },
  },
}
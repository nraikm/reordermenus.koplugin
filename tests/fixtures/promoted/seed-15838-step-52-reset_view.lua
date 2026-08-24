-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 15838,
  signature = "I7|order",
  history = {
    { op = "sort_menu_az", args = { ["menu"] = "setting", ["seq"] = { [1] = "device", [2] = "document", [3] = "frontlight", [4] = "language", [5] = "navigation", [6] = "network", [7] = "night_mode", [8] = "screen", [9] = "taps_and_gestures", }, } },
    { op = "unhide_item", args = { ["id"] = "exporter", } },
    { op = "reset_view", args = {} },
  },
}
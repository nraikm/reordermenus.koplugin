-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 7919,
  signature = "I7|order",
  history = {
    { op = "sort_menu_za", args = { ["menu"] = "main", ["seq"] = { [1] = "ota_update", [2] = "open_previous_document", [3] = "mass_storage_actions", [4] = "history", [5] = "help", [6] = "favorites", [7] = "exit_menu", [8] = "collections", [9] = "book_status", [10] = "book_info", }, } },
    { op = "upstream_reorder", args = { ["i"] = 9, ["menu"] = "taps_and_gestures", ["view"] = "reader", } },
  },
}
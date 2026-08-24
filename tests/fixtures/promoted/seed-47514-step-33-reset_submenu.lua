-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 47514,
  signature = "I7|order",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "main", ["seq"] = { [1] = "favorites", [2] = "collections", [3] = "exit_menu", [4] = "book_status", [5] = "book_info", [6] = "ota_update", [7] = "open_previous_document", [8] = "history", [9] = "mass_storage_actions", [10] = "help", }, } },
    { op = "upstream_reorder", args = { ["i"] = 5, ["menu"] = "exit_menu", ["view"] = "reader", } },
  },
}
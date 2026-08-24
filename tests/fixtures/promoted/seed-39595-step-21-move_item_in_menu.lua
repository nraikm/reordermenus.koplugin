-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 39595,
  signature = "I7|order",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "sort_menu_az", args = { ["menu"] = "document", ["seq"] = { [1] = "document_auto_save", [2] = "document_end_action", [3] = "document_metadata_location", [4] = "language_support", [5] = "partial_rerendering", }, } },
    { op = "move_item_in_menu", args = { ["from"] = 13, ["menu"] = "navigation", ["to"] = 13, } },
  },
}
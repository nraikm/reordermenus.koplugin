-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 375757,
  signature = "I7|order",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "document", ["seq"] = { [1] = "document_end_action", [2] = "document_auto_save", [3] = "language_support", [4] = "document_metadata_location", [5] = "document_metadata_location_move", }, } },
    { op = "stage_list_permutation", args = { ["menu"] = "document", ["seq"] = { [1] = "document_metadata_location_move", [2] = "document_metadata_location", [3] = "document_auto_save", [4] = "document_end_action", [5] = "language_support", }, } },
  },
}
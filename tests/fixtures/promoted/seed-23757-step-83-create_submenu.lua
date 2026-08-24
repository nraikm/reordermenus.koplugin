-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 23757,
  signature = "I7|order",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "document", ["seq"] = { [1] = "document_metadata_location_move", [2] = "document_auto_save", [3] = "document_end_action", [4] = "language_support", [5] = "document_metadata_location", }, } },
    { op = "create_submenu", args = { ["parent"] = "filemanager_settings", ["title"] = "Tools", } },
  },
}
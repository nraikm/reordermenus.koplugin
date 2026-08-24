-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 102947,
  signature = "I16|disabled mismatch",
  history = {
    { op = "hide_item", args = { ["id"] = "open_previous_document", ["parent"] = "main", } },
    { op = "upstream_remove", args = { ["id"] = "document_metadata_location", ["menu"] = "document", ["view"] = "reader", } },
  },
}
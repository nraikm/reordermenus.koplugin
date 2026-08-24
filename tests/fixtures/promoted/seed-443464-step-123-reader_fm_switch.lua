-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 443464,
  signature = "I16|disabled mismatch",
  history = {
    { op = "hide_item", args = { ["id"] = "toc_items_per_page", ["parent"] = "navi_settings", } },
    { op = "upstream_remove", args = { ["id"] = "document_auto_save", ["menu"] = "document", ["view"] = "reader", } },
  },
}
-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 609763,
  signature = "I7|untouched stock dictionary_lookup_history",
  history = {
    { op = "move_item_to_menu", args = { ["dest"] = "document", ["from"] = "search", ["id"] = "dictionary_lookup_history", } },
    { op = "upstream_add", args = { ["id"] = "nitem2", ["menu"] = "taps_and_gestures", ["view"] = "reader", } },
  },
}
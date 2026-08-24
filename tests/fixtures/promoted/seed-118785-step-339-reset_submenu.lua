-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 118785,
  signature = "I16|disabled mismatch&&I7|untouched stock font_ui_fallbacks",
  history = {
    { op = "hide_item", args = { ["id"] = "font_ui_fallbacks", ["parent"] = "device", } },
    { op = "external_native_edit", args = { ["menu"] = "document", ["view"] = "reader", } },
  },
}
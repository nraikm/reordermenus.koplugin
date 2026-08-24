-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 47514,
  signature = "I16|disabled mismatch",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "create_submenu", args = { ["parent"] = "navi_settings", ["title"] = "Notes", } },
    { op = "external_native_edit", args = { ["menu"] = "filemanager", ["view"] = "reader", } },
    { op = "hide_tab", args = { ["id"] = "navi", } },
    { op = "external_native_edit", args = { ["menu"] = "taps_and_gestures", ["view"] = "reader", } },
  },
}
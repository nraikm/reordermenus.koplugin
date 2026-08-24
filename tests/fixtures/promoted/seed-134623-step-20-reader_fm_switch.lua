-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 134623,
  signature = "I16|disabled mismatch",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "create_submenu", args = { ["parent"] = "navi", ["title"] = "Notes", } },
    { op = "copy_layout", args = {} },
    { op = "reader_fm_switch", args = { ["view"] = "filemanager", } },
  },
}
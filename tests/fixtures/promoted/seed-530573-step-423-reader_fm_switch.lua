-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 530573,
  signature = "I16|disabled mismatch&&I7|untouched stock poweroff",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "hide_item", args = { ["id"] = "poweroff", ["parent"] = "exit_menu", } },
    { op = "upstream_add", args = { ["id"] = "nitem11", ["menu"] = "tools", ["view"] = "filemanager", } },
  },
}
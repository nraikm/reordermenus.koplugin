-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 427626,
  signature = "I16|disabled mismatch",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "move_item_to_menu", args = { ["dest"] = "filemanager", ["from"] = "tools", ["id"] = "move_to_archive", } },
    { op = "hide_tab", args = { ["id"] = "filemanager", } },
  },
}
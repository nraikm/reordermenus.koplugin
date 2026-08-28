-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 744386,
  signature = "I6|help",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "move_item_to_menu", args = { ["dest"] = "navi", ["from"] = "main", ["id"] = "help", } },
    { op = "external_native_edit", args = { ["menu"] = "filemanager", ["view"] = "reader", } },
    { op = "external_native_edit", args = { ["menu"] = "navi_settings", ["view"] = "reader", } },
    { op = "upstream_remove_tab", args = { ["id"] = "navi", ["view"] = "reader", } },
  },
}
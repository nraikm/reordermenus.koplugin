-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 126704,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 5, ["menu"] = "setting", ["to"] = 9, } },
    { op = "upstream_remove_tab", args = { ["id"] = "filemanager", ["view"] = "reader", } },
  },
}
-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 388031,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 11, ["menu"] = "tools", ["to"] = 9, } },
    { op = "upstream_add", args = { ["id"] = "nitem2", ["menu"] = "filemanager", ["view"] = "reader", } },
  },
}
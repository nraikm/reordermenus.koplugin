-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 15838,
  signature = "I7|order",
  history = {
    { op = "move_item_in_menu", args = { ["from"] = 2, ["menu"] = "filemanager_settings", ["to"] = 4, } },
    { op = "unhide_item", args = { ["id"] = "color_rendering", } },
    { op = "reset_view", args = {} },
  },
}
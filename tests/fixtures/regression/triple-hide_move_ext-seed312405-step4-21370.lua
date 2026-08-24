-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 312405,
  signature = "I7|order",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "move_item_in_menu", args = { ["from"] = 12, ["menu"] = "search", ["to"] = 1, } },
    { op = "hide_item", args = { ["id"] = "translate_current_page", ["parent"] = "search", } },
    { op = "unhide_item", args = { ["id"] = "translate_current_page", } },
  },
}
-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 158380,
  signature = "I7|untouched stock autosuspend",
  history = {
    { op = "move_item_to_menu", args = { ["dest"] = "setting", ["from"] = "device", ["id"] = "autosuspend", } },
    { op = "external_native_edit", args = { ["menu"] = "navi", ["view"] = "reader", } },
  },
}
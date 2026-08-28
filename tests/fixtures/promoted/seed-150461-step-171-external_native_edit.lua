-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 150461,
  signature = "I6|poweroff",
  history = {
    { op = "move_item_to_menu", args = { ["dest"] = "filemanager_settings", ["from"] = "exit_menu", ["id"] = "poweroff", } },
    { op = "external_native_edit", args = { ["menu"] = "network", ["view"] = "filemanager", } },
    { op = "external_native_edit", args = { ["menu"] = "filemanager_settings", ["view"] = "filemanager", } },
    { op = "upstream_remove_tab", args = { ["id"] = "filemanager_settings", ["view"] = "filemanager", } },
  },
}
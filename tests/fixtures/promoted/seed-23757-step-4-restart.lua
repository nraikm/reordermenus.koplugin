-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 23757,
  signature = "I8|restart",
  history = {
    { op = "reorder_tabs", args = { ["tabs"] = { [1] = "setting", [2] = "search", [3] = "main", [4] = "filemanager_settings", [5] = "plus_menu", [6] = "tools", }, } },
    { op = "create_submenu", args = { ["parent"] = "taps_and_gestures", ["title"] = "中文菜单", } },
    { op = "rename_submenu", args = { ["id"] = "reorderingmenus:user:fb31e8c9f8edcec56471a6749b3cf116", ["title"] = "Notes", ["view"] = "filemanager", } },
    { op = "restart", args = {} },
  },
}
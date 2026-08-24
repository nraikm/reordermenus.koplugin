-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 47514,
  signature = "I7|order",
  history = {
    { op = "save_order", args = {} },
    { op = "external_native_edit", args = { ["menu"] = "setting", ["view"] = "filemanager", } },
    { op = "create_submenu", args = { ["parent"] = "main", ["title"] = "中文菜单", } },
  },
}
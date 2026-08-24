-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 47514,
  signature = "I7|order",
  history = {
    { op = "create_submenu", args = { ["parent"] = "help", ["title"] = "Notes", } },
    { op = "restart", args = {} },
    { op = "external_native_edit", args = { ["menu"] = "device", ["view"] = "filemanager", } },
    { op = "create_submenu", args = { ["parent"] = "network", ["title"] = "Tools", } },
  },
}
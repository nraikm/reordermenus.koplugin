-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 47514,
  signature = "I7|order",
  history = {
    { op = "upstream_remove", args = { ["id"] = "file_search", ["menu"] = "search", ["view"] = "filemanager", } },
    { op = "move_item_in_menu", args = { ["from"] = 13, ["menu"] = "search", ["to"] = 2, } },
    { op = "create_submenu", args = { ["parent"] = "document", ["title"] = "Tools", } },
  },
}
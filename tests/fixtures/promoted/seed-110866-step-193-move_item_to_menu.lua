-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 110866,
  signature = "I6|plugin_management",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "external_native_edit", args = { ["menu"] = "search", ["view"] = "reader", } },
    { op = "conditional_capability", args = { ["id"] = "frontlight", ["menu"] = "setting", ["view"] = "reader", } },
    { op = "reorder_tabs", args = { ["tabs"] = { [1] = "tools", [2] = "main", [3] = "setting", [4] = "navi", [5] = "ntab1", [6] = "search", [7] = "filemanager", [8] = "typeset", }, } },
    { op = "save_order", args = {} },
    { op = "upstream_remove_tab", args = { ["id"] = "setting", ["view"] = "reader", } },
    { op = "move_item_to_menu", args = { ["dest"] = "setting", ["from"] = "more_tools", ["id"] = "plugin_management", } },
  },
}
-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 31676,
  signature = "I6|vocabbuilder",
  history = {
    { op = "reorder_tabs", args = { ["tabs"] = { [1] = "tools", [2] = "navi", [3] = "filemanager", [4] = "typeset", [5] = "search", [6] = "main", }, } },
    { op = "sort_menu_za", args = { ["menu"] = "typeset", ["seq"] = { [1] = "typography", [2] = "switch_zoom_mode", [3] = "style_tweaks", [4] = "start_content_selection", [5] = "speed_reading_module_perception_expander", [6] = "set_render_style", [7] = "selection_text", [8] = "panel_zoom_options", [9] = "page_overlap", [10] = "highlight_options", [11] = "document_settings", [12] = "djvu_render_mode", [13] = "change_font", }, } },
    { op = "move_item_to_menu", args = { ["dest"] = "typeset", ["from"] = "search", ["id"] = "vocabbuilder", } },
  },
}
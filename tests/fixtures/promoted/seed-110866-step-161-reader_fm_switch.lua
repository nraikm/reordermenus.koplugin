-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 110866,
  signature = "I16|disabled mismatch",
  history = {
    { op = "reorder_tabs", args = { ["tabs"] = { [1] = "tools", [2] = "ntab1", [3] = "main", [4] = "navi", [5] = "typeset", [6] = "search", [7] = "setting", [8] = "filemanager", }, } },
    { op = "stage_list_permutation", args = { ["menu"] = "typeset", ["seq"] = { [1] = "panel_zoom_options", [2] = "change_font", [3] = "set_render_style", [4] = "highlight_options", [5] = "switch_zoom_mode", [6] = "start_content_selection", [7] = "selection_text", [8] = "document_settings", [9] = "speed_reading_module_perception_expander", [10] = "djvu_render_mode", [11] = "page_overlap", [12] = "typography", [13] = "style_tweaks", }, } },
    { op = "create_submenu", args = { ["parent"] = "typeset", ["title"] = "Tools", } },
  },
}
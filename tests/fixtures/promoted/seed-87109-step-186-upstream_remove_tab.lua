-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 87109,
  signature = "I6|profiles",
  history = {
    { op = "reorder_tabs", args = { ["tabs"] = { [1] = "setting", [2] = "typeset", [3] = "filemanager", [4] = "tools", }, } },
    { op = "stage_list_permutation", args = { ["menu"] = "typeset", ["seq"] = { [1] = "switch_zoom_mode", [2] = "start_content_selection", [3] = "panel_zoom_options", [4] = "speed_reading_module_perception_expander", [5] = "document_settings", [6] = "djvu_render_mode", [7] = "nitem6", [8] = "set_render_style", [9] = "highlight_options", [10] = "style_tweaks", [11] = "selection_text", [12] = "typography", [13] = "change_font", [14] = "page_overlap", }, } },
    { op = "move_item_to_menu", args = { ["dest"] = "typeset", ["from"] = "tools", ["id"] = "profiles", } },
  },
}
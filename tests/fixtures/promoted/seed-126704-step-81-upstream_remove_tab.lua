-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 126704,
  signature = "I6|screen_dpi",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "stage_list_permutation", args = { ["menu"] = "typeset", ["seq"] = { [1] = "switch_zoom_mode", [2] = "change_font", [3] = "page_overlap", [4] = "screen_dpi", [5] = "selection_text", [6] = "style_tweaks", [7] = "start_content_selection", [8] = "document_settings", [9] = "panel_zoom_options", [10] = "djvu_render_mode", [11] = "speed_reading_module_perception_expander", [12] = "typography", [13] = "set_render_style", [14] = "highlight_options", }, } },
    { op = "save_order", args = {} },
    { op = "external_native_edit", args = { ["menu"] = "more_tools", ["view"] = "reader", } },
    { op = "upstream_remove_tab", args = { ["id"] = "typeset", ["view"] = "reader", } },
  },
}
-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 87109,
  signature = "I6|about",
  history = {
    { op = "external_native_edit", args = { ["menu"] = "navigation", ["view"] = "reader", } },
    { op = "upstream_remove_tab", args = { ["id"] = "setting", ["view"] = "reader", } },
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "stage_list_permutation", args = { ["menu"] = "typeset", ["seq"] = { [1] = "style_tweaks", [2] = "switch_zoom_mode", [3] = "selection_text", [4] = "about", [5] = "start_content_selection", [6] = "djvu_render_mode", [7] = "nitem6", [8] = "set_render_style", [9] = "change_font", [10] = "speed_reading_module_perception_expander", [11] = "panel_zoom_options", [12] = "document_settings", [13] = "typography", [14] = "highlight_options", [15] = "page_overlap", }, } },
    { op = "save_order", args = {} },
    { op = "upstream_remove_tab", args = { ["id"] = "typeset", ["view"] = "reader", } },
  },
}
-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 150461,
  signature = "I16|disabled mismatch",
  history = {
    { op = "plugin_install", args = { ["hint"] = "search", ["id"] = "xitem6", ["name"] = "p6", ["view"] = "reader", } },
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "stage_list_permutation", args = { ["menu"] = "typeset", ["seq"] = { [1] = "set_render_style", [2] = "xitem6", [3] = "panel_zoom_options", [4] = "highlight_options", [5] = "start_content_selection", [6] = "djvu_render_mode", [7] = "typography", [8] = "document_settings", [9] = "switch_zoom_mode", [10] = "speed_reading_module_perception_expander", [11] = "style_tweaks", [12] = "selection_text", [13] = "change_font", }, } },
    { op = "save_order", args = {} },
    { op = "upstream_remove_tab", args = { ["id"] = "typeset", ["view"] = "reader", } },
  },
}
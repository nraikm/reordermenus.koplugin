-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 87109,
  signature = "I6|vocabbuilder",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "save_order", args = {} },
    { op = "external_native_edit", args = { ["menu"] = "network", ["view"] = "reader", } },
    { op = "stage_list_permutation", args = { ["menu"] = "setting", ["seq"] = { [1] = "screen", [2] = "taps_and_gestures", [3] = "vocabbuilder", [4] = "nitem2", [5] = "device", [6] = "language", [7] = "status_bar", [8] = "network", [9] = "navigation", }, } },
    { op = "save_order", args = {} },
    { op = "upstream_remove_tab", args = { ["id"] = "setting", ["view"] = "reader", } },
  },
}
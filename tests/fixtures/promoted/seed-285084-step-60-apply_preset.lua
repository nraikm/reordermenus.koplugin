-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 285084,
  signature = "I7|order",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "save_order", args = {} },
    { op = "save_preset", args = { ["name"] = "sm285084_1", ["view"] = "reader", } },
    { op = "stage_list_permutation", args = { ["menu"] = "tools", ["seq"] = { [1] = "exporter", [2] = "statistics", [3] = "progress_sync", [4] = "move_to_archive", [5] = "wallabag", [6] = "news_downloader", [7] = "qrclipboard", [8] = "read_timer", [9] = "calibre", [10] = "profiles", [11] = "more_tools", }, } },
    { op = "apply_preset", args = { ["name"] = "sm285084_1", } },
  },
}
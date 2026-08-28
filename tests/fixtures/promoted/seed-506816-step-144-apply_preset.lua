-- Promoted positive regression (was an XFAIL for the preset/healing bugs).
-- If this history ever fails again, test_regressions_promoted fails loudly.
return {
  seed = 506816,
  signature = "I7|order",
  history = {
    { op = "save_order", args = {} },
    { op = "save_preset", args = { ["name"] = "sm506816_2", ["view"] = "filemanager", } },
    { op = "stage_list_permutation", args = { ["menu"] = "tools", ["seq"] = { [1] = "news_downloader", [2] = "move_to_archive", [3] = "profiles", [4] = "wallabag", [5] = "exporter", [6] = "text_editor", [7] = "qrclipboard", [8] = "cloud_storage", [9] = "read_timer", [10] = "statistics", [11] = "more_tools", [12] = "calibre", }, } },
    { op = "apply_preset", args = { ["name"] = "sm506816_2", } },
  },
}
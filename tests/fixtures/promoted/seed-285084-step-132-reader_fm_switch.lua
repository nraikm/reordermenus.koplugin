-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 285084,
  signature = "I7|order&&I7|untouched stock fullscreen&&I7|untouched stock wikipedia_lookup",
  history = {
    { op = "reader_fm_switch", args = { ["view"] = "reader", } },
    { op = "stage_list_permutation", args = { ["menu"] = "tools", ["seq"] = { [1] = "move_to_archive", [2] = "calibre", [3] = "wallabag", [4] = "wikipedia_lookup", [5] = "text_editor", [6] = "statistics", [7] = "qrclipboard", [8] = "nitem3", [9] = "progress_sync", [10] = "more_tools", [11] = "exporter", [12] = "read_timer", [13] = "fullscreen", [14] = "profiles", [15] = "news_downloader", }, } },
    { op = "upstream_remove", args = { ["id"] = "file_ext_assoc", ["menu"] = "device", ["view"] = "filemanager", } },
  },
}
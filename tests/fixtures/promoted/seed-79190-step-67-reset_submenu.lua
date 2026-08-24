-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 79190,
  signature = "I7|order&&I7|untouched stock mass_storage_settings",
  history = {
    { op = "stage_list_permutation", args = { ["menu"] = "tools", ["seq"] = { [1] = "calibre", [2] = "profiles", [3] = "statistics", [4] = "text_editor", [5] = "news_downloader", [6] = "qrclipboard", [7] = "move_to_archive", [8] = "mass_storage_settings", [9] = "more_tools", [10] = "progress_sync", [11] = "exporter", [12] = "read_timer", [13] = "nitem1", [14] = "wallabag", }, } },
    { op = "upstream_remove", args = { ["id"] = "cover_events", ["menu"] = "device", ["view"] = "reader", } },
  },
}
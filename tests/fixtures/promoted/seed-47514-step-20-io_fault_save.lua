-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 47514,
  signature = "I7|order",
  history = {
    { op = "sort_menu_za", args = { ["menu"] = "search_settings", ["seq"] = { [1] = "wikipedia_settings", [2] = "translation_settings", [3] = "fulltext_search_settings", [4] = "dictionary_settings", }, } },
    { op = "io_fault_save", args = {} },
  },
}
-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 31676,
  signature = "I6|filemanager",
  history = {
    { op = "hide_tab", args = { ["id"] = "filemanager", } },
    { op = "unhide_all", args = { ["ids"] = { [1] = "filemanager", }, } },
  },
}
-- Auto-generated regression fixture. DO NOT EDIT BY HAND.
-- Regenerate via the state-machine suite; retire via XPASS review.
return {
  seed = 31676,
  -- refreshed 2026-08-23: P0 pipeline refactor added the known I16
  -- disabled-mismatch family to this history alongside the original I7.
  signature = "I16|disabled mismatch&&I7|untouched stock language_support",
  history = {
    { op = "hide_item", args = { ["id"] = "language_support", ["parent"] = "document", } },
    { op = "io_fault_save", args = {} },
  },
}
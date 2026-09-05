--[[-- semantic_diff unit checks (pure, no KOReader env) --]]
package.path = "/Users/nr/Development/ReorderingMenus/?.lua;" .. package.path
local SD = require("lib.semantic_diff")

local passed, failed = 0, 0
local function assert_eq(a, e, msg)
   if a == e then passed = passed + 1
   else failed = failed + 1; print("[FAIL] " .. msg ..
      string.format(" expected=%s got=%s", tostring(e), tostring(a))) end
end
local function assert_table_eq(a, b, msg)
   local sa, sb = table.concat(a, "|"), table.concat(b, "|")
   assert_eq(sa, sb, msg .. " [" .. sa .. " vs " .. sb .. "]")
end

-- LCS
assert_table_eq(SD.lcs({"A","B","C","D","E"}, {"A","D","B","C","E"}),
   {"A","B","C","E"}, "lcs of single swap keeps ABC E")
assert_table_eq(SD.lcs({}, {"x"}), {}, "lcs empty-old")
assert_table_eq(SD.lcs({"1","2","3"}, {"1","2","3"}), {"1","2","3"}, "lcs identical")
assert_table_eq(SD.lcs({"a","b","c"},{"c","b","a"}), {"a"} , "lcs reversal len3")

-- infer_list_change: no change
assert_eq(SD.infer_list_change({"A","B","C"}, {"A","B","C"}), nil, "no change -> nil")

-- the motivating case from the task: A B C D E -> A D B C E
local r = SD.infer_list_change({"A","B","C","D","E"}, {"A","D","B","C","E"})
assert_eq(r and r.kind, "single_move", "task example classified as single_move")
assert_eq(r and r.id, "D", "task example moved id D")
-- D now sits at index 2, predecessor is A:
assert_eq(r and tostring(r.after), "A", "task example anchor after=A")

-- move to front / back
r = SD.infer_list_change({"A","B","C"}, {"C","A","B"})
assert_eq(r and r.kind, "single_move", "move-to-front kind")
assert_eq(tostring(r.after), "false", "move-to-front anchor=false")
r = SD.infer_list_change({"A","B","C"}, {"B","C","A"})
assert_eq(r and r.id, "A", "move-to-end id")

-- total reversal
r = SD.infer_list_change({"A","B","C","D"}, {"D","C","B","A"})
assert_eq(r and r.kind, "reversal", "total reversal detected")

-- block move: A [B C D] E F -> A E F [B C D]
r = SD.infer_list_change({"A","B","C","D","E","F"}, {"A","E","F","B","C","D"})
assert_eq(r and r.kind, "block_move", "block move detected")
if r then assert_table_eq(r.block or {}, {"B","C","D"}, "block members") end

-- bulk fallback: two independent swaps
r = SD.infer_list_change({"A","B","C","D"}, {"B","A","D","C"})
assert_eq(r and r.kind, "bulk", "two swaps => bulk")
if r and r.sequence then assert_table_eq(r.sequence, {"B","A","D","C"}, "bulk sequence") end

-- separators ignored for ordering classification
r = SD.infer_list_change(
   {"A", "--", "B", "C"},
   {-- same rows+order, separator shifted only
    "A", "--", "B", "C"})
assert_eq(r, nil, "identical-with-seps -> nil")
r = SD.infer_list_change(
   {"A", "B", "C"},
   {"A", "B", "C", SD.SEPARATOR_ID})   -- pure separator addition at end
assert_eq(r, nil, "separator-only change -> nil ordering action")

-- membership claims
local reg = { nodes = {
   x = { default_parent = "menu1" },
   y = { default_parent = "menu2" },
} }
local chosen = SD.resolve_claims(reg, { x = {"menu2"}, y = {"menu1","menu2"} })
assert_eq(chosen.x, "menu2", "non-default claimant wins")
assert_eq(chosen.y, "menu1", "alphabetical tie-break on double non-default")

print(string.format("semantic_diff: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end

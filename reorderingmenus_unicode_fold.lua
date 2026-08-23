--[[--
Unicode-safe case folding for user-facing comparison keys (search matching,
title ordering, case-insensitive collision checks).

This is KOReader's established convention — the same pair used by stock menu
search (frontend/ui/widget/menu.lua):

    Utf8Proc.lowercase(util.fixUtf8(str, "?"))

fixUtf8 replaces invalid byte sequences first so lowercase() never sees
malformed input; Utf8Proc.lowercase performs real Unicode case folding
(É/é, Greek final sigma, Cyrillic, Turkish dotted/dotless I as supported
by utf8proc, etc.).

IDENTITY RULE: this helper is for presentation/search keys ONLY. Canonical
identifiers (item ids, provider stamps, preset filenames) are persisted
byte-exact and must never be replaced by a folded form; fold a COPY when a
comparison needs case-insensitivity.
--]]

local util = require("util")
local Utf8Proc = require("ffi/utf8proc")

local UnicodeFold = {}

--- Return a case-folded comparison key for a user-presented string.
-- Never errors and never returns nil: non-strings fold to "", invalid
-- UTF-8 bytes become "?" (matching KOReader's own usage).
function UnicodeFold.key(str)
    if type(str) ~= "string" then return "" end
    local fixed = util.fixUtf8(str, "?")
    local folded = Utf8Proc.lowercase(fixed)
    return folded or ""
end

return UnicodeFold

--[[--
failure_sig.lua — stable failure signatures for generated regression fixtures.

A fixture records the signature of the failure it was promoted for. On
replay, three outcomes are distinguishable (Priority 4 contract):

  same signature      -> XFAIL   (unresolved known bug)
  no failure          -> XPASS   (bug possibly fixed — investigate, never
                                  silently retire)
  different signature -> SIGCHANGED (an unrelated regression replaced the
                                  original one — fail loudly)

The signature is computed from the SORTED, NORMALIZED SET of failure lines,
not from the first line: the invariant scan iterates hash tables, so which
single violation happens to be reported first varies per process even when
the underlying failure set is identical (verified empirically: same 12-line
failure set, 4 processes, different first lines).

The normalizer strips volatile detail (item ids, menu names, counts) so all
histories hitting the SAME root cause map to ONE signature, while different
invariant violations map to different ones. The final signature is the
sorted set of unique normalized lines joined with "&&", capped for length.
--]]

local FailureSig = {}

-- Strip anything after these marker phrases: they introduce per-seed detail.
local CUT_MARKERS = {
    " listed", " should", " rendered", " missing", " violated",
    " crashed", " changed", " dropped", " removed", " restored",
    " sits", " survives", " not under", " also", " leaked", " fabricated",
}

function FailureSig.normalizeOne(msg)
    msg = tostring(msg or ""):gsub("%s+", " ")
    -- table addresses vary per process: never part of a signature
    msg = msg:gsub("0x%x+", "0xADDR")
    -- Harness line numbers shift whenever tests/lib/*.lua is edited; they
    -- carry no root-cause signal and would SIGCHANGED every fixture on any
    -- harness touch-up. Keep the file name, drop the line number.
    msg = msg:gsub("([%w_]+%.lua):%d+", "%1")
    -- "op N crashed: <error>" — the crash text is the signature payload
    local crashed = msg:match("^op %d+ crashed:%s*(.+)$")
    if crashed then msg = crashed end
    local tag = msg:match("^(I%d+)") or msg:match("^(OPERROR)") or "OTHER"
    -- A pure table-address artifact (e.g. "table: 0x...") carries no
    -- root-cause signal: it is a tostring() of a transient object that
    -- happened to leak into a failure line. Normalize it away entirely.
    -- NOTE: this runs AFTER the 0x%x+ -> 0xADDR literalization above, so
    -- match the already-literalized form.
    if msg:match("^table: 0xADDR$") then return "-" end
    local kind
    if tag == "OPERROR" then
        -- keep the error head: e.g. "bad argument #2 to 'clear' "
        kind = msg:match("^OPERROR:%s*(.-)%s*%(") or msg:sub(9, 60)
        -- runtime errors embed absolute source paths: keep the basename tail
        kind = (kind:match("[^/]+$") or kind)
    elseif tag == "OTHER" then
        -- absolute paths from runtime errors carry no root-cause signal
        kind = msg:match("[^/]+$") or msg
        kind = kind:sub(1, 40)
    else
        -- text between the invariant tag and the first detail delimiter
        kind = msg:match("^I%d+%s*([^:()%]]*):")     -- "I7 order: ..."
            or msg:match("^I%d+%s*([^:()%]]*)$")     -- bare tag lines
            or ""
    end
    for _, marker in ipairs(CUT_MARKERS) do
        local at = kind:find(marker, 1, true)
        if at then kind = kind:sub(1, at - 1) end
    end
    kind = (kind:gsub("[%s:]+$", "")):gsub("^%s+", "")
    return tag .. "|" .. (kind ~= "" and kind or "-")
end

-- Signature over a LIST of failure lines (order-insensitive).
function FailureSig.normalize(lines)
    local seen, set = {}, {}
    for _, line in ipairs(lines or {}) do
        local sig = FailureSig.normalizeOne(line)
        if sig ~= "-" and not seen[sig] then
            seen[sig] = true
            set[#set + 1] = sig
        end
    end
    table.sort(set)
    local joined = table.concat(set, "&&")
    if #joined > 200 then joined = joined:sub(1, 200) .. "…" end
    return joined
end

return FailureSig

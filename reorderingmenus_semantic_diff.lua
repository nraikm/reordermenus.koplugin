--[[--
semantic_diff.lua — minimal intent inference for external native edits.

When a user hand-edits a native menu-order file, the observed change should
become the MINIMAL user action, not a frozen snapshot of the whole list:

    old: A B C D E      manual edit: A D B C E
    => move D before B  (one position_override)

not "order_override = [A D B C E]", which would shadow every future KOReader
reorder of untouched neighbours.

Algorithms (all deterministic; ties break on the lexicographically smallest
id, never on pairs() iteration order):

  lcs(a, b)          - longest common subsequence via dynamic programming
  diff_sequences     - LCS-based element diff: kept / removed / added
  infer_list_change  - classifies one menu's old->new as a minimal action:
                         identical            -> nil (no information)
                         single_move          -> { id, after } anchor
                         reversal             -> { reversed = true } (bulk)
                         block_move           -> { block = ids, after }
                         unrepresentable      -> full sequence (explicit bulk)
  infer_membership   - cross-parent claims -> per-id destination choice with
                         customized-destination-wins and alphabetical tie-break

The caller decides what to do with an explicit bulk sequence; this module only
guarantees that anything representable as a smaller action IS returned as the
smaller action.
--]]

local MenuSchema = require("reorderingmenus_menu_schema")

local SemanticDiff = {}

local SEPARATOR_ID = MenuSchema.SEPARATOR_ID
SemanticDiff.SEPARATOR_ID = SEPARATOR_ID

-- -------------------------------------------------------------------------
-- Longest common subsequence of two arrays of strings.
-- O(#a * #b) time/space - menu lists are small (tens of rows), fine.
-- Deterministic: produces ONE canonical LCS (the DP backtrace prefers
-- moving up over left, which is stable for any input pair).
-- -------------------------------------------------------------------------
function SemanticDiff.lcs(a, b)
    local n, m = #a, #b
    local dp = {}
    for i = 0, n do dp[i] = { [0] = 0 } end
    for j = 1, m do dp[0][j] = 0 end
    for i = 1, n do
        for j = 1, m do
            if a[i] == b[j] then
                dp[i][j] = dp[i - 1][j - 1] + 1
            else
                local up, left = dp[i - 1][j], dp[i][j - 1]
                dp[i][j] = (up >= left) and up or left
            end
        end
    end
    -- backtrace
    local result = {}
    local i, j = n, m
    while i > 0 and j > 0 do
        if a[i] == b[j] then
            table.insert(result, 1, a[i])
            i, j = i - 1, j - 1
        elseif dp[i - 1][j] >= dp[i][j - 1] then
            i = i - 1
        else
            j = j - 1
        end
    end
    return result
end

-- Element-level classification of old vs new. Returns:
--   kept   = ordered common subsequence (as it appears in NEW)
--   removed= ids in OLD but not in NEW (sorted)
--   added  = ids in NEW but not in OLD (in new order)
function SemanticDiff.diff_sequences(old, new)
    local kept = SemanticDiff.lcs(old, new)
    local kept_set = {}
    for _, id in ipairs(kept) do kept_set[id] = true end

    local old_set, new_set = {}, {}
    for _, id in ipairs(old) do old_set[id] = true end
    for _, id in ipairs(new) do new_set[id] = true end

    local removed, added = {}, {}
    for _, id in ipairs(old) do
        if not kept_set[id] and not new_set[id] then table.insert(removed, id) end
    end
    -- ids present in both but NOT in the LCS were moved; they are neither
    -- removed nor added.
    local moved_or_kept_in_new = {}
    for _, id in ipairs(new) do
        if not kept_set[id] then
            if old_set[id] then
                table.insert(moved_or_kept_in_new, id)
            else
                table.insert(added, id)
            end
        end
    end
    for _, id in ipairs(kept) do table.insert(moved_or_kept_in_new, id) end
    table.sort(removed)
    return kept, removed, moved_or_kept_in_new, added
end

local function same_multiset(a, b)
    if #a ~= #b then return false end
    local count = {}
    for _, x in ipairs(a) do count[x] = (count[x] or 0) + 1 end
    for _, x in ipairs(b) do
        count[x] = (count[x] or 0) - 1
        if (count[x] or 0) < 0 then return false end
    end
    return true
end

-- Single-relocation detection (same multiset): find the row whose removal
-- makes both sequences equal. Returns id, target_index_in_new (1-based slot
-- it now occupies), or nil.
local function find_single_relocation(old, new)
    for removed_index, candidate in ipairs(new) do
        if candidate ~= SEPARATOR_ID then
            local trimmed_new = {}
            for i, id in ipairs(new) do
                if i ~= removed_index then table.insert(trimmed_new, id) end
            end
            local trimmed_old = {}
            local taken = false
            for _, id in ipairs(old) do
                if not taken and id == candidate then
                    taken = true
                else
                    table.insert(trimmed_old, id)
                end
            end
            if taken then
                local equal = #trimmed_old == #trimmed_new
                if equal then
                    for k = 1, #trimmed_old do
                        if trimmed_old[k] ~= trimmed_new[k] then
                            equal = false
                            break
                        end
                    end
                end
                if equal then return candidate, removed_index end
            end
        end
    end
    return nil
end

-- Contiguous-block relocation: some contiguous run of OLD appears verbatim,
-- in order, at a different contiguous position in NEW, with everything else
-- in place. Returns { block = {...}, after = anchor }, anchor being the new
-- predecessor of the block (false when it now starts the list), or nil.
local function find_block_relocation(old, new)
    local n = #old
    -- try every contiguous window of old (length >= 2), longest first
    for len = n - 1, 2, -1 do
        for start = 1, n - len + 1 do
            local block = {}
            for i = start, start + len - 1 do
                table.insert(block, old[i])
            end
            -- does the block appear verbatim somewhere else in new?
            for nstart = 1, #new - len + 1 do
                local matches = true
                for k = 1, len do
                    if new[nstart + k - 1] ~= block[k] then
                        matches = false
                        break
                    end
                end
                if matches and nstart ~= start then
                    -- everything outside the block must be in the same
                    -- relative order in old and new
                    local rest_old, rest_new = {}, {}
                    for i = 1, n do
                        local in_block = i >= start and i < start + len
                        if not in_block then table.insert(rest_old, old[i]) end
                    end
                    for i = 1, #new do
                        local in_block = i >= nstart and i < nstart + len
                        if not in_block then table.insert(rest_new, new[i]) end
                    end
                    local same = true
                    for k = 1, #rest_old do
                        if rest_old[k] ~= rest_new[k] then
                            same = false
                            break
                        end
                    end
                    if same and #rest_old == #rest_new then
                        local anchor = nstart > 1 and new[nstart - 1] or false
                        return {
                            block = block,
                            after = anchor,
                            before = (nstart + len <= #new)
                                and new[nstart + len] or nil,
                        }
                    end
                end
            end
        end
    end
    return nil
end

-- Classify one menu's old->new transformation. `old`/`new` are raw lists of
-- string ids (separators included). Returns nil when nothing changed, else a
-- descriptor:
--   { kind = "single_move", id, after }   - one row relocated
--   { kind = "block_move", block, after } - one contiguous run relocated
--   { kind = "reversal" }                 - exact reverse (a sort Z-A)
--   { kind = "removal", removed }         - rows deleted, survivors keep
--                                         relative order (upstream deletion
--                                         or an item moved OUT by hand)
--   { kind = "addition", added }          - rows inserted, incumbents keep
--                                         relative order (update arrival)
--   { kind = "bulk", sequence }           - anything else (explicit sequence)
--   { kind = "membership_only" }          - pure add/remove handled elsewhere
function SemanticDiff.infer_list_change(old, new)
    if type(old) ~= "table" or type(new) ~= "table" then return nil end

    -- strip separators for ordering analysis; separator placement is handled
    -- through separator records by the caller.
    local function strip(t)
        local out = {}
        for _, id in ipairs(t) do
            if id ~= SEPARATOR_ID then table.insert(out, id) end
        end
        return out
    end
    local olds, news = strip(old), strip(new)

    if #olds == #news then
        local identical = true
        for i = 1, #olds do
            if olds[i] ~= news[i] then identical = false break end
        end
        if identical then return nil end

        local reversed = #olds > 1
        for i = 1, #olds do
            if olds[i] ~= news[#news - i + 1] then reversed = false break end
        end
        if reversed then
            return { kind = "reversal" }
        end

        local moved_id, at = find_single_relocation(olds, news)
        if moved_id then
            local after = at > 1 and news[at - 1] or false
            return { kind = "single_move", id = moved_id, after = after }
        end

        local blk = find_block_relocation(olds, news)
        if blk then
            return { kind = "block_move", block = blk.block, after = blk.after }
        end
    else
        -- Unequal lengths: distinguish genuine reshuffles (bulk) from PURE
        -- insertions / removals, where every survivor keeps its relative
        -- order. Those carry no ORDERING information at all - the id sets
        -- change, which membership reconciliation handles - so freezing an
        -- explicit sequence for them would shadow future upstream reorders.
        local function is_subsequence(small, big)
            local j = 1
            for i = 1, #big do
                if big[i] == small[j] then j = j + 1 end
            end
            return j > #small
        end
        if #news < #olds and is_subsequence(news, olds) then
            local new_set = {}
            for _, id in ipairs(news) do new_set[id] = true end
            local removed = {}
            for _, id in ipairs(olds) do
                if not new_set[id] then table.insert(removed, id) end
            end
            return { kind = "removal", removed = removed }
        end
        if #news > #olds and is_subsequence(olds, news) then
            local old_set = {}
            for _, id in ipairs(olds) do old_set[id] = true end
            local added = {}
            for _, id in ipairs(news) do
                if not old_set[id] then table.insert(added, id) end
            end
            return { kind = "addition", added = added }
        end
    end

    return { kind = "bulk", sequence = news }
end

-- Resolve membership claims gathered from every changed level of an edited
-- file: an id listed under a non-default parent means "the user moved it".
-- Claims is { [id] = { menu_a, menu_b, ... } }; returns { [id] = chosen }.
-- Policy: prefer a non-default claimant (customized destination wins);
-- ties break alphabetically for determinism under any iteration order.
function SemanticDiff.resolve_claims(reg, claims)
    local chosen_by_id = {}
    for id, claimants in pairs(claims) do
        table.sort(claimants)
        local node = reg.nodes[id]
        local default_parent = node and node.default_parent or nil
        local non_default = {}
        for _, m in ipairs(claimants) do
            if m ~= default_parent then table.insert(non_default, m) end
        end
        chosen_by_id[id] = non_default[1] or claimants[1]
    end
    return chosen_by_id
end

return SemanticDiff

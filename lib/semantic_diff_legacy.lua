-- Compatibility algorithms used by historical callers and diagnostic tests.
-- Production mutations use SemanticDiff.classify_permutation and IntentOps.

local Legacy = {}

-- -------------------------------------------------------------------------
-- Longest common subsequence of two arrays of strings.
-- O(#a * #b) time/space - menu lists are small (tens of rows), fine.
-- Deterministic: produces ONE canonical LCS (the DP backtrace prefers
-- moving up over left, which is stable for any input pair).
-- -------------------------------------------------------------------------
function Legacy.lcs(a, b)
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

local function find_block_relocation(old, new, SemanticDiff)
    local n = #old
    for len = n - 1, 2, -1 do
        for start = 1, n - len + 1 do
            local block = {}
            for i = start, start + len - 1 do
                table.insert(block, old[i])
            end
            for nstart = 1, #new - len + 1 do
                local matches = true
                for k = 1, len do
                    if new[nstart + k - 1] ~= block[k] then
                        matches = false
                        break
                    end
                end
                if matches and nstart ~= start then
                    local rest_old, rest_new = {}, {}
                    for i = 1, n do
                        local in_block = i >= start and i < start + len
                        if not in_block then table.insert(rest_old, old[i]) end
                    end
                    for i = 1, #new do
                        local in_block = i >= nstart and i < nstart + len
                        if not in_block then table.insert(rest_new, new[i]) end
                    end
                    if SemanticDiff.sequence_equal(rest_old, rest_new) then
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
-- descriptor.
function Legacy.infer_list_change(old, new, SemanticDiff)
    if type(old) ~= "table" or type(new) ~= "table" then return nil end

    local olds = SemanticDiff.items_projection(old)
    local news = SemanticDiff.items_projection(new)

    if #olds == #news then
        if SemanticDiff.sequence_equal(olds, news) then return nil end

        local reversed = #olds > 1
        for i = 1, #olds do
            if olds[i] ~= news[#news - i + 1] then reversed = false break end
        end
        if reversed then
            return { kind = "reversal" }
        end

        local det = SemanticDiff.detect_relocation(olds, news, { separator_aware = false })
        if det and det.move then
            local move = det.move
            local after = move.type == "move_before" and false or move.after
            return { kind = "single_move", id = move.item, after = after }
        end

        local blk = find_block_relocation(olds, news, SemanticDiff)
        if blk then
            return { kind = "block_move", block = blk.block, after = blk.after }
        end
    else
        -- Unequal lengths: distinguish genuine reshuffles (bulk) from PURE
        -- insertions / removals, where every survivor keeps its relative
        -- order. Those carry no ORDERING information at all - the id sets
        -- change, which membership reconciliation handles - so freezing an
        -- explicit sequence for them would shadow future upstream reorders.
        if #news < #olds and SemanticDiff.is_subsequence(news, olds) then
            local new_set = {}
            for _, id in ipairs(news) do new_set[id] = true end
            local removed = {}
            for _, id in ipairs(olds) do
                if not new_set[id] then table.insert(removed, id) end
            end
            return { kind = "removal", removed = removed }
        end
        if #news > #olds and SemanticDiff.is_subsequence(olds, news) then
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
function Legacy.resolve_claims(reg, claims)
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

return Legacy

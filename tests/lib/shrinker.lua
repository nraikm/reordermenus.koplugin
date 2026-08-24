--[[--
shrinker.lua — delta-debugging minimization for recorded SM histories.

Given a deterministic predicate fails(seed, history) -> boolean, ddmin
deletes chunks of the history until no single-chunk deletion preserves
the failure, then collapses consecutive duplicate entries. Bounded by a
replay budget so a pathological case cannot hang the nightly.
--]]

local Shrinker = {}

function Shrinker.shrink(seed, history, fails_predicate, max_replays)
    max_replays = max_replays or 400
    local replays = 0

    local function test(hist)
        replays = replays + 1
        if replays > max_replays then return false end
        return fails_predicate(seed, hist)
    end

    -- Fast path: confirm the full history actually reproduces.
    if not test(history) then
        return history, replays, false
    end

    local current = {}
    for i, entry in ipairs(history) do
        current[i] = entry
    end

    -- ddmin over deletable chunks
    local n = 2
    while #current >= 2 do
        local chunk_size = math.max(1, math.ceil(#current / n))
        local removed_any = false
        local i = 1
        while i <= #current do
            local candidate = {}
            for j = 1, #current do
                if j < i or j >= i + chunk_size then
                    candidate[#candidate + 1] = current[j]
                end
            end
            if #candidate > 0 and #candidate < #current and test(candidate) then
                current = candidate
                removed_any = true
                n = 2
                chunk_size = math.max(1, math.ceil(#current / n))
                i = 1
            else
                i = i + chunk_size
            end
            if replays > max_replays then break end
        end
        if replays > max_replays then break end
        if not removed_any then
            if n >= #current then break end
            n = math.min(#current, n * 2)
        end
    end

    -- collapse consecutive duplicate operations
    local collapsed = {}
    for _, entry in ipairs(current) do
        local last = collapsed[#collapsed]
        if not last or last.op ~= entry.op then
            collapsed[#collapsed + 1] = entry
        end
    end
    if #collapsed < #current and test(collapsed) then
        current = collapsed
    end

    return current, replays, true
end

return Shrinker

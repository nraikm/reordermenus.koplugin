--[[--
visibility.lua — explicit hiding vs inherited invisibility vs absence.

A menu id can be invisible for four disjoint reasons; conflating them is what
made "unhide" report success while nothing appeared:

  explicitly_hidden   an applicable hidden record exists for this id
                      (Materializer.hiddenApplies). Clearing it is the unhide.
  hidden_by_ancestor  no applicable record for this id, but the id is in the
                      validated disabled set because an ancestor container
                      (tab or submenu) is hidden or unreachable. The item
                      stays invisible until its PATH is revealed. Unhiding the
                      child alone is idempotent but not sufficient; the UI must
                      say so and offer a deliberate reveal-path that unhides
                      ONLY the ancestors on that path (never unrelated hidden
                      content).
  unplaced            no valid parent anywhere (stale/invalid container
                      reference). Materializer reports unplaced; Validator
                      cascades into disabled. Requires safe migration to a
                      valid home or a truthful unplaced report.
  provider_absent     no live provider serves this id right now (uninstalled
                      plugin / conditional row). Records are dormant ghosts;
                      the row cannot render until its provider returns.
  visible             reachable in the validated projection.

status(reg, intent, graph, validated, id) is pure and history-free like the
materializer: same inputs -> same status. Callers (Manager.getVisibilityStatus)
build the four inputs from the current session; UI presenters branch on
.state without re-deriving the rule.
--]]

local MenuSchema = require("lib.menu_schema")
local Materializer = require("lib.materializer")

local Visibility = {}

Visibility.STATES = {
    VISIBLE = "visible",
    EXPLICITLY_HIDDEN = "explicitly_hidden",
    HIDDEN_BY_ANCESTOR = "hidden_by_ancestor",
    UNPLACED = "unplaced",
    PROVIDER_ABSENT = "provider_absent",
}

local MENU_BUTTONS_KEY = MenuSchema.MENU_BUTTONS_KEY

local function contains(list, id)
    for _, v in ipairs(list or {}) do
        if v == id then return true end
    end
    return false
end

local function isCustom(intent, id)
    return type(intent) == "table" and type(intent.custom_menus) == "table"
        and intent.custom_menus[id] ~= nil
end

--- Walk the effective-parent chain from id up toward the bar.
--- Returns array of ancestor ids (nearest first), capped at 32.
local function ancestorChain(reg, intent, id)
    local chain = {}
    local seen = {}
    local cur = id
    for _ = 1, 32 do
        local parent = Materializer.effectiveParent(reg, intent, cur)
        if parent == nil or parent == MENU_BUTTONS_KEY then
            if parent == MENU_BUTTONS_KEY then
                chain[#chain + 1] = MENU_BUTTONS_KEY
            end
            break
        end
        if seen[parent] then break end
        seen[parent] = true
        chain[#chain + 1] = parent
        cur = parent
    end
    return chain
end

--- Pure visibility classification. All inputs are current-session values:
---   reg       base registry
---   intent    one view's sparse intent section
---   graph     Materializer.resolve(reg, intent) (pre-validation)
---   validated Validator.validate(graph, reg, intent) repaired graph
function Visibility.status(reg, intent, graph, validated, id)
    intent = intent or {}
    graph = graph or { unplaced = {} }
    validated = validated or { disabled = {}, lists = {}, tabs = {} }
    if type(id) ~= "string" then
        return { state = Visibility.STATES.UNPLACED, id = id }
    end
    -- Explicit hide wins: an applicable record is the user's deliberate
    -- invisibility for THIS id, even when an ancestor is also hidden.
    if Materializer.hiddenApplies(reg, intent, id) then
        local rec = type(intent.hidden) == "table" and intent.hidden[id] or nil
        return {
            state = Visibility.STATES.EXPLICITLY_HIDDEN,
            id = id,
            record = rec,
            origin = type(rec) == "table" and rec.origin or nil,
        }
    end
    -- Provider absence: nothing live serves this id (and it is not a user
    -- custom container). Dormant ghost records may exist but cannot render.
    local node = reg and reg.nodes and reg.nodes[id] or nil
    if node == nil and not isCustom(intent, id) then
        -- Unknown ids that only exist as order entries / parent claims are
        -- still "absent": they cannot render until a provider serves them.
        -- Distinguish from unplaced (which IS served but has no home).
        -- If the id is in the validated disabled set via cascade, report
        -- unplaced only when a live claim exists; otherwise provider_absent.
        -- For simplicity: no node and no custom => provider_absent, unless
        -- the id is explicitly listed as unplaced (known via parent claim).
        if contains(graph.unplaced, id) then
            return { state = Visibility.STATES.UNPLACED, id = id }
        end
        return { state = Visibility.STATES.PROVIDER_ABSENT, id = id }
    end
    -- Unplaced: served but no valid parent (stale/invalid container).
    if contains(graph.unplaced, id) then
        return {
            state = Visibility.STATES.UNPLACED,
            id = id,
            parent = Materializer.effectiveParent(reg, intent, id),
        }
    end
    -- Reachability in the VALIDATED projection decides the rest. An id in
    -- validated disabled that is not explicitly hidden is there via cascade.
    local in_disabled = contains(validated.disabled, id)
    -- Visible when reachable: in tabs (for tabs) or in some surviving list.
    local reachable = false
    if contains(validated.tabs, id) then
        reachable = true
    else
        for _, list in pairs(validated.lists or {}) do
            for _, row in ipairs(list or {}) do
                if row == id then reachable = true break end
            end
            if reachable then break end
        end
    end
    if reachable and not in_disabled then
        return { state = Visibility.STATES.VISIBLE, id = id }
    end
    if not reachable or in_disabled then
        -- Find the nearest hidden/unreachable ancestor for an actionable path.
        local chain = ancestorChain(reg, intent, id)
        for _, anc in ipairs(chain) do
            if anc == MENU_BUTTONS_KEY then break end
            if Materializer.hiddenApplies(reg, intent, anc) then
                return {
                    state = Visibility.STATES.HIDDEN_BY_ANCESTOR,
                    id = id,
                    ancestor = anc,
                    path = chain,
                }
            end
            -- Level pruned as unreachable (hidden tab dragged its subtree, or
            -- a vanished intermediate container).
            if validated.lists and validated.lists[anc] == nil then
                -- Ancestor level itself gone: still an ancestor problem, with
                -- the missing level as the blocker when no explicit hide found.
                return {
                    state = Visibility.STATES.HIDDEN_BY_ANCESTOR,
                    id = id,
                    ancestor = anc,
                    path = chain,
                }
            end
        end
        -- No ancestor hide found but still not reachable: treat as unplaced
        -- (e.g., tab filtered from bar by an invalid override that resolve
        -- already migrated, or a level that validator pruned).
        if contains(validated.disabled, id) then
            return {
                state = Visibility.STATES.HIDDEN_BY_ANCESTOR,
                id = id,
                ancestor = chain[1],
                path = chain,
            }
        end
        return { state = Visibility.STATES.UNPLACED, id = id }
    end
    return { state = Visibility.STATES.VISIBLE, id = id }
end

return Visibility

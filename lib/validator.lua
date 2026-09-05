--[[--
validator.lua — structural guarantees for a materialized menu graph.

Runs after materialization and repairs deterministically instead of
crashing or corrupting KOReader's MenuSorter. Checks:

  - single parent   : every visible id is listed exactly once
  - no cycles       : submenu containers must form a DAG under the tab bar
  - valid anchors   : position hints and separators referencing siblings
  - collision       : created submenu ids must not clash with stock ids
  - hidden invariant: hidden ids appear in no list; protected entries stay
                      reachable so menu editing can never lock itself out

The validator never mutates intent; it repairs the derived graph and
reports what it had to fix.
--]]

local MenuSchema = require("lib.menu_schema")

local Validator = {}

local SEPARATOR_ID = MenuSchema.SEPARATOR_ID

local function array_contains(list, value)
    for _, entry in ipairs(list or {}) do
        if entry == value then return true end
    end
    return false
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t or {}) do table.insert(keys, k) end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local PROTECTED_ITEMS = MenuSchema.PROTECTED_ITEMS
local PROTECTED_TABS = MenuSchema.PROTECTED_TABS

function Validator.isItemProtected(item_id)
    return PROTECTED_ITEMS[item_id] == true
end

function Validator.isTabProtected(tab_id)
    return PROTECTED_TABS[tab_id] == true
end

local function repairDuplicateOwnership(ctx)
    local owners_by_id = {}
    for _, menu_id in ipairs(sortedKeys(ctx.lists)) do
        local list = ctx.lists[menu_id]
        local seen_in_menu = {}
        for _, id in ipairs(list or {}) do
            if id ~= SEPARATOR_ID then
                seen_in_menu[id] = true
                owners_by_id[id] = owners_by_id[id] or {}
                table.insert(owners_by_id[id], menu_id)
            end
        end
    end

    -- Deterministic repair: an explicit parent_override wins; otherwise the
    -- customized destination when there is exactly one non-default claimant,
    -- otherwise the alphabetically first.
    local keep_parent = {}
    local override_parent = {}
    if type(ctx.intent) == "table"
            and type(ctx.intent.parent_override) == "table" then
        for id, record in pairs(ctx.intent.parent_override) do
            if type(record) == "table" and record.parent then
                override_parent[id] = record.parent
            end
        end
    end

    -- Deterministic warning order: sort duplicate IDs before iteration
    local dup_ids = {}
    for id, owners in pairs(owners_by_id) do
        if #owners > 1 then
            table.insert(dup_ids, id)
        end
    end
    table.sort(dup_ids, function(a, b) return tostring(a) < tostring(b) end)

    for _, id in ipairs(dup_ids) do
        local owners = owners_by_id[id]
        table.sort(owners, function(a, b) return tostring(a) < tostring(b) end)
        local chosen = override_parent[id]
        if chosen then
            local found = false
            for _, o in ipairs(owners) do
                if o == chosen then found = true; break end
            end
            if not found then chosen = nil end
        end
        if not chosen then
            local node = ctx.reg.nodes and ctx.reg.nodes[id]
            local default_parent = node and node.default_parent or nil
            local non_default = {}
            for _, o in ipairs(owners) do
                if o ~= default_parent then table.insert(non_default, o) end
            end
            chosen = (#non_default == 1) and non_default[1] or owners[1]
        end
        keep_parent[id] = chosen
        table.insert(ctx.warnings, string.format(
            "%s listed under %d menus; kept %s", id, #owners, keep_parent[id]))
    end

    for _, menu_id in ipairs(sortedKeys(ctx.lists)) do
        local list = ctx.lists[menu_id]
        local seen_in_menu = {}
        local cleaned = {}
        for _, id in ipairs(list or {}) do
            if id == SEPARATOR_ID then
                table.insert(cleaned, id)
            elseif seen_in_menu[id] then
                table.insert(ctx.warnings,
                    string.format("duplicate row %s removed from %s", id, menu_id))
            else
                seen_in_menu[id] = true
                local keeper = keep_parent[id]
                if keeper == nil or keeper == menu_id then
                    ctx.owner[id] = ctx.owner[id] or menu_id
                    table.insert(cleaned, id)
                end
            end
        end
        ctx.lists[menu_id] = cleaned
    end
end

local function breakCycles(ctx)
    -- A container reachable from its own subtree would recurse forever in
    -- MenuSorter. Break cycles by dropping back-references. The scan runs
    -- over SORTED menu ids and removes, per cycle, every edge that points
    -- back into the scanning container - so the surviving edge set is a pure
    -- function of the graph, never of pairs() order.
    local function reaches(from, target)
        local visited = {}
        local stack = { from }
        while #stack > 0 do
            local current = table.remove(stack)
            if not visited[current] then
                visited[current] = true
                for _, child in ipairs(ctx.lists[current] or {}) do
                    if child == target then return true end
                    if ctx.lists[child] then table.insert(stack, child) end
                end
            end
        end
        return false
    end
    local cycle_menu_ids = sortedKeys(ctx.lists)
    for _, menu_id in ipairs(cycle_menu_ids) do
        if reaches(menu_id, menu_id) then
            local cleaned = {}
            for _, child in ipairs(ctx.lists[menu_id] or {}) do
                if child == menu_id or reaches(child, menu_id) then
                    table.insert(ctx.warnings, string.format(
                        "cycle broken: %s removed from %s", child, menu_id))
                else
                    table.insert(cleaned, child)
                end
            end
            ctx.lists[menu_id] = cleaned
        end
    end
end

local function removeHiddenRows(ctx)
    for _, id in ipairs(ctx.graph.disabled or {}) do ctx.hidden[id] = true end
    for _, menu_id in ipairs(sortedKeys(ctx.lists)) do
        local list = ctx.lists[menu_id]
        local cleaned = {}
        for _, id in ipairs(list or {}) do
            if ctx.hidden[id] then
                table.insert(ctx.warnings, string.format(
                    "hidden %s dropped from %s", id, menu_id))
            else
                table.insert(cleaned, id)
            end
        end
        ctx.lists[menu_id] = cleaned
    end
end

local function hideUnreachableContainers(ctx)
    -- Stock MenuSorter renders only what is reachable from the tab bar:
    -- hiding (or failing to place) a submenu hides its ENTIRE subtree, and
    -- stranded children either vanish or resurface as "NEW:"-prefixed
    -- orphans. Mirror that reality here: every menu level not reachable
    -- from the bar loses its level key, and its members join KOMenu:disabled
    -- so stock drops them cleanly instead of orphaning them.
    local function collect_reachable_levels()
        local seen = {}
        local stack = {}
        for _, t in ipairs(ctx.tabs) do
            if ctx.lists[t] and not seen[t] then
                seen[t] = true
                table.insert(stack, t)
            end
        end
        while #stack > 0 do
            local cur = table.remove(stack)
            for _, child in ipairs(ctx.lists[cur] or {}) do
                if ctx.lists[child] and not seen[child] then
                    seen[child] = true
                    table.insert(stack, child)
                end
            end
        end
        return seen
    end
    local reachable_levels = collect_reachable_levels()
    local unreachable_levels = {}
    for menu_id in pairs(ctx.lists) do
        if not reachable_levels[menu_id] then
            table.insert(unreachable_levels, menu_id)
        end
    end
    table.sort(unreachable_levels, function(a, b) return tostring(a) < tostring(b) end)
    local explicit_disabled = {}
    for _, id in ipairs(ctx.graph.disabled or {}) do
        explicit_disabled[id] = true
    end
    local newly_cascaded = {}
    local cascaded_set = {}
    if #unreachable_levels > 0 then
        for _, menu_id in ipairs(unreachable_levels) do
            for _, id in ipairs(ctx.lists[menu_id] or {}) do
                if id ~= SEPARATOR_ID and not explicit_disabled[id]
                        and not cascaded_set[id] then
                    table.insert(newly_cascaded, id)
                    cascaded_set[id] = true
                end
            end
            ctx.lists[menu_id] = nil
            table.insert(ctx.warnings, string.format(
                "container %s is unreachable from the tab bar; " ..
                "its contents follow it into invisibility", menu_id))
        end
    end
    for _, id in ipairs(ctx.graph.unplaced or {}) do
        if id ~= SEPARATOR_ID and not explicit_disabled[id] and not cascaded_set[id] then
            local is_custom = ctx.intent and ctx.intent.custom_menus and ctx.intent.custom_menus[id] ~= nil
            local node = ctx.reg.nodes and ctx.reg.nodes[id]
            if is_custom or (node and node.available ~= false) then
                table.insert(newly_cascaded, id)
                cascaded_set[id] = true
            end
        end
    end
    if #newly_cascaded > 0 then
        table.sort(newly_cascaded, function(a, b) return tostring(a) < tostring(b) end)
        for _, id in ipairs(newly_cascaded) do
            table.insert(ctx.graph.disabled, id)
        end
    end
end

local function removeNestedTabs(ctx)
    -- Defense in depth for unsupported tab_nesting placements: a top-level
    -- tab id must never appear as a row inside an ordinary menu list. Such
    -- a duplicate (tab in bar + nested placeholder with nil text and no
    -- sub_item_table) crashes the host menu when opened. Materializer
    -- already ignores tab_nesting overrides at resolve time; this repair
    -- keeps even hand-built graphs render-safe and deterministic.
    local tab_set = {}
    if ctx.reg and type(ctx.reg.tab_list) == "table" then
        for _, t in ipairs(ctx.reg.tab_list) do tab_set[t] = true end
    end
    if ctx.reg and ctx.reg.menus then
        for id, info in pairs(ctx.reg.menus) do
            if type(info) == "table" and info.is_tab == true then
                tab_set[id] = true
            end
        end
    end
    if next(tab_set) == nil then return end
    -- Tabs themselves are levels, not rows: never strip the bar.
    for _, menu_id in ipairs(sortedKeys(ctx.lists)) do
        local list = ctx.lists[menu_id]
        if type(list) == "table" then
            local cleaned = {}
            for _, id in ipairs(list) do
                if id ~= SEPARATOR_ID and tab_set[id] then
                    table.insert(ctx.warnings, string.format(
                        "tab %s cannot live inside %s; kept in tab bar", id, menu_id))
                else
                    table.insert(cleaned, id)
                end
            end
            ctx.lists[menu_id] = cleaned
        end
    end
    -- The bar itself may only name live tabs (legacy tab_order shapes may
    -- list ordinary submenu ids that can never render as tabs).
    if type(ctx.tabs) == "table" then
        local kept = {}
        for _, id in ipairs(ctx.tabs) do
            if tab_set[id] then
                table.insert(kept, id)
            else
                table.insert(ctx.warnings, string.format(
                    "non-tab %s cannot occupy the tab bar; dropped", tostring(id)))
            end
        end
        -- Never emit an empty bar: stock MenuSorter indexes [1] during orphan
        -- fallback. Restore the live bar order when filtering emptied it.
        if #kept == 0 and #ctx.tabs > 0 and ctx.reg and type(ctx.reg.tab_list) == "table" then
            for _, id in ipairs(ctx.reg.tab_list) do
                if not ctx.hidden[id] then
                    table.insert(kept, id)
                end
            end
        end
        -- Reassign in place so ctx.graph.tabs (aliased) observes the repair.
        for i = #ctx.tabs, 1, -1 do ctx.tabs[i] = nil end
        for i, id in ipairs(kept) do ctx.tabs[i] = id end
    end
end

local function rebuildOwnership(ctx)
    ctx.owner = {}
    for _, menu_id in ipairs(sortedKeys(ctx.lists)) do
        local list = ctx.lists[menu_id]
        for _, id in ipairs(list or {}) do
            if id ~= SEPARATOR_ID then ctx.owner[id] = menu_id end
        end
    end
end

local function restoreProtectedItems(ctx)
    -- A protected item must remain reachable somewhere in the tree, even
    -- when a migrated legacy configuration hid it. Reachability means more
    -- than ownership: an item parked under a hidden or unreachable ancestor
    -- is cascaded into invisibility by the passes above, which would lock
    -- the user out of menu editing entirely. Whenever the protected id is
    -- hidden, unowned, or owned by a level that did not survive the
    -- unreachable-container pass, it is relocated to the nearest guaranteed
    -- visible anchor: its provider hint home, else its default parent, else
    -- the first tab.
    local function level_present(menu_id)
        return type(menu_id) == "string" and ctx.lists[menu_id] ~= nil
    end

    local function persisted_trace(item_id, in_disabled)
        if in_disabled then return true end
        local it = ctx.intent or {}
        if it.hidden and it.hidden[item_id] ~= nil then return true end
        if it.parent_override and it.parent_override[item_id] ~= nil then
            return true
        end
        if it.position_override and it.position_override[item_id] ~= nil then
            return true
        end
        if it.custom_menus and it.custom_menus[item_id] then return true end
        for _, rec in pairs(it.order_override or {}) do
            if type(rec) == "table" then
                for _, entry in ipairs(rec.entries or {}) do
                    if MenuSchema.entryId(entry) == item_id then return true end
                end
            end
        end
        for _, raw in pairs(it.raw_override or {}) do
            if type(raw) == "table" and type(raw.list) == "table" then
                if array_contains(raw.list, item_id) then return true end
            end
        end
        return false
    end

    for _, item_id in ipairs(sortedKeys(PROTECTED_ITEMS)) do
        local node = ctx.reg.nodes and ctx.reg.nodes[item_id]
        local owner_menu = ctx.owner[item_id]
        local in_disabled = array_contains(ctx.graph.disabled, item_id)
        local stranded = ctx.hidden[item_id]
            or (owner_menu ~= nil and not level_present(owner_menu))
            or (owner_menu == nil
                and persisted_trace(item_id, in_disabled))
        if stranded then
            local home
            if node then
                if node.sorting_hint and level_present(node.sorting_hint) then
                    home = node.sorting_hint
                elseif node.default_parent
                        and level_present(node.default_parent) then
                    home = node.default_parent
                end
            end
            if not home and #ctx.tabs > 0 then
                home = ctx.tabs[1]
            end
            if home then
                local still_hidden = {}
                local removed = false
                for _, id in ipairs(ctx.graph.disabled) do
                    if id == item_id then
                        removed = true
                    else
                        table.insert(still_hidden, id)
                    end
                end
                if removed then
                    ctx.graph.disabled = still_hidden
                    ctx.hidden[item_id] = nil
                end
                ctx.lists[home] = ctx.lists[home] or {}
                table.insert(ctx.lists[home], item_id)
                ctx.owner[item_id] = home
                table.insert(ctx.warnings, string.format(
                    "protected item %s relocated to visible %s "
                        .."(ancestor unreachable)", item_id, home))
            end
        end
    end
end

local function ensureNonEmptyTabBar(ctx)
    -- Stock MenuSorter indexes menu_buttons[1] while placing orphans: an
    -- EMPTY bar crashes the build (and would do so even with our guards,
    -- because the crash is not hint-related). If every tab ended up hidden,
    -- the most recently hidden one is restored as a landing place.
    if #ctx.tabs == 0 then
        local restore_id
        for i = #ctx.graph.disabled, 1, -1 do
            local candidate = ctx.graph.disabled[i]
            if ctx.reg.menus[candidate]
                    or array_contains(ctx.reg.tab_list, candidate) then
                restore_id = candidate
                break
            end
        end
        restore_id = restore_id
            or (ctx.reg.tab_list and ctx.reg.tab_list[1] or nil)
        if restore_id then
            local still_disabled = {}
            for _, id in ipairs(ctx.graph.disabled) do
                if id ~= restore_id then table.insert(still_disabled, id) end
            end
            ctx.graph.disabled = still_disabled
            ctx.hidden[restore_id] = nil
            table.insert(ctx.tabs, restore_id)
            table.insert(ctx.warnings, string.format(
                "empty menu bar: restored %s as landing tab", restore_id))
        end
    end
end

local function collectUnplacedWarnings(ctx)
    -- Items with no valid parent anywhere are silently dropped by stock;
    -- surface them so silent loss is at least observable in the log.
    for _, id in ipairs(ctx.graph.unplaced or {}) do
        table.insert(ctx.warnings, string.format(
            "unplaced item has no valid parent: %s", id))
    end
end

-- Repairs are applied to a fresh copy of graph; returns ok, repaired_graph, warnings.
function Validator.validate(graph, reg, intent)
    reg = reg or { menus = {}, nodes = {}, tab_list = {} }
    graph = graph or { lists = {}, tabs = {}, disabled = {}, unplaced = {}, custom_titles = {} }

    local lists = {}
    for menu_id, list in pairs(graph.lists or {}) do
        local copy = {}
        for _, id in ipairs(list or {}) do table.insert(copy, id) end
        lists[menu_id] = copy
    end
    local tabs = {}
    for _, tab_id in ipairs(graph.tabs or {}) do table.insert(tabs, tab_id) end
    local disabled = {}
    for _, id in ipairs(graph.disabled or {}) do table.insert(disabled, id) end

    local ctx = {
        graph = {
            tabs = tabs,
            lists = lists,
            disabled = disabled,
            custom_titles = graph.custom_titles or {},
            unplaced = graph.unplaced or {},
        },
        reg = reg,
        intent = intent,
        warnings = {},
        lists = lists,
        tabs = tabs,
        hidden = {},
        owner = {},
    }

    repairDuplicateOwnership(ctx)
    breakCycles(ctx)
    removeHiddenRows(ctx)
    removeNestedTabs(ctx)
    hideUnreachableContainers(ctx)
    rebuildOwnership(ctx)
    restoreProtectedItems(ctx)
    ensureNonEmptyTabBar(ctx)
    collectUnplacedWarnings(ctx)

    local repaired = {
        tabs = ctx.tabs,
        lists = ctx.lists,
        disabled = ctx.graph.disabled,
        custom_titles = ctx.graph.custom_titles,
        unplaced = ctx.graph.unplaced,
    }

    return true, repaired, ctx.warnings
end

return Validator

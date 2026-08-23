--[[--
materializer.lua — PURE resolve(base_registry, intent) -> menu graph.

Deterministically derives the complete menu graph from the ephemeral base
registry and one view's sparse intent section. No KOReader UI dependencies,
no persistence, no side effects: identical inputs always produce an
identical graph.

Resolution rules:

  - absent intent  -> follow the CURRENT default placement exactly
  - hidden         -> excluded from every list, collected into disabled
  - parent_override-> wins over the default parent (single-parent model)
  - order_override -> user-curated sequence for one menu level; entries the
                      installation no longer serves stay positionally (so a
                      disabled plugin's row keeps its exact slot), default
                      residents absent from it are slot-aligned, brand-new
                      hinted items append alphabetically; entries era-stamped
                      for another provider are skipped until that provider
                      returns (sequence_eras)
  - position_override / custom .after -> explicit sibling anchoring, honored
                      only while the anchoring provider still serves the id
  - raw_override   -> verbatim passthrough for unrepresentable hand edits

Because placement is computed fresh from live defaults every time, KOReader
and plugin updates flow through untouched menus (and even customized ones)
with zero reconciliation.
--]]

local MenuSchema = require("reorderingmenus_menu_schema")

local Materializer = {}

local SEPARATOR_ID = MenuSchema.SEPARATOR_ID
Materializer.SEPARATOR_ID = SEPARATOR_ID

local RESERVED_KEYS = MenuSchema.RESERVED_KEYS

function Materializer.emptyIntent()
    return MenuSchema.newViewSection()
end

-- -------------------------------------------------------------------------
-- Provider-aware record application
-- -------------------------------------------------------------------------

-- A hidden record keeps applying while its provider is unchanged OR while no
-- live provider serves the id (disabled plugin ghosting). A different live
-- provider releases the stale record.
function Materializer.hiddenApplies(reg, intent, id)
    local record = type(intent) == "table" and intent.hidden and intent.hidden[id] or nil
    if type(record) ~= "table" then return false end
    if record.provider == nil then return true end
    local node = reg.nodes[id]
    local current_provider = node and node.provider or nil
    if current_provider == nil then return true end
    return current_provider == record.provider
end

local function recordApplies(record, current_provider)
    if type(record) ~= "table" then return false end
    if record.provider == nil then return true end
    if current_provider == nil then return true end
    return record.provider == current_provider
end

local function defaultParent(reg, id)
    local node = reg.nodes[id]
    if not node then return nil end
    if node.default_parent then return node.default_parent end
    if node.sorting_hint and reg.menus[node.sorting_hint] then
        return node.sorting_hint
    end
    return nil
end

-- Where does this id live once intent is applied? Exposed for queries.
function Materializer.effectiveParent(reg, intent, id)
    local node = reg.nodes[id]
    local current_provider = node and node.provider or nil
    local record = type(intent) == "table" and intent.parent_override
        and intent.parent_override[id] or nil
    if recordApplies(record, current_provider) then
        local target = record.parent
        local custom_ok = type(intent.custom_menus) == "table"
            and intent.custom_menus[target] ~= nil
        if reg.menus[target] ~= nil or custom_ok
                or target == MenuSchema.MENU_BUTTONS_KEY then
            return target
        end
        -- Invalid target: fall through to the default instead of dropping.
    end
    return defaultParent(reg, id)
end

-- -------------------------------------------------------------------------
-- List assembly
-- -------------------------------------------------------------------------

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do table.insert(keys, k) end
    table.sort(keys)
    return keys
end

local function indexOf(list, value)
    for i, v in ipairs(list) do
        if v == value then return i end
    end
    return nil
end

-- Insert a default resident at its curated stock slot. Anchoring prefers
-- the nearest FOLLOWING default sibling already sequenced (separators are
-- transparent: the row joins the next real row, like upstream's own healing
-- walk), else the nearest preceding one, else appends.
local function insertAtStockSlot(seq, default_list, dindex, id)
    for i = dindex + 1, #default_list do
        if default_list[i] ~= SEPARATOR_ID then
            local anchor_index = indexOf(seq, default_list[i])
            if anchor_index then
                table.insert(seq, anchor_index, id)
                return
            end
        end
    end
    for i = dindex - 1, 1, -1 do
        if default_list[i] ~= SEPARATOR_ID then
            local anchor_index = indexOf(seq, default_list[i])
            if anchor_index then
                table.insert(seq, anchor_index + 1, id)
                return
            end
        end
    end
    table.insert(seq, id)
end

-- Apply one explicit position hint ({after=id|false} / {before=id|false}).
-- NOTE: anchors are slot-exact (immediately after/before the anchor row).
-- Dividers are NOT skipped here: curated restore pins depend on exact
-- adjacency, and stageList's no-op detection compares against the default
-- derivation rather than re-interpreting anchors.
local function applyPositionHint(seq, id, hint)
    local at = indexOf(seq, id)
    if not at then return false end
    local target
    if hint.after == false then
        target = 1
    elseif type(hint.after) == "string" then
        local anchor_at = indexOf(seq, hint.after)
        if not anchor_at then return false end
        target = anchor_at + 1
    elseif hint.before == false then
        return false -- meaningless
    elseif type(hint.before) == "string" then
        local anchor_at = indexOf(seq, hint.before)
        if not anchor_at then return false end
        target = anchor_at
    else
        return false
    end
    if target == at or target == at + 1 then return true end
    table.remove(seq, at)
    if target > at then target = target - 1 end
    table.insert(seq, math.max(1, math.min(target, #seq + 1)), id)
    return true
end

local function positionHintFor(reg, intent, id, customs)
    local record = type(intent.position_override) == "table"
        and intent.position_override[id] or nil
    if type(record) == "table" and (record.after ~= nil or record.before ~= nil) then
        -- Provider-gated: an anchor recorded under another provider's era of
        -- this id must not drag the current provider's item around.
        local node = reg and reg.nodes[id]
        local current_provider = node and node.provider or nil
        if recordApplies(record, current_provider) then
            return record
        end
        return nil
    end
    local custom = customs and customs[id]
    if custom and custom.after ~= nil then return { after = custom.after } end
    return nil
end

local function countSeparatorRecords(intent, menu_id)
    local count = 0
    for _, separator in pairs(type(intent.separators) == "table"
            and intent.separators or {}) do
        if type(separator) == "table" and separator.parent == menu_id then
            count = count + 1
        end
    end
    return count
end

-- Seed a menu from its explicit sequence, or from the previous projection
-- when no sequence exists. Membership and provider-era gates are applied
-- before any current-default residents are merged.
local function seedSequence(ctx, seq, present)
    if ctx.override then
        local era_map = type(ctx.intent.sequence_eras) == "table"
            and ctx.intent.sequence_eras[ctx.menu_id] or nil
        for _, id in ipairs(ctx.override) do
            if id == SEPARATOR_ID then
                table.insert(seq, id)
                present[id] = true
            elseif not ctx.hidden[id] and ctx.members[id] then
                local stale_era = false
                if era_map and era_map[id] ~= nil then
                    local node = ctx.reg.nodes[id]
                    stale_era = node and node.provider ~= nil
                        and node.provider ~= era_map[id]
                end
                if not stale_era then
                    table.insert(seq, id)
                    present[id] = true
                end
            end
        end
        return
    end

    if not ctx.default_list or not ctx.prev_seq or #ctx.prev_seq == 0 then
        return
    end
    for _, id in ipairs(ctx.prev_seq) do
        local separator_taken_over = id == SEPARATOR_ID
            and ctx.separator_record_count > 0
        if not ctx.hidden[id] and not separator_taken_over
                and (id == SEPARATOR_ID or ctx.members[id])
                and ctx.default_set[id] then
            table.insert(seq, id)
            present[id] = true
        end
    end
end

local function mergeDefaultResidents(ctx, seq, present)
    if not ctx.default_list then return end
    for default_index, id in ipairs(ctx.default_list) do
        if id ~= SEPARATOR_ID and type(id) == "string" and not ctx.hidden[id]
                and ctx.members[id] and not present[id] then
            insertAtStockSlot(seq, ctx.default_list, default_index, id)
            present[id] = true
        end
    end
end

local function restoreStockSeparators(ctx, seq)
    if not ctx.default_list or ctx.separator_record_count ~= 0 then return end

    local present_count = 0
    for _, id in ipairs(seq) do
        if id == SEPARATOR_ID then present_count = present_count + 1 end
    end
    local wanted_count = 0
    for _, id in ipairs(ctx.default_list) do
        if id == SEPARATOR_ID then wanted_count = wanted_count + 1 end
    end

    local last_placed_at
    for _, id in ipairs(ctx.default_list) do
        if id == SEPARATOR_ID then
            if present_count < wanted_count and last_placed_at then
                table.insert(seq, math.min(last_placed_at + 1, #seq + 1),
                    SEPARATOR_ID)
                present_count = present_count + 1
                last_placed_at = last_placed_at + 1
            end
        elseif not ctx.hidden[id] then
            local at = indexOf(seq, id)
            if at then last_placed_at = at end
        end
    end
end

local function appendImmigrants(ctx, seq, present)
    local immigrants = {}
    for id in pairs(ctx.members) do
        if not present[id] then table.insert(immigrants, id) end
    end

    local foreigners = {}
    for _, id in ipairs(immigrants) do
        local default_index = ctx.default_list and ctx.default_set[id]
            and indexOf(ctx.default_list, id) or nil
        if default_index then
            insertAtStockSlot(seq, ctx.default_list, default_index, id)
        else
            table.insert(foreigners, id)
        end
    end
    table.sort(foreigners, function(a, b) return tostring(a) < tostring(b) end)
    for _, id in ipairs(foreigners) do
        table.insert(seq, id)
        present[id] = true
    end
end

local function applyExplicitPositionAnchors(ctx, seq)
    local hinted = {}
    for _, id in ipairs(seq) do
        local hint = positionHintFor(ctx.reg, ctx.intent, id, ctx.customs)
        if hint and type(id) == "string" and id ~= SEPARATOR_ID
                and ctx.override then
            for _, sequenced_id in ipairs(ctx.override) do
                if sequenced_id == id then
                    hint = nil -- the whole-menu sequence wins
                    break
                end
            end
        end
        if hint and type(id) == "string" and id ~= SEPARATOR_ID then
            table.insert(hinted, { id = id, hint = hint })
        end
    end
    table.sort(hinted, function(a, b) return a.id < b.id end)
    for _, entry in ipairs(hinted) do
        applyPositionHint(seq, entry.id, entry.hint)
    end
end

local function applyUserSeparators(ctx, seq)
    for _, key in ipairs(sortedKeys(type(ctx.intent.separators) == "table"
            and ctx.intent.separators or {})) do
        local separator = ctx.intent.separators[key]
        if type(separator) == "table" and separator.parent == ctx.menu_id then
            if separator.after == false then
                table.insert(seq, 1, SEPARATOR_ID)
            else
                local anchor_at = type(separator.after) == "string"
                    and indexOf(seq, separator.after)
                table.insert(seq, anchor_at and (anchor_at + 1) or (#seq + 1),
                    SEPARATOR_ID)
            end
        end
    end
end

local function assembleMenuList(reg, intent, menu_id, members, hidden, customs,
                                prev_seq)
    -- Verbatim passthrough for unrepresentable hand edits.
    local raw = type(intent.raw_override) == "table"
        and intent.raw_override[menu_id] or nil
    if type(raw) == "table" and type(raw.list) == "table" then
        local out = {}
        for _, id in ipairs(raw.list) do
            if not hidden[id] then table.insert(out, id) end
        end
        return out
    end

    local default_list = reg.menus[menu_id] and reg.menus[menu_id].list or nil
    local default_set = {}
    for _, id in ipairs(default_list or {}) do default_set[id] = true end
    local ctx = {
        reg = reg,
        intent = intent,
        menu_id = menu_id,
        members = members,
        hidden = hidden,
        customs = customs,
        prev_seq = prev_seq,
        override = type(intent.order_override) == "table"
            and intent.order_override[menu_id] or nil,
        default_list = default_list,
        default_set = default_set,
        separator_record_count = countSeparatorRecords(intent, menu_id),
    }

    local seq, present = {}, {}
    seedSequence(ctx, seq, present)
    mergeDefaultResidents(ctx, seq, present)
    restoreStockSeparators(ctx, seq)
    appendImmigrants(ctx, seq, present)
    applyExplicitPositionAnchors(ctx, seq)
    applyUserSeparators(ctx, seq)
    return seq
end

-- -------------------------------------------------------------------------
-- Graph resolution
-- -------------------------------------------------------------------------

-- resolve(registry, intent[, prev_lists]) -> {
--   tabs          = { ordered visible top-level menu ids },
--   lists         = { [menu_id] = { ordered ids, separators inline } },
--   disabled      = { sorted hidden ids },
--   custom_titles = { [custom_id] = title },
--   unplaced      = { known ids with no valid parent },
--
-- prev_lists (optional) is the previously materialized projection: default
-- residents the previous layout already knew keep their arrangement, while
-- brand-new arrivals are slot-aligned against it like upstream's healer.
function Materializer.resolve(reg, intent, prev_lists)
    intent = intent or Materializer.emptyIntent()

    local hidden = {}
    local disabled = {}
    for id in pairs(intent.hidden or {}) do
        if Materializer.hiddenApplies(reg, intent, id) then
            hidden[id] = true
        end
    end
    -- Editors list hidden rows in the order the user hid them.
    for _, id in ipairs(intent.hidden_order or {}) do
        if hidden[id] then table.insert(disabled, id) end
    end
    local unordered = {}
    local already_listed = {}
    for _, id in ipairs(disabled) do already_listed[id] = true end
    for id in pairs(hidden) do
        if not already_listed[id] then table.insert(unordered, id) end
    end
    table.sort(unordered)
    for _, id in ipairs(unordered) do table.insert(disabled, id) end

    local customs = {}
    for id, record in pairs(intent.custom_menus or {}) do
        if type(record) == "table" then
            customs[id] = {
                title = record.title,
                parent = record.parent,
                after = record.after,
            }
        end
    end

    local function menuExists(menu_id)
        return menu_id ~= nil
            and (reg.menus[menu_id] ~= nil or customs[menu_id] ~= nil
                or menu_id == MenuSchema.MENU_BUTTONS_KEY)
    end

    -- Single-parent membership assignment.
    local members = {}
    local unplaced = {}
    local function assign(id, parent)
        if hidden[id] then return end
        if not parent or not menuExists(parent) then
            table.insert(unplaced, id)
            return
        end
        members[parent] = members[parent] or {}
        members[parent][id] = true
    end

    for id, node in pairs(reg.nodes) do
        assign(id, Materializer.effectiveParent(reg, intent, id))
    end
    -- Ghost entries: ids with persisted placement whose provider is currently
    -- unserved. They keep their configured spot so a plugin reinstall or
    -- re-enable restores them exactly where they were.
    local cascaded_ghosts = {}
    for id in pairs(intent.parent_override or {}) do
        if not reg.nodes[id] then
            local parent = Materializer.effectiveParent(reg, intent, id)
            local record = intent.parent_override[id]
            if parent == nil and recordApplies(record, nil) then
                -- A provider-neutral persisted row whose authored container
                -- disappeared cannot render safely.  Cascade it into the
                -- derived disabled list while retaining its intent record so
                -- restoring the container restores the row.
                hidden[id] = true
                cascaded_ghosts[#cascaded_ghosts + 1] = id
            else
                assign(id, parent)
            end
        end
    end
    table.sort(cascaded_ghosts)
    for _, id in ipairs(cascaded_ghosts) do
        if not already_listed[id] then
            disabled[#disabled + 1] = id
            already_listed[id] = true
        end
    end
    -- Created submenus join their declared parent like any member; their own
    -- contents materialize below regardless of their own visibility.
    for id, custom in pairs(customs) do
        if not hidden[id] then
            assign(id, custom.parent)
        end
    end
    -- A parent_override recorded by a LATER move must win over the
    -- creation-time custom home: moveItemToMenu writes both, but external
    -- imports and legacy data may carry only the override. Customs are not
    -- registry nodes, so the node loop above never consulted their override.
    for id in pairs(intent.parent_override or {}) do
        local custom = customs[id]
        if custom and not hidden[id] then
            local moved = Materializer.effectiveParent(reg, intent, id)
            if moved and moved ~= custom.parent then
                members[custom.parent] = members[custom.parent] or {}
                members[custom.parent][id] = nil
                assign(id, moved)
            end
        end
    end

    -- Top-level tabs.
    local tabs = {}
    local tab_seen = {}
    local base_tabs = intent.tab_order or reg.tab_list
    for _, tab_id in ipairs(base_tabs) do
        if not hidden[tab_id] and not tab_seen[tab_id] then
            table.insert(tabs, tab_id)
            tab_seen[tab_id] = true
        end
    end
    -- Tabs introduced by an update slot in near their default neighbours
    -- instead of always appending: a new tab whose following default sibling
    -- survives in the bar joins it; otherwise it trails its nearest present
    -- predecessor; only when no neighbour survives does it append. This keeps
    -- a curated bar ordered like the updated stock layout rather than
    -- freezing newcomers at the end.
    local function defaultTabIndex(tab_id)
        for i, t in ipairs(reg.tab_list) do
            if t == tab_id then return i end
        end
        return nil
    end
    local arrivals = {}
    for _, tab_id in ipairs(reg.tab_list) do
        if not hidden[tab_id] and not tab_seen[tab_id] then
            table.insert(arrivals, tab_id)
        end
    end
    for _, tab_id in ipairs(arrivals) do
        local dindex = defaultTabIndex(tab_id)
        local placed = false
        if dindex then
            for i = dindex + 1, #reg.tab_list do
                local at = indexOf(tabs, reg.tab_list[i])
                if at then
                    table.insert(tabs, at, tab_id)
                    placed = true
                    break
                end
            end
            if not placed then
                for i = dindex - 1, 1, -1 do
                    local at = indexOf(tabs, reg.tab_list[i])
                    if at then
                        table.insert(tabs, at + 1, tab_id)
                        placed = true
                        break
                    end
                end
            end
        end
        if not placed then
            table.insert(tabs, tab_id)
        end
        tab_seen[tab_id] = true
    end

    -- A user may unhide a tab after an upstream update removed it from the
    -- current default bar.  Unhide records an explicit bar parent with a
    -- provider-neutral stamp when no live node remains; honor that sparse
    -- placement just like parent overrides for ordinary menu rows.
    for _, tab_id in ipairs(sortedKeys(intent.parent_override or {})) do
        if not hidden[tab_id] and not tab_seen[tab_id]
                and Materializer.effectiveParent(reg, intent, tab_id)
                    == MenuSchema.MENU_BUTTONS_KEY then
            table.insert(tabs, tab_id)
            tab_seen[tab_id] = true
        end
    end

    -- Menu levels: stock menus plus created ones plus raw passthroughs.
    local universe = {}
    for menu_id in pairs(reg.menus) do
        if not RESERVED_KEYS[menu_id] then universe[menu_id] = true end
    end
    for menu_id in pairs(customs) do universe[menu_id] = true end
    for menu_id in pairs(members) do
        if not RESERVED_KEYS[menu_id] then universe[menu_id] = true end
    end
    if type(intent.order_override) == "table" then
        for menu_id in pairs(intent.order_override) do
            if not RESERVED_KEYS[menu_id] then universe[menu_id] = true end
        end
    end
    if type(intent.raw_override) == "table" then
        for menu_id in pairs(intent.raw_override) do
            if not RESERVED_KEYS[menu_id] then universe[menu_id] = true end
        end
    end

    local lists = {}
    local empty_members = {}
    for _, menu_id in ipairs(sortedKeys(universe)) do
        lists[menu_id] = assembleMenuList(reg, intent, menu_id,
            members[menu_id] or empty_members, hidden, customs,
            prev_lists and prev_lists[menu_id] or nil)
    end

    local custom_titles = {}
    for id, custom in pairs(customs) do
        custom_titles[id] = custom.title or id
    end

    table.sort(unplaced)

    return {
        tabs = tabs,
        lists = lists,
        disabled = disabled,
        custom_titles = custom_titles,
        unplaced = unplaced,
    }
end

-- Deep structural equality used by the sparse writer: emit a menu key only
-- when the materialized result actually deviates from the pure-default one.
function Materializer.listEquals(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

return Materializer

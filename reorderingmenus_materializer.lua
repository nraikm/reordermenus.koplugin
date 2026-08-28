--[[--
materializer.lua — PURE resolve(base_registry, intent) -> menu graph.

Deterministically derives the complete menu graph from the ephemeral base
registry and one view's sparse intent section. No KOReader UI dependencies,
no persistence, no side effects: identical inputs always produce an
identical graph. HISTORICALLY STATELESS: the output depends only on the
current registry and the current canonical intent - never on previous
projections, cached graphs, or editor history. Clearing every cache,
restarting the process, or replaying a different edit history that arrives
at the same canonical state yields byte-identical output.

Resolution rules (semantic inputs only):

  - absent intent  -> follow the CURRENT default placement exactly
  - hidden         -> excluded from every list, collected into disabled
  - parent_override-> wins over the default parent (single-parent model);
                      ALSO the single parent authority for created submenus
  - order_override -> user-curated sequence for one menu level; each entry
                      carries its own provider stamp, entries the
                      installation no longer serves stay positionally (so a
                      disabled plugin's row keeps its exact slot), default
                      residents absent from it are slot-aligned, brand-new
                      hinted items append alphabetically; entries era-stamped
                      for another provider are skipped until that provider
                      returns (the stamp lives on the entry itself)
  - position_override / custom .after -> explicit sibling anchoring, honored
                      only while the anchoring provider still serves the id
  - raw_override   -> verbatim passthrough for unrepresentable hand edits

Because placement is computed fresh from live defaults every time, KOReader
and plugin updates flow through untouched menus (and even customized ones)
with zero reconciliation, and an explicitly customized item keeps its
recorded intent while its provider's era still applies.
--]]

local MenuSchema = require("reorderingmenus_menu_schema")
local Registry = require("reorderingmenus_registry")

local Materializer = {}

local SEPARATOR_ID = MenuSchema.SEPARATOR_ID
Materializer.SEPARATOR_ID = SEPARATOR_ID

local RESERVED_KEYS = MenuSchema.RESERVED_KEYS

function Materializer.emptyIntent()
    return MenuSchema.newViewSection()
end

-- -------------------------------------------------------------------------
-- Semantic read adapter
-- -------------------------------------------------------------------------
-- The materializer body consumes ONLY these accessors when reading intent.
-- They delegate to the public Materializer.shim (bottom of file), which is
-- the SINGLE seam to remap when the canonical representation changes
-- (Agent A/D handoff): everything downstream consumes the semantic concepts
-- these functions return - explicit anchor / explicit sequence / explicit
-- parent / hidden / default-unmodified.

local function readHiddenRecord(intent, id)
    if type(intent) ~= "table" or type(intent.hidden) ~= "table" then
        return nil
    end
    local record = intent.hidden[id]
    return type(record) == "table" and record or nil
end

-- Deterministic iteration of semantic hidden records: ordinal order (the
-- user's hide sequence), ties broken by id so malformed/migrated data that
-- lacks ordinals still projects identically in every process.
local function eachHiddenRecord(intent, visit)
    for _, entry in Materializer.shim.hiddenRecords(intent) do
        visit(entry.id)
    end
end

-- The explicit sequence for one menu level (nil = level not curated).
-- Sequence entries carry their own provider era: entries stamped for another
-- provider's era of their id are skipped until that provider returns.
local function readOrderEntries(intent, menu_id)
    return Materializer.shim.orderEntries(intent, menu_id)
end

-- The explicit parent record for one id (nil = no explicit parent intent).
local function readParentRecord(intent, id)
    return Materializer.shim.explicitParent(intent, id)
end

-- The explicit sibling anchor for one id (nil = no explicit slot intent).
local function readPositionRecord(intent, id)
    return Materializer.shim.positionAnchor(intent, id)
end

-- -------------------------------------------------------------------------
-- Provider-aware record application
-- -------------------------------------------------------------------------

-- A hidden record applies when the provider is present and matches the record stamp
-- (or for unstamped records on live nodes). Stamped records for absent providers are dormant.
function Materializer.hiddenApplies(reg, intent, id)
    local record = readHiddenRecord(intent, id)
    if not record then return false end
    if record.provider == nil then return true end
    local node = reg.nodes[id]
    local current_provider = node and node.provider or nil
    if current_provider == nil then return false end
    return current_provider == record.provider
end

local function recordApplies(record, current_provider)
    if type(record) ~= "table" then return false end
    if record.provider == nil then return true end
    if current_provider == nil then return false end
    return record.provider == current_provider
end

local function defaultParent(reg, id)
    return Registry.getDefaultParent(reg, id)
end

-- Where does this id live once intent is applied? Exposed for queries.
function Materializer.effectiveParent(reg, intent, id)
    local node = reg.nodes[id]
    local is_custom = type(intent.custom_menus) == "table"
        and intent.custom_menus[id] ~= nil
    local current_provider = node and node.provider or (is_custom and "custom" or nil)
    local record = readParentRecord(intent, id)
    local applies = false
    if record then
        if is_custom then
            applies = (record.provider == nil or record.provider == "custom")
        else
            applies = recordApplies(record, current_provider)
        end
    end
    if applies then
        return record.parent
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
    local record = readPositionRecord(intent, id)
    if record and (record.after ~= nil or record.before ~= nil) then
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

-- Seed a menu from its explicit sequence, if any. Membership and provider-
-- era gates are applied before any current-default residents are merged.
-- History-independence (P0 semantic rule): there is deliberately NO fallback
-- seeding from a previous projection. Untouched items reach their placement
-- through mergeDefaultResidents (current provider default), customized ones
-- through this explicit sequence - a prior projection must never become
-- implicit intent, or restart-equivalence breaks by construction.
local function seedSequence(ctx, seq, present)
    local entries = readOrderEntries(ctx.intent, ctx.menu_id)
    if not entries then return end
    for _, entry in ipairs(entries) do
        if MenuSchema.isSeparatorEntry(entry) then
            table.insert(seq, SEPARATOR_ID)
            present[SEPARATOR_ID] = true
        elseif not ctx.hidden[entry.id] and ctx.members[entry.id] then
            -- Era gate: the entry applies only while its recorded provider
            -- still serves the id (unstamped entries always apply).
            if recordApplies(entry, ctx.reg.nodes[entry.id]
                    and ctx.reg.nodes[entry.id].provider or nil) then
                table.insert(seq, entry.id)
                present[entry.id] = true
            end
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

local function rewriteSeq(seq, items)
    for i = #seq, 1, -1 do seq[i] = nil end
    for i, id in ipairs(items) do seq[i] = id end
end

-- Stock-divider normalization, shared by every path (explicit sequence,
-- default-resident merge, immigrant append): strip any inline dividers the
-- seed carried, then re-insert each current-default divider slot exactly
-- once, immediately after the nearest preceding LIVE default item. A divider
-- slot whose preceding group is entirely hidden stays absent - matching what
-- a cold rebuild produces. When user separator RECORDS exist for this menu
-- the records own divider placement entirely (applyUserSeparators runs
-- below): stock dividers are stripped there too, so every derivation of the
-- same canonical state lands on the same arrangement.
local function restoreStockSeparators(ctx, seq)
    if not ctx.default_list then return end

    local items = {}
    for _, id in ipairs(seq) do
        if id ~= SEPARATOR_ID then table.insert(items, id) end
    end
    rewriteSeq(seq, items)

    if ctx.separator_record_count ~= 0 then
        return
    end

    local last_placed_at
    for _, id in ipairs(ctx.default_list) do
        if id == SEPARATOR_ID then
            -- A divider slot with no live predecessor (everything before it
            -- hidden) stays absent: the fresh-session rebuild drops it too.
            if last_placed_at then
                table.insert(seq, last_placed_at + 1, SEPARATOR_ID)
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
    -- Determinism discipline: multiple unplaced members landing in ONE menu
    -- interact through insertAtStockSlot's anchors, so their arrival order
    -- must never depend on the process's table-iteration seed. Sorted order
    -- gives every process (and every replay) the same final arrangement.
    table.sort(immigrants, function(a, b) return tostring(a) < tostring(b) end)
    local foreigners = {}
    for _, id in ipairs(immigrants) do
        local default_index = ctx.default_index and ctx.default_index[id] or nil
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
        if hint and type(id) == "string" and id ~= SEPARATOR_ID then
            -- Whole-menu curated sequence takes precedence over single-item hint
            if not (ctx.sequenced_set and ctx.sequenced_set[id]) then
                table.insert(hinted, { id = id, hint = hint })
            end
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

local function assembleMenuList(reg, intent, menu_id, members, hidden, customs)
    -- Verbatim passthrough for unrepresentable hand edits.
    local raw = type(intent.raw_override) == "table"
        and intent.raw_override[menu_id] or nil
    if type(raw) == "table" and type(raw.list) == "table" then
        local out = {}
        local in_raw = {}
        for _, id in ipairs(raw.list) do
            in_raw[id] = true
            if not hidden[id] then
                if reg.nodes[id] then
                    if members[id] then
                        table.insert(out, id)
                    end
                else
                    local p_rec = readParentRecord(intent, id)
                    if not p_rec or p_rec.parent == menu_id then
                        table.insert(out, id)
                    end
                end
            end
        end
        local extra = {}
        for id in pairs(members) do
            if not hidden[id] and not in_raw[id] then
                table.insert(extra, id)
            end
        end
        table.sort(extra)
        for _, id in ipairs(extra) do
            table.insert(out, id)
        end
        return out
    end

    local default_list = reg.menus[menu_id] and reg.menus[menu_id].list or nil
    local default_set = {}
    local default_index = {}
    for idx, id in ipairs(default_list or {}) do
        if id ~= SEPARATOR_ID and type(id) == "string" then
            default_set[id] = true
            if not default_index[id] then default_index[id] = idx end
        end
    end

    local override_entries = readOrderEntries(intent, menu_id)
    local sequenced_set = {}
    if override_entries then
        for _, entry in ipairs(override_entries) do
            local eid = MenuSchema.entryId(entry)
            if eid and eid ~= SEPARATOR_ID then
                sequenced_set[eid] = true
            end
        end
    end

    local ctx = {
        reg = reg,
        intent = intent,
        menu_id = menu_id,
        members = members,
        hidden = hidden,
        customs = customs,
        override = override_entries,
        sequenced_set = sequenced_set,
        default_list = default_list,
        default_set = default_set,
        default_index = default_index,
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

-- History-independence (P0): resolve consumes ONLY the current registry and
-- canonical intent. The third parameter is gone - callers that previously
-- passed a previous projection now get identical semantics by omitting it.
function Materializer.resolve(reg, intent)
    intent = intent or Materializer.emptyIntent()

    -- Semantic hidden records, in deterministic (ordinal, id) order via the
    -- read adapter: applicable ones leave every list; the same sequence
    -- becomes the derived disabled list.
    local hidden = {}
    local disabled = {}
    eachHiddenRecord(intent, function(id)
        if Materializer.hiddenApplies(reg, intent, id) then
            hidden[id] = true
            table.insert(disabled, id)
        end
    end)

    local customs = {}
    -- Canonical accessor: creation records (title + optional placement hint
    -- `after`); parent authority is NOT here - it lives in parent_override.
    for id, record in pairs(type(intent.custom_menus) == "table"
            and intent.custom_menus or {}) do
        if type(record) == "table" then
            customs[id] = {
                title = record.title,
                after = record.after,
            }
        end
    end

    local function menuExists(menu_id)
        return menu_id ~= nil
            and (reg.menus[menu_id] ~= nil or customs[menu_id] ~= nil
                or menu_id == MenuSchema.MENU_BUTTONS_KEY
                or (type(intent.raw_override) == "table" and intent.raw_override[menu_id] ~= nil))
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
    -- Unstamped items (test fixtures / mock objects) that are not in reg.nodes
    for id, record in pairs(intent.parent_override or {}) do
        if not reg.nodes[id] and not customs[id] and not hidden[id] then
            if type(record) == "table" and record.provider == nil then
                assign(id, Materializer.effectiveParent(reg, intent, id))
            end
        end
    end
    if type(intent.order_override) == "table" then
        for menu_id in pairs(intent.order_override) do
            local entries = readOrderEntries(intent, menu_id)
            if entries then
                for _, entry in ipairs(entries) do
                    local eid = MenuSchema.entryId(entry)
                    local stamp = type(entry) == "table" and entry.provider or nil
                    if eid and eid ~= SEPARATOR_ID and stamp == nil and not reg.nodes[eid]
                            and not customs[eid] and not hidden[eid]
                            and not readParentRecord(intent, eid) then
                        assign(eid, menu_id)
                    end
                end
            end
        end
    end
    -- Created submenus join the parent recorded in parent_override - the
    -- SINGLE parent authority for customs (schema v3 folded
    -- custom_menus.parent away).
    for id in pairs(customs) do
        if not hidden[id] then
            assign(id, Materializer.effectiveParent(reg, intent, id))
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
    local default_tab_index = {}
    for i, t in ipairs(reg.tab_list or {}) do
        if not default_tab_index[t] then
            default_tab_index[t] = i
        end
    end

    local arrivals = {}
    for _, tab_id in ipairs(reg.tab_list or {}) do
        if not hidden[tab_id] and not tab_seen[tab_id] then
            table.insert(arrivals, tab_id)
        end
    end
    for _, tab_id in ipairs(arrivals) do
        local dindex = default_tab_index[tab_id]
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
    -- Explicit sequences and raw passthroughs only claim levels that still
    -- EXIST in the current registry or among custom containers: a record
    -- naming a vanished level describes placement inside a world upstream
    -- removed, so it must not resurrect the level as an empty phantom (the
    -- oracle reads order[level] ~= nil as "reachable" - and an empty level
    -- is not a user-visible arrangement anyway). Dormant records stay in
    -- canonical intent untouched and reapply when the level returns.
    if type(intent.order_override) == "table" then
        for menu_id in pairs(intent.order_override) do
            if not RESERVED_KEYS[menu_id] and (reg.menus[menu_id]
                    or customs[menu_id]) then
                universe[menu_id] = true
            end
        end
    end
    if type(intent.raw_override) == "table" then
        for menu_id in pairs(intent.raw_override) do
            if not RESERVED_KEYS[menu_id] and (reg.menus[menu_id]
                    or customs[menu_id]) then
                universe[menu_id] = true
            end
        end
    end

    local lists = {}
    local empty_members = {}
    for _, menu_id in ipairs(sortedKeys(universe)) do
        lists[menu_id] = assembleMenuList(reg, intent, menu_id,
            members[menu_id] or empty_members, hidden, customs)
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

-- -------------------------------------------------------------------------
-- Canonical read seam (P1A integration: delegates to menu_schema v3)
--
-- The materializer body consumes ONLY these accessors when reading intent.
-- They are thin delegations onto MenuSchema's accessor surface - the schema
-- module owns every physical-storage detail (record shapes, ordinal
-- ordering, separator tokens); this seam owns only the SEMANTIC concepts
-- downstream projection consumes:
--
--   Materializer.shim.hiddenRecords(intent)
--       -> iterator over {id=..., ordinal=number|nil} in hide order,
--          ordinal-less/malformed records sorted by id (deterministic).
--   Materializer.shim.orderEntries(intent, menu_id)
--       -> array of entries, each either {separator=true} or
--          {id=string, provider=string|nil}, in curated order; nil when the
--          level carries no explicit sequence.
--   Materializer.shim.explicitParent(intent, id)
--       -> {provider=..., parent=...}|nil - the single parent-authority
--          record for an item or created submenu.
--   Materializer.shim.positionAnchor(intent, id)
--       -> {provider=..., after=...}|{after=false}|nil sibling anchor.
--   Materializer.shim.customMenus(intent)
--       -> map id -> {title=...} for user-created containers.
-- -------------------------------------------------------------------------
Materializer.shim = {
    hiddenRecords = function(intent)
        local section = type(intent) == "table" and intent or {}
        -- Canonical accessor: hide-order iteration lives in menu_schema
        -- (per-record ordinals, id tiebreak for migrated/malformed data).
        local ordered_ids = MenuSchema.orderedHiddenIds(section)
        local ordered = {}
        for index, id in ipairs(ordered_ids) do
            local record = type(section.hidden) == "table"
                and type(section.hidden[id]) == "table"
                and section.hidden[id] or {}
            ordered[index] = {
                id = id,
                ordinal = (type(record.ordinal) == "number")
                    and record.ordinal or math.huge,
            }
        end
        return ipairs(ordered)
    end,

    orderEntries = function(intent, menu_id)
        local section = type(intent) == "table" and intent or {}
        -- Canonical accessor: combined order record (entries carry their own
        -- era stamps; separator tokens are typed entries).
        local record = MenuSchema.getOrderRecord(section, menu_id)
        return record and record.entries or nil
    end,

    explicitParent = function(intent, id)
        local section = type(intent) == "table" and intent or {}
        return MenuSchema.getParentOverrideRecord(section, id)
    end,

    positionAnchor = function(intent, id)
        local section = type(intent) == "table" and intent or {}
        return MenuSchema.getPositionOverrideRecord(section, id)
    end,

    customMenus = function(intent)
        local section = type(intent) == "table" and intent or {}
        -- Titles only; parent authority lives in explicitParent.
        local titles = MenuSchema.customMenuTitles(section)
        local present = type(section.custom_menus) == "table"
            and next(section.custom_menus) ~= nil or false
        return titles, present
    end,
}

return Materializer

-- Shared names, constructors, and predicates for the KOReader menu-order
-- data model (canonical schema v3).
--
-- This module intentionally contains only plain constants and fresh-table
-- constructors. It is safe for pure domain modules to require: it performs no
-- I/O and has no dependency on KOReader runtime objects.
--
-- NOTE ON PROVENANCE (P1A, 2026-08-24): the v3 canonical shapes in this file
-- were converged between two parallel sessions that both implemented parts of
-- the consolidation. The record shapes below are the single agreed truth:
--   hidden[id]           = { provider?, origin?, ordinal }        ONE record
--   order_override[menu] = { entries = [ {id, provider?} ] }
--   parent_override[id]  = { provider?, parent }   <- custom-menu parent authority
--   custom_menus[id]     = { title, after? }
-- Earlier drafts that kept hidden_order / sequence_eras / ui_state anchors or
-- a custom_menus.parent field are superseded by THIS file.

local MenuSchema = {}

MenuSchema.SCHEMA_VERSION = 3

MenuSchema.SEPARATOR_ID = "----------------------------"
MenuSchema.MENU_BUTTONS_KEY = "KOMenu:menu_buttons"
MenuSchema.DISABLED_KEY = "KOMenu:disabled"
MenuSchema.CUSTOM_SUBMENUS_KEY = "KOMenu:custom_submenus"

MenuSchema.VIEWS = { "reader", "filemanager" }

function MenuSchema.isCanonicalView(view)
    return view == "reader" or view == "filemanager"
end

MenuSchema.ORDERING_MODE = {
    RAW = "raw",
    SEMANTIC = "semantic",
    DEFAULT = "default",
}

MenuSchema.NODE_TYPE = {
    TAB = "tab",
    SUBMENU = "submenu",
    ITEM = "item",
}

MenuSchema.PROVIDER_STOCK = "stock"

MenuSchema.PROTECTED_ITEMS = {
    reordering_menus = true,
}

MenuSchema.PROTECTED_TABS = {
    tools = true,
}

-- Canonical view-section collections (schema v3).
--
--   hidden[id]           one record per deliberately invisible id:
--                          { provider?, origin?, ordinal }
--                          - origin    where it came from when hidden
--                            (provider disappearance / return / ghost
--                            restoration all key off this + provider)
--                          - ordinal   position among hidden rows; the old
--                            parallel hidden_order list lives on the record
--   parent_override[id]  { provider?, parent }   explicit move of an item;
--                        THE single authority for a custom submenu's parent
--                        too (creation-time homes are folded here)
--   position_override[id]{ provider?, after|before } sparse single-item slot
--   order_override[menu] ONE record: entries = array of
--                          { id = string, provider? = era stamp }.
--                        Per-entry era stamps travel with their entry, so no
--                        parallel sequence_eras map can drift.
--   custom_menus[id]     { title, after? } user-created submenu. Parent lives
--                        ONLY in parent_override[id].
--   separators[key]      { parent, after } THE canonical authority for
--                        user-inserted dividers.
--   raw_override[menu]   { list = {...} } verbatim passthrough; installing
--                        one clears that level's semantic records.
--
-- tab_order stays a plain array on the section.
MenuSchema.VIEW_COLLECTIONS = {
    "hidden",
    "parent_override",
    "position_override",
    "order_override",
    "custom_menus",
    "separators",
    "raw_override",
}

MenuSchema.MAP_COLLECTIONS = MenuSchema.VIEW_COLLECTIONS
MenuSchema.SEQUENCE_FIELDS = { "tab_order" }

MenuSchema.VIEW_COLLECTION_SET = {}
for _, name in ipairs(MenuSchema.VIEW_COLLECTIONS) do
    MenuSchema.VIEW_COLLECTION_SET[name] = true
end

-- Collections whose records carry a provider stamp ({provider=...}).
MenuSchema.PROVIDER_STAMPED_COLLECTIONS = {
    hidden = true,
    parent_override = true,
    position_override = true,
}

-- Explicitly typed NON-user intent markers. Lifecycle pins written by
-- registration / import reconciliation (`record.anchor == true` on
-- parent_override / position_override records) keep placements durable
-- across provider churn; they are NOT user customization for isCustomized
-- purposes. Schema v3 migration strips them from persisted state; this table
-- remains the recognition contract for any writer that re-introduces pins.
MenuSchema.LIFECYCLE_PIN_KINDS = {
    anchor = true,
}

MenuSchema.RESERVED_KEYS = {
    [MenuSchema.MENU_BUTTONS_KEY] = true,
    [MenuSchema.DISABLED_KEY] = true,
    [MenuSchema.CUSTOM_SUBMENUS_KEY] = true,
}

function MenuSchema.newViewSection()
    return {
        hidden = {},
        parent_override = {},
        position_override = {},
        -- [menu_id] = { entries = {...} }; nil entry = follow defaults.
        -- Entries are { id, provider? }; eras ride the entry. Historical
        -- inline separator tokens are accepted only at migration boundaries.
        order_override = {},
        custom_menus = {},
        separators = {},
        raw_override = {},
        tab_order = nil,
    }
end

--- The single authoritative constructor for a blank canonical root document (v3).
function MenuSchema.newCanonicalState()
    local views = {}
    local view_generations = {}
    for _, view in ipairs(MenuSchema.VIEWS) do
        views[view] = MenuSchema.newViewSection()
        view_generations[view] = 0
    end
    return {
        version = MenuSchema.SCHEMA_VERSION,
        views = views,
        meta = {
            mirror_changes = false,
            hidden_in_place = true,
            generation = 0,
            view_generations = view_generations,
        },
    }
end

MenuSchema.newEmptyCanonicalState = MenuSchema.newCanonicalState

-- -------------------------------------------------------------------------
-- Typed record constructors / predicates (the semantic accessor surface)
-- -------------------------------------------------------------------------

--- One consolidated hidden record. Membership, restore origin, and hide
--- ordering travel together, so hidden membership and its metadata cannot
--- become independently inconsistent by construction.
function MenuSchema.newHiddenRecord(fields)
    fields = type(fields) == "table" and fields or {}
    return {
        provider = fields.provider,
        origin = type(fields.origin) == "string" and fields.origin or nil,
        ordinal = fields.ordinal,
    }
end

--- Historical inline separator token constructor. Current canonical writers
--- use the `separators` collection exclusively; retained for migration/tests.
function MenuSchema.newSeparatorEntry()
    return { separator = true }
end

--- One combined order record from a plain id sequence + optional per-id era
--- map. Separators are deliberately omitted: callers persist them through the
--- canonical anchored `separators` collection.
function MenuSchema.newOrderRecord(sequence, eras)
    local rec = { entries = {} }
    if type(sequence) ~= "table" then return rec end
    local seen = {}
    for _, id in ipairs(sequence) do
        if id ~= MenuSchema.SEPARATOR_ID and not seen[id] then
            seen[id] = true
            local era = type(eras) == "table" and eras[id] or nil
            if era ~= nil then
                rec.entries[#rec.entries + 1] = { id = id, provider = era }
            else
                rec.entries[#rec.entries + 1] = { id = id }
            end
        end
    end
    return rec
end

--- Is this a historical inline separator token?
function MenuSchema.isSeparatorEntry(entry)
    return type(entry) == "table" and entry.separator == true
end

--- The id of an order_override entry (separator tokens report SEPARATOR_ID
--- so generic iteration can treat every entry uniformly); nil for garbage.
function MenuSchema.entryId(entry)
    if type(entry) ~= "table" then return nil end
    if entry.separator == true then return MenuSchema.SEPARATOR_ID end
    return type(entry.id) == "string" and entry.id or nil
end

--- True when the record is lifecycle bookkeeping rather than explicit user
--- intent. Recognizes the historical boolean marker and the typed kind
--- names; anything else falls back to "user intent".
function MenuSchema.isLifecyclePin(record)
    if type(record) ~= "table" then return false end
    if record.anchor == true then return true end
    return MenuSchema.LIFECYCLE_PIN_KINDS[record.anchor] == true
end

--- Does this view section carry any EXPLICIT USER customization?
--- Derived artifacts (native files, sidecars, stale checkpoints), lifecycle
--- pins, and pure display bookkeeping are not customization.
function MenuSchema.sectionHasUserIntent(section)
    if type(section) ~= "table" then return false end
    local function map_has(name)
        local coll = section[name]
        if type(coll) ~= "table" then return false end
        return next(coll) ~= nil
    end
    if map_has("hidden") then return true end
    for _, record in pairs(type(section.parent_override) == "table"
            and section.parent_override or {}) do
        if type(record) == "table" and not MenuSchema.isLifecyclePin(record) then
            return true
        end
    end
    for _, record in pairs(type(section.position_override) == "table"
            and section.position_override or {}) do
        if type(record) == "table" and not MenuSchema.isLifecyclePin(record) then
            return true
        end
    end
    if map_has("order_override") then return true end
    if map_has("custom_menus") then return true end
    if map_has("separators") then return true end
    if map_has("raw_override") then return true end
    if section.tab_order ~= nil then return true end
    return false
end

-- -------------------------------------------------------------------------
-- Semantic accessor surface (small, documented; consumed by materializer /
-- import code so those layers stop knowing every physical storage detail)
-- -------------------------------------------------------------------------

--- Iterate hidden records: fn(id, record); returns number visited.
function MenuSchema.eachHiddenRecord(section, fn)
    local n = 0
    for id, record in pairs(type(section.hidden) == "table"
            and section.hidden or {}) do
        if type(record) == "table" then
            n = n + 1
            fn(id, record)
        end
    end
    return n
end

--- Hidden ids ordered by their per-record ordinal (the old hidden_order read
--- path). Ties break on id for cross-process determinism.
function MenuSchema.orderedHiddenIds(section)
    local entries = {}
    for id, record in pairs(type(section.hidden) == "table"
            and section.hidden or {}) do
        if type(record) == "table" then
            entries[#entries + 1] = {
                id = id,
                ordinal = (type(record.ordinal) == "number")
                    and record.ordinal or math.huge,
            }
        end
    end
    table.sort(entries, function(a, b)
        if a.ordinal ~= b.ordinal then return a.ordinal < b.ordinal end
        return tostring(a.id) < tostring(b.id)
    end)
    local out = {}
    for _, e in ipairs(entries) do out[#out + 1] = e.id end
    return out
end

--- Next free hidden-ordinal counter value (monotonic per view section).
function MenuSchema.nextHiddenOrdinal(section)
    local max_ordinal = 0
    for _, record in pairs(type(section.hidden) == "table"
            and section.hidden or {}) do
        if type(record) == "table" and type(record.ordinal) == "number"
                and record.ordinal > max_ordinal then
            max_ordinal = record.ordinal
        end
    end
    return max_ordinal + 1
end

--- The explicit parent of a CUSTOM submenu id, or nil. Custom-menu parent
--- authority lives ONLY in parent_override; callers must never consult
--- custom_menus for placement.
function MenuSchema.getCustomParent(section, submenu_id)
    local overrides = type(section.parent_override) == "table"
        and section.parent_override or {}
    local record = overrides[submenu_id]
    if type(record) == "table" and type(record.parent) == "string" then
        return record.parent
    end
    return nil
end

--- Ordering mode for one menu level:
---   raw      -> verbatim passthrough wins exclusively
---   semantic -> curated sequence (+ per-entry era stamps)
---   default  -> no explicit ordering
--- Mutators keep raw and semantic mutually exclusive; validation flags any
--- on-disk contradiction for repair (raw wins, passthrough semantics first).
function MenuSchema.orderingMode(section, menu_id)
    local has_raw = type(section.raw_override) == "table"
        and section.raw_override[menu_id] ~= nil
    local has_semantic = type(section.order_override) == "table"
        and section.order_override[menu_id] ~= nil
    if has_raw then return "raw", has_semantic and "conflict" or nil end
    if has_semantic then return "semantic" end
    return "default"
end

--- The combined order record for a menu level (nil = no explicit ordering).
function MenuSchema.getOrderRecord(section, menu_id)
    if type(section.order_override) ~= "table" then return nil end
    local rec = section.order_override[menu_id]
    if type(rec) == "table" and type(rec.entries) == "table" then return rec end
    return nil
end

--- Era/provider-applicability of ONE sequence entry (per-entry stamps live
--- on the entry itself; unstamped entries always apply).
function MenuSchema.entryEra(entry)
    if type(entry) == "table" and type(entry.provider) == "string" then
        return entry.provider
    end
    return nil
end

--- Provider applicability of any stamped record (shared semantics with
--- IntentStore.recordApplies, available without loading the store).
function MenuSchema.recordApplies(record, current_provider)
    if type(record) ~= "table" then return false end
    if record.provider == nil then return true end
    return record.provider == current_provider
end

--- The raw parent-authority record for an id, if any ({ provider?, parent }).
function MenuSchema.getParentOverrideRecord(section, id)
    local overrides = type(section.parent_override) == "table"
        and section.parent_override or {}
    local record = overrides[id]
    return type(record) == "table" and record or nil
end

--- The raw sibling-anchor record for an id, if any ({ provider?, after|before }).
function MenuSchema.getPositionOverrideRecord(section, id)
    local overrides = type(section.position_override) == "table"
        and section.position_override or {}
    local record = overrides[id]
    return type(record) == "table" and record or nil
end

--- Titles of user-created submenus as { [id] = { title } }; placement never
--- lives here (parent authority is parent_override) so only titles are copied.
function MenuSchema.customMenuTitles(section)
    local titles = {}
    local menus = type(section.custom_menus) == "table"
        and section.custom_menus or {}
    for id, record in pairs(menus) do
        if type(record) == "table" then
            titles[id] = { title = record.title }
        end
    end
    return titles
end

--- Explicit placement of one id, if any: { kind = "position", record } for
--- sparse anchors, { kind = "sequence", menu_id } for rows governed by a
--- curated sequence, else nil. reg_parent_of is an optional callback
--- (typically Materializer.effectiveParent partially applied).
function MenuSchema.getExplicitPlacement(section, reg_parent_of, id)
    local pos = type(section.position_override) == "table"
        and section.position_override[id] or nil
    if type(pos) == "table" and (pos.after ~= nil or pos.before ~= nil) then
        return { kind = "position", record = pos }
    end
    if type(reg_parent_of) == "function" then
        local parent = reg_parent_of(id)
        if parent ~= nil
                and type(section.order_override) == "table"
                and section.order_override[parent] ~= nil then
            return { kind = "sequence", menu_id = parent }
        end
    end
    return nil
end

return MenuSchema

-- Tombstone garbage collection: an explicit user action that drops records
-- for ids no live provider serves, so a future reinstall starts from CURRENT
-- provider defaults instead of resurrecting pre-uninstall customizations.
--
-- Semantics (deliberately narrower than resetView):
--   - ONLY records whose id is unknown to the live registry are dropped.
--     Customizations of ids still served by KOReader/plugins are never
--     touched.
--   - Ghost entries inside bulk sequences are NOT removed here: dropping a
--     row from a curated sequence would renumber neighbours; instead the
--     sequence is left intact and its era stamps keep gating application.
--   - Returns the list of forgotten ids per view for UI confirmation.

local IntentStore = require("lib.intent_store")

local GhostGC = {}

-- Which collections hold per-id records subject to GC. Schema v3: sequence
-- eras ride order_override entries, so both old parallel maps are gone.
local GC_COLLECTIONS = {
    "hidden",
    "parent_override",
    "position_override",
    "custom_menus",
}

-- Count stale records for one view without mutating anything.
--
-- Identity rule: an id is stale only when NO live provider serves it AND it
-- is not a user-CREATED submenu (custom submenus are never registry nodes -
-- they are the user's own data, not a provider's contribution - so they must
-- never be offered to or destroyed by GC).
function GhostGC.countStaleIds(view, reg)
    local section = IntentStore.view(view)
    local custom_menus = type(section.custom_menus) == "table"
        and section.custom_menus or {}
    local function is_stale(id)
        return reg.nodes[id] == nil and custom_menus[id] == nil
    end
    local stale = {}
    for _, coll_name in ipairs(GC_COLLECTIONS) do
        if coll_name ~= "custom_menus" then
            local coll = section[coll_name]
            if type(coll) == "table" then
                for id in pairs(coll) do
                    if is_stale(id) then stale[id] = true end
                end
            end
        end
    end
    -- Ghost SUBMENU levels: their customization lives under order_override /
    -- raw_override keyed BY the ghost id, and dividers parented INSIDE the
    -- level, so neither is covered by the per-id collections above.
    if type(section.order_override) == "table" then
        for menu_id in pairs(section.order_override) do
            if is_stale(menu_id) then stale[menu_id] = true end
        end
    end
    if type(section.raw_override) == "table" then
        for menu_id in pairs(section.raw_override) do
            if is_stale(menu_id) then stale[menu_id] = true end
        end
    end
    if type(section.separators) == "table" then
        for _, sep in pairs(section.separators) do
            if type(sep) == "table" and type(sep.parent) == "string"
                    and is_stale(sep.parent) then
                stale[sep.parent] = true
            end
        end
    end
    local out = {}
    for id in pairs(stale) do table.insert(out, id) end
    table.sort(out)
    return out
end

-- Drop every customization record for `ids` in one view. Runs through a
-- transaction so the write is all-or-nothing with generation bumping.
function GhostGC.forgetIds(view, txn, ids)
    local forgotten = 0
    for _, id in ipairs(ids) do
        -- A forgotten GHOST may itself be a (hand-authored or created)
        -- SUBMENU: its level is keyed BY the ghost id, so clear its whole
        -- sequence and era map too - clearItem only strips the id FROM
        -- other levels' sequences.
        txn:setOrderOverride(view, id, nil)
        -- Divider records parented INSIDE the forgotten level are dead
        -- bookkeeping once the level goes; leaving them behind would
        -- resurrect dividers if a future provider ever reused the id as a
        -- menu key again.
        for key in pairs(txn:view(view).separators or {}) do
            local sep = txn:view(view).separators[key]
            if type(sep) == "table" and sep.parent == id then
                txn:setSeparator(view, key, nil)
            end
        end
        txn:clearItem(view, id)
        txn:setCustomMenu(view, id, nil)
        -- clearItem covers hidden/parent/position/sequence membership;
        -- raw_override levels keyed BY such ids (hand-authored submenus)
        -- also need removal:
        txn:setRawOverride(view, id, nil)
        forgotten = forgotten + 1
    end
    return forgotten
end

return GhostGC

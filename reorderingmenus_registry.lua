--[[--
registry.lua — builds the ephemeral BASE REGISTRY.

The registry captures what exists RIGHT NOW, before any user customization:

  - every stock item/submenu/tab from the current KOReader defaults
  - every live contribution from installed plugins and widgets, including
    its sorting_hint

Nothing here is persisted. Each entry records:

    id              -- menu id
    provider        -- "stock" | "plugin:<name>" | nil (unattributed)
    default_parent  -- menu the CURRENT defaults place it in (hint-resolved)
    default_index   -- 1-based slot inside that parent's default list
    sorting_hint    -- provider-requested anchor, when unanchored by defaults
    node_type       -- "tab" | "submenu" | "item"
    available       -- true: served by the running installation

Items whose provider disappeared are simply absent; their persisted intent
survives in the intent store until they return.
--]]

local MenuSchema = require("reorderingmenus_menu_schema")
local ok_util, util = pcall(require, "util")

local function deepCopy(t)
    if ok_util and util and util.tableDeepCopy then
        return util.tableDeepCopy(t)
    end
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do copy[k] = deepCopy(v) end
    return copy
end

local Registry = {}

local RESERVED_KEYS = MenuSchema.RESERVED_KEYS

Registry.RESERVED_KEYS = RESERVED_KEYS

-- Pure constructor: build the registry from explicit inputs (tests inject
-- these; production resolves them through koreader_adapter). Signature:
--   buildFromData(defaults, registrations, providers, collisions)
--     defaults       view -> ordered id list (stock layout)
--     registrations  id -> { sorting_hint = ... } live contributions
--     providers      id -> widget name (attribution)
--     collisions     id -> { sorted widget names } (>1 entry = contested)
function Registry.buildFromData(defaults, registrations, providers, collisions)
    local reg = {
        menus = {},
        tab_list = deepCopy(defaults[MenuSchema.MENU_BUTTONS_KEY] or {}),
        nodes = {},
    }

    local menu_ids = {}
    for menu_id, list in pairs(defaults) do
        if not RESERVED_KEYS[menu_id] and type(list) == "table" then
            table.insert(menu_ids, menu_id)
        end
    end
    table.sort(menu_ids)
    for _, menu_id in ipairs(menu_ids) do
        reg.menus[menu_id] = {
            list = deepCopy(defaults[menu_id]),
            is_tab = false,
        }
    end
    for _, tab_id in ipairs(reg.tab_list) do
        if reg.menus[tab_id] then
            reg.menus[tab_id].is_tab = true
        else
            reg.menus[tab_id] = { list = {}, is_tab = true }
        end
    end

    local function addNode(id, provider, default_parent, default_index, hint, node_type)
        if reg.nodes[id] then return reg.nodes[id] end
        reg.nodes[id] = {
            id = id,
            provider = provider,
            default_parent = default_parent,
            default_index = default_index,
            sorting_hint = hint,
            node_type = node_type,
            available = true,
        }
        return reg.nodes[id]
    end

    -- Stock entries first: identity and placement come from the shipped
    -- layout. Deterministic order keeps duplicate-id resolution stable.
    local function sortedDefaultMenus()
        local ids = {}
        for menu_id in pairs(reg.menus) do table.insert(ids, menu_id) end
        table.sort(ids)
        return ids
    end
    for _, menu_id in ipairs(sortedDefaultMenus()) do
        local info = reg.menus[menu_id]
        for index, id in ipairs(info.list) do
            if type(id) == "string" and id ~= MenuSchema.SEPARATOR_ID then
                addNode(id, "stock", menu_id, index, nil,
                    info.is_tab and "tab" or (reg.menus[id] and "submenu" or "item"))
            end
        end
    end
    for _, tab_id in ipairs(reg.tab_list) do
        addNode(tab_id, "stock", MenuSchema.MENU_BUTTONS_KEY, nil, nil, "tab")
    end

    -- Live contributions fill in anything the static defaults cannot know,
    -- most importantly freshly updated plugins and their sorting hints.
    -- P1B (#2/#8): collision metadata arrives via the SEPARATE `collisions`
    -- map ({ [id] = { sorted widget names } }) and is stored only on registry
    -- nodes - never written back into provider-owned entry tables.
    for id, item in pairs(registrations or {}) do
        if type(id) == "string" and not RESERVED_KEYS[id] then
            local hint = item and item.sorting_hint or nil
            local existing = reg.nodes[id]
            if existing then
                if not existing.sorting_hint and hint then
                    existing.sorting_hint = hint
                end
            else
                local widget_name = providers and providers[id] or nil
                local prov = nil
                if widget_name then
                    local s = tostring(widget_name)
                    prov = (s:find("^plugin:") or s == "stock") and s or ("plugin:" .. s)
                end
                local node = addNode(id, prov,
                    nil, nil, hint, reg.menus[id] and "submenu" or "item")
                -- Simultaneous collision: several widgets contribute the same
                -- id right now. Attribution is deterministic (smallest widget
                -- name) but the identity is inherently unstable, so the node
                -- is flagged; reconciliation refuses to pin such ids.
                if node and type(collisions) == "table"
                        and type(collisions[id]) == "table"
                        and #collisions[id] > 1 then
                    node.collides = true
                end
            end
        end
    end

    return reg
end


function Registry.isKnown(reg, id)
    return reg.nodes[id] ~= nil
end

function Registry.getNode(reg, id)
    return reg.nodes[id]
end

function Registry.getProvider(reg, id)
    local node = reg.nodes[id]
    return node and node.provider or nil
end

-- Where would this id live right now with zero user intent?
function Registry.getDefaultParent(reg, id)
    local node = reg.nodes[id]
    if not node then return nil end
    if node.default_parent then return node.default_parent end
    if node.sorting_hint and reg.menus[node.sorting_hint] then
        return node.sorting_hint
    end
    return nil
end

function Registry.isSubmenuId(reg, id)
    return reg.menus[id] ~= nil
end

return Registry

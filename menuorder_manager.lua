--[[--
Core data manager for reading, modifying, serializing, and applying
KOReader menu orders for Book View (Reader) and Normal View (File Manager).
--]]

local DataStorage = require("datastorage")
local dump = require("dump")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local SEPARATOR_ID = "----------------------------"
-- Reserved key of the order tables holding the display titles of user-created
-- submenus (id -> title). Like "KOMenu:menu_buttons" and "KOMenu:disabled" it
-- is configuration metadata, not a menu level, and must be skipped everywhere
-- generic code iterates the order's menu lists.
local CUSTOM_SUBMENUS_KEY = "KOMenu:custom_submenus"
local RESERVED_ORDER_KEYS = {
    ["KOMenu:menu_buttons"] = true,
    ["KOMenu:disabled"] = true,
    [CUSTOM_SUBMENUS_KEY] = true,
}

local MenuOrderManager = {
    SEPARATOR_ID = SEPARATOR_ID,
    CUSTOM_SUBMENUS_KEY = CUSTOM_SUBMENUS_KEY,
    orders = {
        reader = nil,
        filemanager = nil,
    },
    default_orders = {
        reader = nil,
        filemanager = nil,
    },
    backups = {
        reader = nil,
        filemanager = nil,
    },
    -- KOReader's rebuilt live menu tree may lag one refresh behind a saved
    -- cross-menu move. Keep the authoritative destination (and source) for this
    -- session so the editor does not re-import the stale source row or filter
    -- the item out of its new destination before the next complete menu
    -- rebuild/restart. Editors opened before a move keep their own stale row
    -- snapshot; buildPersistentOrder heals those against these records.
    recent_moves = {
        reader = {},
        filemanager = {},
    },
}

local function getSettingsPath(view)
    return string.format("%s/%s_menu_order.lua", DataStorage:getSettingsDir(), view)
end

local function getPluginStatePath()
    return string.format("%s/reorderingmenus_state.lua", DataStorage:getSettingsDir())
end

local plugin_state
local function loadPluginState()
    if plugin_state then return plugin_state end
    local path = getPluginStatePath()
    local loaded
    if lfs.attributes(path, "mode") == "file" then
        local ok, data = pcall(dofile, path)
        if ok and type(data) == "table" then loaded = data end
    end
    plugin_state = loaded or {}
    plugin_state.hidden_origins = plugin_state.hidden_origins or {}
    plugin_state.hidden_origins.reader = plugin_state.hidden_origins.reader or {}
    plugin_state.hidden_origins.filemanager = plugin_state.hidden_origins.filemanager or {}
    -- Remembers where a hidden entry used to sit (previous visible sibling),
    -- so "preserve location" editors can re-insert the dimmed row correctly.
    plugin_state.hidden_anchors = plugin_state.hidden_anchors or {}
    plugin_state.hidden_anchors.reader = plugin_state.hidden_anchors.reader or {}
    plugin_state.hidden_anchors.filemanager = plugin_state.hidden_anchors.filemanager or {}
    plugin_state.mirror_changes = plugin_state.mirror_changes == true
    return plugin_state
end

local function tableHasEntries(value)
    return type(value) == "table" and next(value) ~= nil
end

local function savePluginState()
    local state = loadPluginState()
    local origins = state.hidden_origins
    local has_data = tableHasEntries(origins.reader)
        or tableHasEntries(origins.filemanager)
        or state.mirror_changes == true
    local path = getPluginStatePath()
    if not has_data then
        if lfs.attributes(path) then os.remove(path) end
        return true
    end
    return util.writeToFile(dump(state, nil, true), path, true, true)
end

local function findParentInOrder(order, item_id)
    for menu_id, items in pairs(order or {}) do
        if menu_id ~= "KOMenu:disabled" and type(items) == "table" then
            for idx, id in ipairs(items) do
                if id == item_id then return menu_id, idx end
            end
        end
    end
end

local function findDefaultParent(default_order, item_id)
    return findParentInOrder(default_order, item_id)
end

local function removeItemReferences(order, item_id)
    for menu_id, items in pairs(order or {}) do
        if menu_id ~= "KOMenu:disabled" and type(items) == "table" then
            for i = #items, 1, -1 do
                if items[i] == item_id then table.remove(items, i) end
            end
        end
    end
end

-- =========================================================================
-- Live mirroring between Book view (reader) and Normal view (filemanager)
-- =========================================================================

-- Optional per-change copying: a move or visibility change in one context is
-- replicated into the other context's saved configuration whenever the same
-- item id and destination exist there. Indices, separators, tab sets and
-- preset operations do not translate cross-view and are never mirrored.
local function getMirrorContext(view)
    if view == "reader" then return "filemanager" end
    if view == "filemanager" then return "reader" end
    return nil
end

function MenuOrderManager:isMirroringEnabled()
    return loadPluginState().mirror_changes == true
end

function MenuOrderManager:setMirroringEnabled(enabled)
    loadPluginState().mirror_changes = enabled == true
    savePluginState()
end

-- How editors present hidden entries: "in place" keeps each dimmed hidden row
-- at the position it occupied among visible entries (default), while "bottom"
-- collects them into the trailing hidden section. Purely a display preference;
-- persistence always removes hidden ids from their parent lists.
function MenuOrderManager:isHiddenInPlace()
    return loadPluginState().hidden_in_place ~= false
end

function MenuOrderManager:setHiddenInPlace(enabled)
    loadPluginState().hidden_in_place = enabled == true
    savePluginState()
end

function MenuOrderManager:getHiddenAnchor(view, item_id)
    local anchors = loadPluginState().hidden_anchors[view]
    return anchors and anchors[item_id] or nil
end

-- The saved files are the truth for the other context; no live instance is
-- needed. An item qualifies when it is already configured somewhere in the
-- other file (hidden entries count: their disabled row lives there too), or
-- when it is a stock resident of the destination menu in that context.
-- Anything else is skipped so mirroring can never leak ids that belong to
-- only one context into the other as ghost entries.
local function mirror_target_known(other_view, item_id, dest_menu)
    local oorder = MenuOrderManager:loadOrder(other_view)
    if findParentInOrder(oorder, item_id) then return true end -- lives there
    for _, disabled_id in ipairs(oorder["KOMenu:disabled"] or {}) do
        if disabled_id == item_id then return true end -- hidden there
    end
    local dlist = MenuOrderManager:getDefaultOrder(other_view)[dest_menu]
    return type(dlist) == "table" and util.arrayContains(dlist, item_id) -- stock resident
end

-- Mirrored writes go through saveOrder(other_view) only; no applyLiveReload,
-- because the other UI is usually not alive in-process. A mirrored change
-- therefore takes effect when that context next reloads its configuration.
local function mirror_to_other_context(view, item_id, dest_menu, apply_fn)
    if not MenuOrderManager:isMirroringEnabled() then return false end
    local other_view = getMirrorContext(view)
    if not other_view then return false end
    if not mirror_target_known(other_view, item_id, dest_menu) then
        logger.info("ReorderingMenus: mirror skipped,", item_id,
            "is not known to", other_view)
        return false
    end
    return apply_fn(other_view)
end

local function mirror_move(other_view, item_id, to_menu_id)
    local oorder = MenuOrderManager:loadOrder(other_view)
    local old_parent = findParentInOrder(oorder, item_id)

    -- Same remove-everywhere discipline as moveItemToMenu: prevents and
    -- repairs duplicate parents while keeping submenu contents untouched.
    removeItemReferences(oorder, item_id)

    -- Anchor adaptation: the destination list may be unknown to the other
    -- context's saved file (it only overrides lists it customizes). Recreate
    -- it from stock first so the single inserted row cannot replace a whole
    -- default list on reload.
    if type(oorder[to_menu_id]) ~= "table" then
        local dlist = MenuOrderManager:getDefaultOrder(other_view)[to_menu_id]
        if type(dlist) ~= "table" then return false end
        oorder[to_menu_id] = util.tableDeepCopy(dlist)
    end
    table.insert(oorder[to_menu_id], item_id)

    -- A move makes the item visible at its destination; drop any stale hidden
    -- entry in the other context as part of the same mirrored operation.
    MenuOrderManager:setItemHidden(other_view, item_id, false, to_menu_id, true)

    MenuOrderManager.recent_moves[other_view] = MenuOrderManager.recent_moves[other_view] or {}
    MenuOrderManager.recent_moves[other_view][item_id] = { from = old_parent, to = to_menu_id }
    return MenuOrderManager:saveOrder(other_view)
end

local function normalizeDuplicateParents(view, order, default_order, recent_moves)
    local parents_by_item = {}
    for menu_id, items in pairs(order) do
        if menu_id ~= "KOMenu:disabled" and type(items) == "table" then
            for _, item_id in ipairs(items) do
                if item_id ~= SEPARATOR_ID then
                    local parents = parents_by_item[item_id]
                    if not parents then
                        parents = {}
                        parents_by_item[item_id] = parents
                    end
                    parents[menu_id] = (parents[menu_id] or 0) + 1
                end
            end
        end
    end

    local keep_parent = {}
    for item_id, parents in pairs(parents_by_item) do
        local parent_ids = {}
        local occurrences = 0
        for parent_id, count in pairs(parents) do
            table.insert(parent_ids, parent_id)
            occurrences = occurrences + count
        end
        if occurrences > 1 then
            table.sort(parent_ids)
            local default_parent = findDefaultParent(default_order, item_id)
            local non_default = {}
            for _, parent_id in ipairs(parent_ids) do
                if parent_id ~= default_parent then table.insert(non_default, parent_id) end
            end
            local recent_parent = recent_moves and recent_moves[item_id]
            if type(recent_parent) == "table" then recent_parent = recent_parent.to end
            if recent_parent and parents[recent_parent] then
                keep_parent[item_id] = recent_parent
            elseif #non_default == 1 then
                -- A duplicate in the stock parent plus one custom parent is the
                -- characteristic state left by the old move/reset bug. Preserve
                -- the user's customized destination.
                keep_parent[item_id] = non_default[1]
            else
                keep_parent[item_id] = parent_ids[1]
            end
            logger.warn("ReorderingMenus: repaired duplicate menu parents for", item_id,
                "in", view, "keeping", keep_parent[item_id])
        end
    end

    if not next(keep_parent) then return false end
    local kept = {}
    for menu_id, items in pairs(order) do
        if menu_id ~= "KOMenu:disabled" and type(items) == "table" then
            local cleaned = {}
            for _, item_id in ipairs(items) do
                local parent = keep_parent[item_id]
                if not parent or (parent == menu_id and not kept[item_id]) then
                    table.insert(cleaned, item_id)
                    if parent then kept[item_id] = true end
                end
            end
            order[menu_id] = cleaned
        end
    end
    return true
end

function MenuOrderManager:getDefaultOrder(view)
    if self.default_orders[view] then
        return util.tableDeepCopy(self.default_orders[view])
    end

    local default_file = string.format("frontend/ui/elements/%s_menu_order.lua", view)
    local loaded
    local ok, res = pcall(dofile, default_file)
    if ok and type(res) == "table" then
        loaded = res
    else
        -- Fallback require
        local req_name = string.format("ui/elements/%s_menu_order", view)
        loaded = require(req_name)
    end

    self.default_orders[view] = util.tableDeepCopy(loaded)
    return util.tableDeepCopy(loaded)
end

function MenuOrderManager:loadOrder(view, force_reload)
    if self.orders[view] and not force_reload then
        return self.orders[view]
    end

    local file_path = getSettingsPath(view)
    local working_order

    if lfs.attributes(file_path) then
        local ok, res = pcall(dofile, file_path)
        if ok and type(res) == "table" then
            working_order = util.tableDeepCopy(res)
            logger.info("ReorderingMenus: loaded user configuration from", file_path)
        else
            logger.warn("ReorderingMenus: failed to load user order, falling back to default:", res)
        end
    end

    if not working_order then
        working_order = self:getDefaultOrder(view)
    end

    -- Ensure standard tables exist
    if not working_order["KOMenu:menu_buttons"] then
        local default_order = self:getDefaultOrder(view)
        working_order["KOMenu:menu_buttons"] = util.tableDeepCopy(default_order["KOMenu:menu_buttons"])
    end
    if not working_order["KOMenu:disabled"] then
        working_order["KOMenu:disabled"] = {}
    end
    if type(working_order[CUSTOM_SUBMENUS_KEY]) ~= "table" then
        working_order[CUSTOM_SUBMENUS_KEY] = {}
    end

    local repaired_duplicates = normalizeDuplicateParents(
        view, working_order, self:getDefaultOrder(view), self.recent_moves[view]
    )
    self.orders[view] = working_order
    if repaired_duplicates and lfs.attributes(file_path, "mode") == "file" then
        local ok, err = util.writeToFile(dump(working_order, nil, true), file_path, true, true)
        if not ok then
            logger.err("ReorderingMenus: failed to persist duplicate-parent repair:", err)
        end
    end
    return working_order
end

function MenuOrderManager:isCustomized(view)
    local file_path = getSettingsPath(view)
    return lfs.attributes(file_path, "mode") == "file"
end

function MenuOrderManager:saveOrder(view)
    local order = self:loadOrder(view)
    local file_path = getSettingsPath(view)

    self:sanitizeOrder(view)

    -- Clean up disabled list (ensure no duplicates and no separators)
    if order["KOMenu:disabled"] then
        local unique_disabled = {}
        local seen = {}
        for __, id in ipairs(order["KOMenu:disabled"]) do
            if id ~= SEPARATOR_ID and not seen[id] then
                seen[id] = true
                table.insert(unique_disabled, id)
            end
        end
        order["KOMenu:disabled"] = unique_disabled
    end

    local serialized = dump(order, nil, true)
    local ok, err = util.writeToFile(serialized, file_path, true, true)
    if not ok then
        logger.err("ReorderingMenus: Failed to write menu order file:", err)
        return false, err
    end

    logger.info("ReorderingMenus: Successfully saved menu order to", file_path)
    return true, file_path
end

function MenuOrderManager:resetOrder(view)
    local file_path = getSettingsPath(view)
    if lfs.attributes(file_path) then
        os.remove(file_path)
    end
    self.orders[view] = nil
    self.backups[view] = nil
    self.recent_moves[view] = {}
    loadPluginState().hidden_origins[view] = {}
    savePluginState()
    -- Invalidate module cache
    package.loaded["ui/elements/reader_menu_order"] = nil
    package.loaded["ui/elements/filemanager_menu_order"] = nil
    return true
end

function MenuOrderManager:getRecentMoves(view)
    return util.tableDeepCopy(self.recent_moves[view] or {})
end

function MenuOrderManager:getHiddenItemParent(view, item_id)
    return loadPluginState().hidden_origins[view][item_id]
end

function MenuOrderManager:resetTabsOnly(view)
    local order = self:loadOrder(view)
    local default_order = self:getDefaultOrder(view)
    order["KOMenu:menu_buttons"] = util.tableDeepCopy(default_order["KOMenu:menu_buttons"])
    -- Clear disabled for tabs that are now visible (only keep non-tab disabled)
    local default_tabs_set = {}
    for _, t in ipairs(default_order["KOMenu:menu_buttons"] or {}) do default_tabs_set[t] = true end
    local new_disabled = {}
    for _, id in ipairs(order["KOMenu:disabled"] or {}) do
        if not default_tabs_set[id] then
            table.insert(new_disabled, id)
        end
    end
    order["KOMenu:disabled"] = new_disabled
    self.recent_moves[view] = {}
    return true
end

function MenuOrderManager:resetSubmenu(view, menu_id)
    local order = self:loadOrder(view)
    local default_order = self:getDefaultOrder(view)
    if not default_order[menu_id] then return false end

    local current_items = util.tableDeepCopy(order[menu_id] or {})
    local reset_items = util.tableDeepCopy(default_order[menu_id])
    local default_items_set = {}
    for _, id in ipairs(reset_items) do
        if id ~= SEPARATOR_ID then default_items_set[id] = true end
    end

    local extras = {}
    local extra_seen = {}
    local function keepDynamicItem(item_id)
        if item_id ~= SEPARATOR_ID and not default_items_set[item_id]
                and not extra_seen[item_id] then
            extra_seen[item_id] = true
            table.insert(extras, item_id)
        end
    end
    local function restoreToDefaultParent(item_id, parent_id)
        removeItemReferences(order, item_id)
        if parent_id and type(order[parent_id]) == "table" then
            table.insert(order[parent_id], item_id)
        end
    end

    -- Keep newly installed/dynamic items when resetting the stock order. Items
    -- moved in from another stock menu return to their stock parent instead.
    for _, item_id in ipairs(current_items) do
        if item_id ~= SEPARATOR_ID and not default_items_set[item_id] then
            local default_parent = findDefaultParent(default_order, item_id)
            if default_parent and default_parent ~= menu_id then
                restoreToDefaultParent(item_id, default_parent)
            else
                keepDynamicItem(item_id)
            end
        end
    end

    -- Hidden dynamic plugin items retain their source in our small sidecar
    -- state. Resetting that menu unhides and restores them just like stock
    -- items, fixing entries that previously disappeared permanently.
    local origins = loadPluginState().hidden_origins[view]
    local new_disabled = {}
    for _, id in ipairs(order["KOMenu:disabled"] or {}) do
        local belongs_here = default_items_set[id] or origins[id] == menu_id
        if belongs_here then
            local default_parent = findDefaultParent(default_order, id)
            if not default_items_set[id] and default_parent and default_parent ~= menu_id then
                restoreToDefaultParent(id, default_parent)
            elseif not default_items_set[id] then
                keepDynamicItem(id)
            end
            origins[id] = nil
        else
            table.insert(new_disabled, id)
        end
    end

    -- Default children may have been moved elsewhere by the user. Remove all
    -- old references before restoring them here so a reset cannot create the
    -- duplicate-parent state that made Battery Statistics placement random.
    local pulled_back = {}
    for item_id in pairs(default_items_set) do
        local old_parent = findParentInOrder(order, item_id)
        if old_parent and old_parent ~= menu_id then
            pulled_back[item_id] = old_parent
        end
    end
    for item_id in pairs(default_items_set) do
        removeItemReferences(order, item_id)
    end
    for _, item_id in ipairs(extras) do table.insert(reset_items, item_id) end
    order[menu_id] = reset_items
    order["KOMenu:disabled"] = new_disabled

    -- Record each pulled-back item's return instead of wiping the move
    -- history: editors of its previous location opened before the reset must
    -- not resurrect it (their stale saves would duplicate it until the next
    -- restart repaired the parent). Unrelated move records stay valid.
    local kept_moves = util.tableDeepCopy(self.recent_moves[view] or {})
    for item_id, old_parent in pairs(pulled_back) do
        kept_moves[item_id] = { from = old_parent, to = menu_id }
    end
    self.recent_moves[view] = kept_moves
    savePluginState()
    return true, pulled_back
end

function MenuOrderManager:backupOrder(view)
    local order = self:loadOrder(view)
    self.backups[view] = util.tableDeepCopy(order)
    return true
end

function MenuOrderManager:restoreOrder(view)
    if self.backups[view] then
        self.orders[view] = util.tableDeepCopy(self.backups[view])
        self.recent_moves[view] = {}
        return true
    end
    return false
end

function MenuOrderManager:hasBackup(view)
    return self.backups[view] ~= nil
end

function MenuOrderManager:getTabs(view)
    local order = self:loadOrder(view)
    local tabs = order["KOMenu:menu_buttons"]
    if tabs and type(tabs) == "table" then
        return util.tableDeepCopy(tabs)
    end
    local default_order = self:getDefaultOrder(view)
    return util.tableDeepCopy(default_order["KOMenu:menu_buttons"] or {})
end

function MenuOrderManager:getAllKnownTabs(view)
    local default_order = self:getDefaultOrder(view)
    local user_order = self:loadOrder(view)
    local tabs = {}
    local seen = {}

    for __, t in ipairs(user_order["KOMenu:menu_buttons"] or {}) do
        if not seen[t] then
            seen[t] = true
            table.insert(tabs, t)
        end
    end

    for __, t in ipairs(default_order["KOMenu:menu_buttons"] or {}) do
        if not seen[t] then
            seen[t] = true
            table.insert(tabs, t)
        end
    end

    return tabs
end

function MenuOrderManager:getMenuItems(view, menu_id)
    local order = self:loadOrder(view)
    if order[menu_id] and type(order[menu_id]) == "table" then
        return util.tableDeepCopy(order[menu_id])
    end
    return {}
end

function MenuOrderManager:isSubmenu(view, id)
    local order = self:loadOrder(view)
    return order[id] ~= nil and not RESERVED_ORDER_KEYS[id]
end

function MenuOrderManager:getAllSubmenuIds(view)
    local order = self:loadOrder(view)
    local submenus = {}
    for k, v in pairs(order) do
        if not RESERVED_ORDER_KEYS[k] and type(v) == "table" then
            -- Verify if it is not a top level tab
            local is_tab = false
            for __, tab in ipairs(order["KOMenu:menu_buttons"] or {}) do
                if tab == k then
                    is_tab = true
                    break
                end
            end
            if not is_tab then
                table.insert(submenus, k)
            end
        end
    end
    table.sort(submenus)
    return submenus
end

function MenuOrderManager:getAllMenusAndSubmenus(view)
    local order = self:loadOrder(view)
    local list = {}
    local seen = {}

    -- Add top level tabs first
    for __, tab in ipairs(order["KOMenu:menu_buttons"] or {}) do
        if not seen[tab] then
            seen[tab] = true
            table.insert(list, { id = tab, is_tab = true })
        end
    end

    -- Add all other submenus
    for k, v in pairs(order) do
        if not RESERVED_ORDER_KEYS[k] and type(v) == "table" and not seen[k] then
            seen[k] = true
            table.insert(list, { id = k, is_tab = false })
        end
    end

    return list
end

function MenuOrderManager:getParentMenu(view, item_id)
    local order = self:loadOrder(view)
    return findParentInOrder(order, item_id)
end

function MenuOrderManager:reconcileMenuItems(view, menu_id, item_ids)
    local order = self:loadOrder(view)
    if type(order[menu_id]) ~= "table" then return false end
    local disabled = {}
    for _, item_id in ipairs(order["KOMenu:disabled"] or {}) do disabled[item_id] = true end
    local changed = false
    for _, item_id in ipairs(item_ids or {}) do
        if item_id ~= SEPARATOR_ID and not disabled[item_id]
                and not findParentInOrder(order, item_id) then
            table.insert(order[menu_id], item_id)
            changed = true
        end
    end
    return changed
end

-- Insert item_id into target_list at its curated stock slot: after the
-- nearest preceding default sibling already present in the list, else before
-- the nearest following one, else appended at the end. Single-id variant of
-- reconcileDefaultEntries' alignment walk.
local function insert_at_stock_slot(target_list, default_list, item_id)
    local didx = nil
    for i, id in ipairs(default_list) do
        if id == item_id then didx = i break end
    end
    if not didx then return false end

    local present = {}
    for _, id in ipairs(target_list) do present[id] = true end

    -- Nearest preceding default sibling present in the list. Separators are
    -- legitimate anchors: they are part of the curated layout.
    for i = didx - 1, 1, -1 do
        local cand = default_list[i]
        if present[cand] then
            for ti, tid in ipairs(target_list) do
                if tid == cand then
                    table.insert(target_list, ti + 1, item_id)
                    return true
                end
            end
        end
    end
    -- Else nearest following default sibling present in the list.
    for i = didx + 1, #default_list do
        local cand = default_list[i]
        if present[cand] then
            for ti, tid in ipairs(target_list) do
                if tid == cand then
                    table.insert(target_list, ti, item_id)
                    return true
                end
            end
        end
    end
    table.insert(target_list, item_id)
    return true
end

-- Revert a single entry to its stock parent and stock slot: unhides it when
-- needed, detaches it from wherever the user placed it, and re-inserts it at
-- its curated default position. Does not persist by itself; callers wrap it
-- with saveAndApply (UI) or saveOrder (tests).
function MenuOrderManager:restoreItemDefault(view, item_id)
    local order = self:loadOrder(view)
    local default_order = self:getDefaultOrder(view)

    -- Resolve the stock home BEFORE mutating anything, so provider-less or
    -- structural ids can be refused without leaving half-applied state.
    local default_menu_id, default_list = nil, nil
    for menu_id, dlist in pairs(default_order) do
        if menu_id ~= "KOMenu:menu_buttons" and menu_id ~= "KOMenu:disabled"
                and type(dlist) == "table" then
            for _, id in ipairs(dlist) do
                if id == item_id then
                    default_menu_id = menu_id
                    default_list = dlist
                    break
                end
            end
            if default_menu_id then break end
        end
    end
    if not default_menu_id or type(order[default_menu_id]) ~= "table" then
        -- This plugin inserts its own entry into More tools at load time
        -- (ui/plugin/insert_menu), so it never appears in freshly-read
        -- default files. Do NOT fall back to scanning the require-cache:
        -- MenuSorter writes user lists into that table by reference, which
        -- would match arbitrary configured entries. Without a stock slot
        -- reference it simply appends at the end of its home.
        if item_id == "reordering_menus" and type(order.more_tools) == "table" then
            default_menu_id = "more_tools"
            default_list = nil
        end
    end
    if not default_menu_id or type(order[default_menu_id]) ~= "table" then
        return false, _("No default placement is available for this entry.")
    end

    if self:isItemHidden(view, item_id) then
        self:setItemHidden(view, item_id, false)   -- unhide first
    end

    removeItemReferences(order, item_id)
    if default_list then
        insert_at_stock_slot(order[default_menu_id], default_list, item_id)
    else
        table.insert(order[default_menu_id], item_id)
    end

    if self.recent_moves[view] then
        self.recent_moves[view][item_id] = nil     -- stop healing interference
    end
    return true
end

function MenuOrderManager:reconcileRegisteredItems(view, menu_items)
    local order = self:loadOrder(view)
    local by_menu = {}
    local default_order = self:getDefaultOrder(view)
    local structure_changed = false
    for item_id, item in pairs(menu_items or {}) do
        local sorting_hint = type(item) == "table" and item.sorting_hint
        if type(sorting_hint) == "string" then
            if type(order[sorting_hint]) ~= "table" then
                -- The hinted menu is unknown to the saved configuration (for
                -- example a file written before that menu existed). Recreate it
                -- from the stock layout so the item lands where it belongs
                -- instead of surfacing as a "NEW: ..." orphan.
                local default_list = default_order[sorting_hint]
                if type(default_list) == "table" then
                    order[sorting_hint] = util.tableDeepCopy(default_list)
                    structure_changed = true
                end
            end
            if type(order[sorting_hint]) == "table" then
                by_menu[sorting_hint] = by_menu[sorting_hint] or {}
                table.insert(by_menu[sorting_hint], item_id)
            end
        end
    end
    local changed = structure_changed
    for menu_id, item_ids in pairs(by_menu) do
        table.sort(item_ids)
        if self:reconcileMenuItems(view, menu_id, item_ids) then changed = true end
    end
    return changed
end

-- Anchor entries that exist in the stock default layout but nowhere in the
-- saved configuration. Two situations need this: KOReader updates add new core
-- menu entries (which carry no sorting_hint), and a saved order file replaces
-- each affected default list wholesale - so without this, such entries fall
-- back to MenuSorter's orphan handling and surface as "NEW: ..." rows in the
-- first menu, while brand-new top-level tabs vanish from the tab bar entirely.
-- Deliberate removals stay untouched: hidden items live in KOMenu:disabled and
-- moved items remain configured under their current parent.
--
-- Insertion is slot-aligned rather than appended: both lists are walked in
-- parallel, and an unknown default entry is emitted right before the next
-- already-known sibling that follows it in the stock layout. Update entries
-- therefore land where upstream curated them (e.g. directly under the option
-- they extend) instead of piling up at the end of the menu.
function MenuOrderManager:reconcileDefaultEntries(view)
    local order = self:loadOrder(view)
    local default_order = self:getDefaultOrder(view)
    local disabled = {}
    for _, id in ipairs(order["KOMenu:disabled"] or {}) do
        disabled[id] = true
    end
    local configured_parent = {}
    for menu_id, list in pairs(order) do
        if menu_id ~= "KOMenu:disabled" and type(list) == "table" then
            for _, id in ipairs(list) do
                if id ~= SEPARATOR_ID then configured_parent[id] = menu_id end
            end
        end
    end

    local changed = false
    for menu_id, default_list in pairs(default_order) do
        local user_list = order[menu_id]
        if type(user_list) ~= "table" or type(default_list) ~= "table" then
            -- Keys the user file does not override come straight from the
            -- (updated) defaults and need no healing.
        else
            local in_result = {}
            for _, id in ipairs(user_list) do in_result[id] = true end

            local qualifies = function(id)
                return type(id) == "string" and id ~= SEPARATOR_ID
                    and id ~= "" and id ~= "__empty_hint__"
                    and not in_result[id] and not disabled[id]
                    and not configured_parent[id]
            end

            local result = {}
            local di = 1 -- cursor into default_list
            local function flush_until(match_k)
                for k = di, match_k - 1 do
                    local did = default_list[k]
                    if qualifies(did) then
                        table.insert(result, did)
                        in_result[did] = true
                        changed = true
                        logger.info("ReorderingMenus: anchored new default entry",
                            did, "under", menu_id, "in", view,
                            "before", tostring(default_list[match_k]))
                    end
                end
                di = match_k + 1
            end

            for _, uid in ipairs(user_list) do
                if uid == SEPARATOR_ID then
                    -- Separators pass through without flushing pending stock
                    -- entries, keeping group boundaries intact.
                    table.insert(result, uid)
                else
                    local match_k = nil
                    for k = di, #default_list do
                        if default_list[k] == uid then match_k = k break end
                    end
                    if match_k then
                        flush_until(match_k)
                    end
                    table.insert(result, uid)
                end
            end
            for k = di, #default_list do
                local did = default_list[k]
                if qualifies(did) then
                    table.insert(result, did)
                    in_result[did] = true
                    changed = true
                    logger.info("ReorderingMenus: anchored new default entry",
                        did, "under", menu_id, "in", view)
                end
            end
            order[menu_id] = result
        end
    end
    return changed
end

function MenuOrderManager:isItemHidden(view, item_id)
    local order = self:loadOrder(view)
    local disabled = order["KOMenu:disabled"] or {}
    for __, id in ipairs(disabled) do
        if id == item_id then
            return true
        end
    end
    return false
end

function MenuOrderManager:getDisabledItems(view)
    local order = self:loadOrder(view)
    return order["KOMenu:disabled"] or {}
end

-- Menu items that must stay reachable. Hiding this plugin's own entry would
-- lock the user out of menu editing entirely (the Tools tab alone is not enough
-- protection: More tools can be edited item by item). Interactive hide actions
-- refuse these items; preset layouts remain deliberate bulk operations.
local PROTECTED_ITEMS = {
    reordering_menus = true,
}

function MenuOrderManager:setItemHidden(view, item_id, is_hidden, current_menu_id, _mirrored)
    if is_hidden and PROTECTED_ITEMS[item_id] then
        return false
    end
    local order = self:loadOrder(view)
    order["KOMenu:disabled"] = order["KOMenu:disabled"] or {}
    local origins = loadPluginState().hidden_origins[view]

    if is_hidden then
        local source_menu = current_menu_id or findParentInOrder(order, item_id)
        if source_menu then origins[item_id] = source_menu end

        -- Remember the previous visible sibling so "preserve location" editors
        -- can re-insert the dimmed row at its old position later.
        local anchors = loadPluginState().hidden_anchors[view]
        anchors[item_id] = false -- explicit "top of the menu" marker
        if source_menu and type(order[source_menu]) == "table" then
            for _, lid in ipairs(order[source_menu]) do
                if lid == item_id then break end
                if lid ~= SEPARATOR_ID then anchors[item_id] = lid end
            end
        end

        -- Add to disabled list if not present
        local found = false
        for __, id in ipairs(order["KOMenu:disabled"]) do
            if id == item_id then
                found = true
                break
            end
        end
        if not found then
            table.insert(order["KOMenu:disabled"], item_id)
        end

        removeItemReferences(order, item_id)

        -- Mirror the hide into the other context. The origin sidecar updates
        -- symmetrically: the mirrored call records the other context's own
        -- parent (or falls back to its defaults on unhide).
        if not _mirrored then
            local gate_dest = source_menu or findDefaultParent(self:getDefaultOrder(view), item_id)
            mirror_to_other_context(view, item_id, gate_dest, function(other_view)
                return self:setItemHidden(other_view, item_id, true, nil, true)
            end)
        end
    else
        -- Unhide: remove from disabled list
        for i = #order["KOMenu:disabled"], 1, -1 do
            if order["KOMenu:disabled"][i] == item_id then
                table.remove(order["KOMenu:disabled"], i)
            end
        end

        -- Re-add only when the item is actually absent. moveItemToMenu calls
        -- this after inserting its exact target index, which must not be
        -- removed and appended again.
        if not findParentInOrder(order, item_id) then
            local target_menu = current_menu_id or origins[item_id]
            if not target_menu or not order[target_menu] then
                target_menu = findDefaultParent(self:getDefaultOrder(view), item_id)
            end
            if target_menu and order[target_menu] then
                table.insert(order[target_menu], item_id)
            end
        end
        origins[item_id] = nil
        loadPluginState().hidden_anchors[view][item_id] = nil

        -- Mirror the unhide into the other context; its own origin sidecar
        -- (or stock default) picks the restoration menu there.
        if not _mirrored then
            local gate_dest = findParentInOrder(order, item_id)
                or findDefaultParent(self:getDefaultOrder(view), item_id)
            mirror_to_other_context(view, item_id, gate_dest, function(other_view)
                return self:setItemHidden(other_view, item_id, false, nil, true)
            end)
        end
    end
    savePluginState()
    return true
end

function MenuOrderManager:moveItem(view, menu_id, from_idx, to_idx)
    local order = self:loadOrder(view)
    local items = order[menu_id]
    if not items then return false end

    if from_idx < 1 or from_idx > #items or to_idx < 1 or to_idx > #items then
        return false
    end

    local item = table.remove(items, from_idx)
    table.insert(items, to_idx, item)
    return true
end

function MenuOrderManager:isMenuDescendant(view, ancestor_menu_id, candidate_menu_id)
    local order = self:loadOrder(view)
    if not order[ancestor_menu_id] or ancestor_menu_id == candidate_menu_id then
        return false
    end

    local visited = {}
    local function containsDescendant(menu_id)
        if visited[menu_id] then return false end
        visited[menu_id] = true
        for _, child_id in ipairs(order[menu_id] or {}) do
            if child_id == candidate_menu_id then return true end
            if type(order[child_id]) == "table" and containsDescendant(child_id) then
                return true
            end
        end
        return false
    end
    return containsDescendant(ancestor_menu_id)
end

function MenuOrderManager:canMoveItemToMenu(view, item_id, from_menu_id, to_menu_id)
    local order = self:loadOrder(view)
    if item_id == SEPARATOR_ID then
        return false, _("Separators cannot be moved between menus.")
    end
    if not from_menu_id or type(order[from_menu_id]) ~= "table" then
        return false, _("The source menu is unavailable.")
    end
    if not to_menu_id or type(order[to_menu_id]) ~= "table" then
        return false, _("The destination menu is unavailable.")
    end
    if from_menu_id == to_menu_id then
        return false, _("The item is already in this menu.")
    end

    local found_in_source = false
    for _, id in ipairs(order[from_menu_id]) do
        if id == item_id then
            found_in_source = true
            break
        end
    end
    if not found_in_source then
        -- Newly registered plugin items can be visible in KOReader before they
        -- have an entry in the persisted order. Allow those orphans to acquire
        -- their first configured parent, but reject a stale/wrong source when
        -- the item is already configured elsewhere.
        local configured_parent = self:getParentMenu(view, item_id)
        if configured_parent then
            return false, _("The item is no longer in the source menu.")
        end
    end

    if type(order[item_id]) == "table" then
        if to_menu_id == item_id then
            return false, _("A submenu cannot be moved into itself.")
        end
        if self:isMenuDescendant(view, item_id, to_menu_id) then
            return false, _("A submenu cannot be moved into one of its own submenus.")
        end
    end
    return true
end

function MenuOrderManager:moveItemToMenu(view, item_id, from_menu_id, to_menu_id, target_idx, _mirrored)
    local order = self:loadOrder(view)
    local can_move, err = self:canMoveItemToMenu(view, item_id, from_menu_id, to_menu_id)
    if not can_move then return false, err end

    -- An older editor could save its stale source model after a move and leave
    -- the same ID under two parents. Remove every configured reference before
    -- inserting the authoritative destination, which both prevents and repairs
    -- that corruption while keeping the submenu's own contents untouched.
    for menu_id, menu_items in pairs(order) do
        if menu_id ~= "KOMenu:disabled" and type(menu_items) == "table" then
            for i = #menu_items, 1, -1 do
                if menu_items[i] == item_id then
                    table.remove(menu_items, i)
                end
            end
        end
    end

    -- Insert into to_menu
    if target_idx and target_idx >= 1 and target_idx <= #order[to_menu_id] + 1 then
        table.insert(order[to_menu_id], target_idx, item_id)
    else
        table.insert(order[to_menu_id], item_id)
    end

    -- Ensure item is not disabled. This composite operation mirrors itself as
    -- a whole below, so the inner toggle's own mirroring stays suppressed.
    self:setItemHidden(view, item_id, false, to_menu_id, true)
    self.recent_moves[view] = self.recent_moves[view] or {}
    -- Record both ends of the move so a still-open editor of either the old or
    -- the new menu can be healed when it saves its stale row snapshot.
    self.recent_moves[view][item_id] = { from = from_menu_id, to = to_menu_id }
    if not _mirrored then
        mirror_to_other_context(view, item_id, to_menu_id, function(other_view)
            return mirror_move(other_view, item_id, to_menu_id)
        end)
    end
    return true
end

function MenuOrderManager:insertSeparator(view, menu_id, idx)
    local order = self:loadOrder(view)
    if not order[menu_id] then return false end
    if idx < 1 then idx = 1 end
    if idx > #order[menu_id] + 1 then idx = #order[menu_id] + 1 end

    table.insert(order[menu_id], idx, SEPARATOR_ID)
    return true
end

function MenuOrderManager:removeSeparator(view, menu_id, idx)
    local order = self:loadOrder(view)
    if not order[menu_id] or not order[menu_id][idx] then return false end
    if order[menu_id][idx] == SEPARATOR_ID then
        table.remove(order[menu_id], idx)
        return true
    end
    return false
end

-- =========================================================================
-- User-created submenus
-- =========================================================================

local function collectTakenIds(order)
    local taken = {}
    for k in pairs(order) do
        taken[k] = true
    end
    for _menu_id, items in pairs(order) do
        if type(items) == "table" then
            for _, item_id in ipairs(items) do
                if type(item_id) == "string" then taken[item_id] = true end
            end
        end
    end
    return taken
end

-- Ids are neutral (custom_submenu_N) because names may contain characters the
-- id space cannot carry; the display title always comes from the registry.
local CUSTOM_ID_PATTERN = "^custom_submenu_(%d+)$"

local function generateCustomSubmenuId(order)
    local taken = collectTakenIds(order)
    local max_used = 0
    for id in pairs(taken) do
        local num = id:match(CUSTOM_ID_PATTERN)
        if num then
            num = tonumber(num)
            if num > max_used then max_used = num end
        end
    end
    return "custom_submenu_" .. (max_used + 1)
end

function MenuOrderManager:getCustomSubmenuTitle(view, submenu_id)
    local order = self:loadOrder(view)
    local customs = order[CUSTOM_SUBMENUS_KEY]
    if type(customs) == "table" then
        local title = customs[submenu_id]
        if type(title) == "string" then return title end
    end
    return nil
end

function MenuOrderManager:getCustomSubmenus(view)
    local order = self:loadOrder(view)
    local customs = order[CUSTOM_SUBMENUS_KEY]
    return type(customs) == "table" and util.tableDeepCopy(customs) or {}
end

function MenuOrderManager:isCustomSubmenu(view, submenu_id)
    return self:getCustomSubmenuTitle(view, submenu_id) ~= nil
end

-- Create an empty submenu under parent_menu_id at 1-based idx (clamped like
-- insertSeparator). The caller persists via saveOrder; creation only mutates
-- the working order so a discarded editor cannot leave half-created state.
-- Returns ok, new_id_or_error.
function MenuOrderManager:createSubmenu(view, parent_menu_id, title, idx)
    local order = self:loadOrder(view)
    local parent_list = order[parent_menu_id]
    if type(parent_list) ~= "table" or RESERVED_ORDER_KEYS[parent_menu_id] then
        return false, _("The target menu is unavailable.")
    end
    title = util.trim(tostring(title or ""))
    if title == "" then
        return false, _("The submenu name cannot be empty.")
    end
    if type(order[CUSTOM_SUBMENUS_KEY]) ~= "table" then
        order[CUSTOM_SUBMENUS_KEY] = {}
    end
    local new_id = generateCustomSubmenuId(order)
    if idx == nil or idx < 1 or idx > #parent_list + 1 then
        idx = #parent_list + 1
    end
    table.insert(parent_list, idx, new_id)
    order[new_id] = {}
    order[CUSTOM_SUBMENUS_KEY][new_id] = title
    return true, new_id
end

-- Only empty user-created submenus can be deleted; their contents must be
-- moved or hidden first so stock items are never orphaned by a deletion.
function MenuOrderManager:deleteCustomSubmenu(view, submenu_id)
    local order = self:loadOrder(view)
    local customs = order[CUSTOM_SUBMENUS_KEY]
    if type(customs) ~= "table" or customs[submenu_id] == nil then
        return false, _("Only created submenus can be deleted.")
    end
    local content = order[submenu_id]
    if type(content) ~= "table" then
        return false, _("Submenu not found.")
    end
    for __, item_id in ipairs(content) do
        if item_id ~= SEPARATOR_ID then
            return false, _("Move or hide this submenu's items before deleting it.")
        end
    end
    removeItemReferences(order, submenu_id)
    order[submenu_id] = nil
    customs[submenu_id] = nil
    return true
end

function MenuOrderManager:reorderTabs(view, new_tab_list)
    local order = self:loadOrder(view)
    order["KOMenu:menu_buttons"] = util.tableDeepCopy(new_tab_list)
    return true
end

-- Top-level tabs that must stay reachable. The plugin's own entry lives under
-- Tools > More tools, so hiding Tools could lock the user out of menu editing
-- entirely. Interactive hide actions refuse these tabs; preset layouts are
-- deliberate bulk operations and may still reposition or hide them.
local PROTECTED_TABS = {
    tools = true,
}

function MenuOrderManager:isTabProtected(tab_id)
    return PROTECTED_TABS[tab_id] == true
end

-- See PROTECTED_ITEMS above setItemHidden; preset layouts remain deliberate
-- bulk operations.
function MenuOrderManager:isItemProtected(item_id)
    return PROTECTED_ITEMS[item_id] == true
end

-- Only well-formed string ids may persist. Non-string entries (numbers,
-- booleans, leaked row tables) would either break MenuSorter or surface as
-- bogus "nil"-titled entries in the rebuilt menus.
local function sanitizedMenuId(id)
    if type(id) ~= "string" then return nil end
    if id == "" or id == "__empty_hint__" then return nil end
    return id
end

function MenuOrderManager:sanitizeOrder(view)
    local order = self.orders[view]
    if not order then return false end
    for menu_id, items in pairs(order) do
        if not RESERVED_ORDER_KEYS[menu_id] and type(items) == "table" then
            local cleaned, seen = {}, {}
            for _, raw_id in ipairs(items) do
                if raw_id == SEPARATOR_ID then
                    -- Multiple separators per menu are intentional.
                    table.insert(cleaned, raw_id)
                else
                    local id = sanitizedMenuId(raw_id)
                    if id and not seen[id] then
                        seen[id] = true
                        table.insert(cleaned, id)
                    end
                end
            end
            order[menu_id] = cleaned
        end
    end
    local disabled, seen = {}, {}
    for _, raw_id in ipairs(order["KOMenu:disabled"] or {}) do
        local id = sanitizedMenuId(raw_id)
        if id and not seen[id] then
            seen[id] = true
            table.insert(disabled, id)
        end
    end
    order["KOMenu:disabled"] = disabled
    return true
end

function MenuOrderManager:setTabHidden(view, tab_id, is_hidden)
    if is_hidden and PROTECTED_TABS[tab_id] then
        return false
    end
    local order = self:loadOrder(view)
    local tabs = order["KOMenu:menu_buttons"] or {}
    order["KOMenu:disabled"] = order["KOMenu:disabled"] or {}

    if is_hidden then
        for i = #tabs, 1, -1 do
            if tabs[i] == tab_id then
                table.remove(tabs, i)
            end
        end
        local found = false
        for __, id in ipairs(order["KOMenu:disabled"]) do
            if id == tab_id then found = true; break end
        end
        if not found then
            table.insert(order["KOMenu:disabled"], tab_id)
        end
    else
        for i = #order["KOMenu:disabled"], 1, -1 do
            if order["KOMenu:disabled"][i] == tab_id then
                table.remove(order["KOMenu:disabled"], i)
            end
        end
        local exists = false
        for __, id in ipairs(tabs) do
            if id == tab_id then exists = true; break end
        end
        if not exists then
            table.insert(tabs, tab_id)
        end
    end
end

function MenuOrderManager:copyLayout(from_view, to_view)
    local src_order = self:loadOrder(from_view)
    local dst_order = self:loadOrder(to_view)

    -- Common submenus to sync between views
    local sync_keys = {
        "setting", "tools", "search", "main",
        "network", "screen", "taps_and_gestures", "navigation", "document", "device",
        "more_tools", "search_settings", "help", "exit_menu",
    }

    for __, key in ipairs(sync_keys) do
        if src_order[key] then
            dst_order[key] = util.tableDeepCopy(src_order[key])
        end
    end

    if src_order["KOMenu:disabled"] then
        dst_order["KOMenu:disabled"] = util.tableDeepCopy(src_order["KOMenu:disabled"])
    end

    -- User-created submenus referenced by the synced lists travel with their
    -- content and title; customs anchored under unsynced parents stay local.
    local src_customs = src_order[CUSTOM_SUBMENUS_KEY]
    if type(src_customs) == "table" then
        local dst_customs = util.tableDeepCopy(dst_order[CUSTOM_SUBMENUS_KEY]) or {}
        for __, list in pairs(dst_order) do
            if not RESERVED_ORDER_KEYS[__] and type(list) == "table" then
                for _, item_id in ipairs(list) do
                    local title = type(item_id) == "string" and src_customs[item_id] or nil
                    if title then
                        dst_customs[item_id] = tostring(title)
                        dst_order[item_id] = type(src_order[item_id]) == "table"
                            and util.tableDeepCopy(src_order[item_id]) or {}
                    end
                end
            end
        end
        if next(dst_customs) then
            dst_order[CUSTOM_SUBMENUS_KEY] = dst_customs
        end
    end

    -- Dynamic hidden items are absent from the menu-order tree, so their
    -- source menu has to travel with the disabled list when copying a layout.

    -- Dynamic hidden items are absent from the menu-order tree, so their
    -- source menu has to travel with the disabled list when copying a layout.
    local origins = loadPluginState().hidden_origins
    origins[to_view] = util.tableDeepCopy(origins[from_view])
    savePluginState()

    self.orders[to_view] = dst_order
    return true
end

function MenuOrderManager:applyLiveReload(ui, view)
    -- Invalidate menu order module cache in package.loaded
    package.loaded["ui/elements/reader_menu_order"] = nil
    package.loaded["ui/elements/filemanager_menu_order"] = nil

    if not ui then return end

    pcall(function()
        if ui.menu then
            -- Close open menu popup safely if visible
            if ui.menu.menu_container then
                pcall(function()
                    if ui.menu.onCloseReaderMenu then
                        ui.menu:onCloseReaderMenu()
                    elseif ui.menu.onCloseFileManagerMenu then
                        ui.menu:onCloseFileManagerMenu()
                    elseif ui.menu.onTapCloseMenu then
                        ui.menu:onTapCloseMenu()
                    end
                end)
            end

            local is_reader = ui.document ~= nil
            local old_menu = ui.menu
            local old_widgets = (old_menu and old_menu.registered_widgets) or {}

            local new_menu
            if is_reader then
                local ReaderMenu = require("apps/reader/modules/readermenu")
                new_menu = ReaderMenu:new{ ui = ui, view = ui.view }
            else
                local FileManagerMenu = require("apps/filemanager/filemanagermenu")
                new_menu = FileManagerMenu:new{ ui = ui }
            end

            new_menu.registered_widgets = {}
            for __, w in pairs(old_widgets) do
                table.insert(new_menu.registered_widgets, w)
            end

            -- Build before swapping: MenuSorter consumes its inputs, so a
            -- failed build would leave a menu object whose tab_item_table can
            -- never be regenerated. The previous menu stays functional then,
            -- instead of being replaced by one that cannot open.
            local ok_build, err_build = pcall(new_menu.setUpdateItemTable, new_menu)
            if not ok_build then
                logger.err("ReorderingMenus: live menu rebuild failed, keeping previous menu:", err_build)
                return
            end

            if ui.registerModule then
                ui:registerModule("menu", new_menu)
            else
                ui.menu = new_menu
            end

            -- Relocated submenus registered with dynamic-only titles would
            -- otherwise render as "nil"; give every row a usable title.
            -- Lazy require: ui_screens depends on this module.
            local ok_tree, err_tree = pcall(function()
                require("ui_screens"):sanitizeLiveMenuTree(new_menu.tab_item_table)
            end)
            if not ok_tree then
                logger.warn("ReorderingMenus: live menu title sanitize failed:", err_tree)
            end
        end
    end)
end

-- =========================================================================
-- Preset Management
-- =========================================================================

function MenuOrderManager:getPresetsDir(view)
    local base_dir = string.format("%s/menu_order_presets", DataStorage:getSettingsDir())
    if not lfs.attributes(base_dir) then
        util.makePath(base_dir)
    end
    local view_dir = string.format("%s/%s", base_dir, view)
    if not lfs.attributes(view_dir) then
        util.makePath(view_dir)
    end
    return view_dir
end

local function cleanPresetName(preset_name)
    if not preset_name or preset_name:match("^%s*$") then
        return nil, _("Preset name cannot be empty.")
    end
    local clean_name = preset_name:gsub("[^%w_%- %.]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if clean_name == "" then
        return nil, _("Invalid preset name.")
    end
    return clean_name
end

local function cleanPathComponent(value)
    local clean_value = tostring(value or ""):gsub("[^%w_%-]", "_")
    return clean_value ~= "" and clean_value or "submenu"
end

function MenuOrderManager:getSubmenuPresetsDir(view, menu_id)
    local root_dir = string.format("%s/submenus", self:getPresetsDir(view))
    if not lfs.attributes(root_dir) then
        util.makePath(root_dir)
    end
    local menu_dir = string.format("%s/%s", root_dir, cleanPathComponent(menu_id))
    if not lfs.attributes(menu_dir) then
        util.makePath(menu_dir)
    end
    return menu_dir
end

local function collectSubmenuOrders(order, default_order, menu_id, include_nested, menus, visited)
    if visited[menu_id] or type(order[menu_id]) ~= "table" then return end
    visited[menu_id] = true
    menus[menu_id] = util.tableDeepCopy(order[menu_id])
    if not include_nested then return end

    local children = {}
    for _, item_id in ipairs(order[menu_id]) do
        if type(order[item_id]) == "table" then
            children[item_id] = true
        end
    end

    -- A hidden submenu is removed from its parent list. Include it when it is
    -- disabled, but do not pull in a submenu that was deliberately moved.
    local disabled = {}
    for _, item_id in ipairs(order["KOMenu:disabled"] or {}) do
        disabled[item_id] = true
    end
    for _, item_id in ipairs(default_order[menu_id] or {}) do
        if disabled[item_id] and type(order[item_id]) == "table" then
            children[item_id] = true
        end
    end

    for child_id in pairs(children) do
        collectSubmenuOrders(order, default_order, child_id, true, menus, visited)
    end
end

function MenuOrderManager:saveSubmenuPreset(view, menu_id, menu_title, preset_name, include_nested, current_menu_items)
    local clean_name, name_err = cleanPresetName(preset_name)
    if not clean_name then return false, name_err end

    local order = self:loadOrder(view)
    if type(order[menu_id]) ~= "table" then
        return false, _("Submenu not found.")
    end

    local menus = {}
    collectSubmenuOrders(order, self:getDefaultOrder(view), menu_id, include_nested == true, menus, {})
    if type(current_menu_items) == "table" then
        menus[menu_id] = util.tableDeepCopy(current_menu_items)
    end
    local preset_data = {
        format = "reorderingmenus_submenu_preset",
        version = 1,
        name = clean_name,
        menu_id = menu_id,
        menu_title = menu_title or menu_id,
        include_submenus = include_nested == true,
        menus = menus,
    }
    local file_path = string.format("%s/%s.lua", self:getSubmenuPresetsDir(view, menu_id), clean_name)
    local ok, err = util.writeToFile(dump(preset_data, nil, true), file_path, true, true)
    if not ok then return false, err end
    return true, file_path
end

function MenuOrderManager:listSubmenuPresets(view, menu_id)
    local dir = self:getSubmenuPresetsDir(view, menu_id)
    local presets = {}
    for file in lfs.dir(dir) do
        if file:sub(-4) == ".lua" and file:sub(1, 1) ~= "." then
            local path = string.format("%s/%s", dir, file)
            local ok, data = pcall(dofile, path)
            if ok and type(data) == "table"
                    and data.format == "reorderingmenus_submenu_preset"
                    and data.menu_id == menu_id and type(data.menus) == "table" then
                local menu_count = 0
                for _ in pairs(data.menus) do menu_count = menu_count + 1 end
                table.insert(presets, {
                    id = "submenu_" .. file:sub(1, -5),
                    name = data.name or file:sub(1, -5),
                    description = data.include_submenus
                        and string.format(_("Order for this menu and %d nested menu(s)"), math.max(0, menu_count - 1))
                        or _("Order for this menu only"),
                    include_submenus = data.include_submenus == true,
                    menu_count = menu_count,
                    path = path,
                })
            end
        end
    end
    table.sort(presets, function(a, b) return a.name:lower() < b.name:lower() end)
    return presets
end

-- Emit ids from extras_ordered into target at their curated stock slots:
-- both arrays are walked in parallel against default_list's ordering, and any
-- pending extra is flushed right before the next target entry that follows it
-- in the default layout. Extras without a default position (plugin items) are
-- appended at the end. Returns true when anything was inserted.
local function insert_extras_at_stock_slots(target, extras_ordered, default_list)
    if #extras_ordered == 0 then return false end
    local known = {}
    for _, id in ipairs(target) do known[id] = true end

    local dindex = nil
    if type(default_list) == "table" then
        dindex = {}
        for i, id in ipairs(default_list) do
            if dindex[id] == nil then dindex[id] = i end
        end
    end

    local ordered = {}
    local tail = {}
    if dindex then
        local with_pos = {}
        for _, ex in ipairs(extras_ordered) do
            if dindex[ex] then table.insert(with_pos, { id = ex, i = dindex[ex] })
            else table.insert(tail, ex) end
        end
        table.sort(with_pos, function(a, b) return a.i < b.i end)
        for _, e in ipairs(with_pos) do table.insert(ordered, e.id) end
        -- tail holds raw ids (entries with no default position), not records.
        for _, e in ipairs(tail) do table.insert(ordered, e) end
    else
        ordered = extras_ordered
    end

    local result, changed = {}, false
    local di = 1
    local oi = 1
    for _, uid in ipairs(target) do
        if uid == SEPARATOR_ID then
            table.insert(result, uid)
        else
            local match_k = nil
            if dindex and dindex[uid] and dindex[uid] >= di then
                match_k = dindex[uid]
            end
            if match_k then
                while oi <= #ordered do
                    local ex = ordered[oi]
                    local exi = dindex and dindex[ex]
                    if exi and exi < match_k then
                        if not known[ex] then
                            table.insert(result, ex)
                            known[ex] = true
                            changed = true
                        end
                        oi = oi + 1
                    else
                        break
                    end
                end
                di = match_k + 1
            end
            table.insert(result, uid)
        end
    end
    while oi <= #ordered do
        local ex = ordered[oi]
        if not known[ex] then
            table.insert(result, ex)
            known[ex] = true
            changed = true
        end
        oi = oi + 1
    end
    for i = #target, 1, -1 do target[i] = nil end
    for i, id in ipairs(result) do target[i] = id end
    return changed
end

local function mergeCapturedOrder(captured, current)
    local current_items = {}
    for _, item_id in ipairs(current) do
        if item_id ~= SEPARATOR_ID then current_items[item_id] = true end
    end

    local merged = {}
    local used = {}
    for _, item_id in ipairs(captured) do
        if item_id == SEPARATOR_ID then
            table.insert(merged, item_id)
        elseif current_items[item_id] and not used[item_id] then
            used[item_id] = true
            table.insert(merged, item_id)
        end
    end
    -- Preserve entries introduced after the preset was saved (for example by
    -- newly installed plugins) and place them after the captured ordering.
    for _, item_id in ipairs(current) do
        if item_id ~= SEPARATOR_ID and not used[item_id] then
            used[item_id] = true
            table.insert(merged, item_id)
        end
    end
    return merged
end

function MenuOrderManager:loadSubmenuPreset(view, menu_id, preset, current_menu_items)
    local data
    if type(preset) == "table" and preset.menus then
        data = preset
    elseif type(preset) == "table" and preset.path then
        local ok, result = pcall(dofile, preset.path)
        if ok then data = result end
    elseif type(preset) == "string" then
        local path = string.format("%s/%s.lua", self:getSubmenuPresetsDir(view, menu_id), preset)
        local ok, result = pcall(dofile, path)
        if ok then data = result end
    end

    if type(data) ~= "table" or data.format ~= "reorderingmenus_submenu_preset"
            or data.menu_id ~= menu_id or type(data.menus) ~= "table"
            or type(data.menus[menu_id]) ~= "table" then
        return false, _("Submenu preset not found or does not match this menu.")
    end

    local order = self:loadOrder(view)
    if type(order[menu_id]) ~= "table" then
        return false, _("Submenu not found.")
    end
    local previous_order = util.tableDeepCopy(order)
    for captured_menu_id, captured_items in pairs(data.menus) do
        if type(captured_items) == "table" and type(order[captured_menu_id]) == "table" then
            local current_items = order[captured_menu_id]
            if captured_menu_id == menu_id and type(current_menu_items) == "table" then
                current_items = current_menu_items
            end
            order[captured_menu_id] = mergeCapturedOrder(captured_items, current_items)
        end
    end

    local ok, result = self:saveOrder(view)
    if not ok then
        self.orders[view] = previous_order
        return false, result
    end
    return true, result
end

function MenuOrderManager:deleteSubmenuPreset(view, menu_id, preset)
    local path
    if type(preset) == "table" then
        path = preset.path
    elseif type(preset) == "string" then
        local clean_name, name_err = cleanPresetName(preset:gsub("^submenu_", ""))
        if not clean_name then return false, name_err end
        path = string.format("%s/%s.lua", self:getSubmenuPresetsDir(view, menu_id), clean_name)
    end
    if path and lfs.attributes(path, "mode") == "file" then
        local ok, data = pcall(dofile, path)
        if ok and type(data) == "table" and data.menu_id == menu_id then
            os.remove(path)
            return true
        end
    end
    return false, _("Submenu preset file not found.")
end

function MenuOrderManager:getHiddenBuiltinPath(view)
    return string.format("%s/.hidden_builtins.lua", self:getPresetsDir(view))
end

function MenuOrderManager:getHiddenBuiltinIds(view)
    local path = self:getHiddenBuiltinPath(view)
    if lfs.attributes(path) then
        local ok, res = pcall(dofile, path)
        if ok and type(res) == "table" then
            return res
        end
    end
    return {}
end

function MenuOrderManager:isBuiltinHidden(view, preset_id)
    if preset_id == "builtin_default" then return false end
    local hidden = self:getHiddenBuiltinIds(view)
    for __, hid in ipairs(hidden) do
        if hid == preset_id then return true end
    end
    return false
end

function MenuOrderManager:hideBuiltinPreset(view, preset_id)
    if preset_id == "builtin_default" then
        return false, _("Cannot delete the default preset.")
    end
    local hidden = self:getHiddenBuiltinIds(view)
    for __, hid in ipairs(hidden) do
        if hid == preset_id then return true end
    end
    table.insert(hidden, preset_id)
    local path = self:getHiddenBuiltinPath(view)
    local serialized = dump(hidden, nil, true)
    local ok, err = util.writeToFile(serialized, path, true, true)
    if not ok then return false, err end
    return true
end

function MenuOrderManager:unhideBuiltinPreset(view, preset_id)
    local hidden = self:getHiddenBuiltinIds(view)
    local new_hidden = {}
    local found = false
    for __, hid in ipairs(hidden) do
        if hid ~= preset_id then
            table.insert(new_hidden, hid)
        else
            found = true
        end
    end
    if not found then return false end
    local path = self:getHiddenBuiltinPath(view)
    if #new_hidden == 0 then
        os.remove(path)
    else
        local serialized = dump(new_hidden, nil, true)
        util.writeToFile(serialized, path, true, true)
    end
    return true
end

local function buildBuiltinPresets(view, default_order)
    local presets = {}

    table.insert(presets, {
        id = "builtin_default",
        name = _("Default (Stock KOReader)"),
        description = _("Standard factory menu layout. Selecting this empties the config file to restore stock."),
        is_builtin = true,
        order = default_order,
    })

    if view == "reader" then
        local reading_focused = util.tableDeepCopy(default_order)
        reading_focused["KOMenu:menu_buttons"] = { "typeset", "navi", "setting", "tools" }
        reading_focused["KOMenu:disabled"] = { "filemanager", "main", "search" }
        table.insert(presets, {
            id = "builtin_reading_focused",
            name = _("Reading Focused"),
            description = _("Puts Typeset and Navigation first; hides Search, Main, and Filemanager."),
            is_builtin = true,
            order = reading_focused,
        })

        local minimalist = util.tableDeepCopy(default_order)
        minimalist["KOMenu:menu_buttons"] = { "navi", "typeset" }
        minimalist["KOMenu:disabled"] = { "setting", "tools", "search", "filemanager", "main" }
        table.insert(presets, {
            id = "builtin_minimalist",
            name = _("Minimalist Reader"),
            description = _("Keeps only Navigation and Typeset tabs for a distraction-free experience."),
            is_builtin = true,
            order = minimalist,
        })

        local power_user = util.tableDeepCopy(default_order)
        power_user["KOMenu:menu_buttons"] = { "search", "navi", "typeset", "setting", "tools", "filemanager", "main" }
        power_user["KOMenu:disabled"] = {}
        table.insert(presets, {
            id = "builtin_power_user",
            name = _("Full Power User"),
            description = _("All tabs and submenus exposed with Search in the first position."),
            is_builtin = true,
            order = power_user,
        })
    else
        local clean_fm = util.tableDeepCopy(default_order)
        clean_fm["KOMenu:menu_buttons"] = { "filemanager_settings", "setting", "tools" }
        clean_fm["KOMenu:disabled"] = { "search", "filemanager", "main" }
        table.insert(presets, {
            id = "builtin_clean_fm",
            name = _("Clean File Manager"),
            description = _("Essential browsing and device tools without clutter."),
            is_builtin = true,
            order = clean_fm,
        })

        local power_user = util.tableDeepCopy(default_order)
        power_user["KOMenu:menu_buttons"] = { "filemanager_settings", "search", "setting", "tools", "filemanager", "main" }
        power_user["KOMenu:disabled"] = {}
        table.insert(presets, {
            id = "builtin_power_user",
            name = _("Full Power User"),
            description = _("All tabs and submenus visible."),
            is_builtin = true,
            order = power_user,
        })
    end

    return presets
end

function MenuOrderManager:getBuiltinPresets(view)
    local hidden = {}
    for _, id in ipairs(self:getHiddenBuiltinIds(view)) do
        hidden[id] = true
    end

    local visible = {}
    for _, preset in ipairs(buildBuiltinPresets(view, self:getDefaultOrder(view))) do
        if not hidden[preset.id] then
            table.insert(visible, preset)
        end
    end
    return visible
end

function MenuOrderManager:listUserPresets(view)
    local dir = self:getPresetsDir(view)
    local list = {}
    if lfs.attributes(dir) then
        for file in lfs.dir(dir) do
            if file:sub(-4) == ".lua" and file:sub(1,1) ~= "." then
                local name = file:sub(1, -5)
                -- Skip hidden file
                if name ~= ".hidden_builtins" then
                    local full_path = string.format("%s/%s", dir, file)
                    table.insert(list, {
                        id = "user_" .. name,
                        name = name,
                        description = _("Custom user preset"),
                        path = full_path,
                        is_builtin = false,
                    })
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return list
end

function MenuOrderManager:getAllPresets(view)
    local builtins = self:getBuiltinPresets(view)
    local user_presets = self:listUserPresets(view)
    local combined = {}
    for __, p in ipairs(builtins) do
        table.insert(combined, p)
    end
    for __, p in ipairs(user_presets) do
        table.insert(combined, p)
    end
    return combined
end

function MenuOrderManager:listDeletablePresets(view)
    local deletable = {}
    for _, p in ipairs(self:getAllPresets(view)) do
        if p.id ~= "builtin_default" then
            table.insert(deletable, p)
        end
    end
    return deletable
end

function MenuOrderManager:savePreset(view, preset_name)
    local clean_name, name_err = cleanPresetName(preset_name)
    if not clean_name then return false, name_err end

    local order = self:loadOrder(view)
    local dir = self:getPresetsDir(view)
    local file_path = string.format("%s/%s.lua", dir, clean_name)

    local serialized = dump(order, nil, true)
    local ok, err = util.writeToFile(serialized, file_path, true, true)
    if not ok then
        return false, err
    end
    return true, file_path
end

-- Overwrite an existing user preset file with the current layout.
-- Built-in presets are code-defined snapshots and cannot be updated; deleting
-- them only hides them from the list.
function MenuOrderManager:updatePreset(view, preset)
    local name, is_builtin
    if type(preset) == "table" then
        is_builtin = preset.is_builtin == true
            or (type(preset.id) == "string" and preset.id:sub(1, 8) == "builtin_")
        name = preset.name
            or (type(preset.path) == "string" and preset.path:match("([^/]+)%.lua$"))
    elseif type(preset) == "string" then
        name = preset
    end
    if is_builtin then
        return false, _("Built-in presets cannot be updated.")
    end
    if not name or name == "" then return false, _("Preset not found.") end
    local dir = self:getPresetsDir(view)
    local file_path = string.format("%s/%s.lua", dir, name)
    if lfs.attributes(file_path, "mode") ~= "file" then
        return false, _("Preset file not found.")
    end
    local order = self:loadOrder(view)
    self:sanitizeOrder(view)
    local ok, err = util.writeToFile(dump(order, nil, true), file_path, true, true)
    if not ok then return false, err end
    logger.info("ReorderingMenus: updated preset", name, "in", view)
    return true, file_path
end

function MenuOrderManager:loadPreset(view, preset)
    local preset_id
    local order
    if type(preset) == "table" and preset.order then
        order = util.tableDeepCopy(preset.order)
        preset_id = preset.id
    elseif type(preset) == "table" and preset.path then
        local ok, res = pcall(dofile, preset.path)
        if ok and type(res) == "table" then
            order = util.tableDeepCopy(res)
        else
            return false, _("Failed to load preset file.")
        end
        preset_id = preset.id
    elseif type(preset) == "string" then
        local dir = self:getPresetsDir(view)
        local file_path = string.format("%s/%s.lua", dir, preset)
        if lfs.attributes(file_path) then
            local ok, res = pcall(dofile, file_path)
            if ok and type(res) == "table" then
                order = util.tableDeepCopy(res)
            end
        end
        if not order then
            for _, b in ipairs(buildBuiltinPresets(view, self:getDefaultOrder(view))) do
                if b.name == preset or b.id == preset then
                    order = util.tableDeepCopy(b.order)
                    preset_id = b.id
                    break
                end
            end
        else
            preset_id = preset
        end
    else
        preset_id = preset and preset.id or nil
    end

    if not order then
        return false, _("Preset not found.")
    end

    -- Default preset should empty the config file (stock)
    if preset_id == "builtin_default" then
        self:resetOrder(view)
        -- Also clear the in-memory order to default
        self.orders[view] = util.tableDeepCopy(order)
        logger.info("ReorderingMenus: applied Default preset - reset to stock (emptied config)")
        return true
    end

    -- Preserve entries that were added AFTER this preset was saved (newly
    -- installed plugins, KOReader-update entries, brand-new tabs): applying a
    -- preset restores its own layout but must not erase configuration the
    -- snapshot never knew about. Such ids are appended to the same key they
    -- currently live under, keeping their hidden state.
    local previous_order = util.tableDeepCopy(self:loadOrder(view))
    local preset_ids = {}
    for __, preset_list in pairs(order) do
        if type(preset_list) == "table" then
            for ___, id in ipairs(preset_list) do
                if id ~= SEPARATOR_ID then preset_ids[id] = true end
            end
        end
    end
    local previous_disabled = {}
    for _, id in ipairs(previous_order["KOMenu:disabled"] or {}) do
        previous_disabled[id] = true
    end
    local default_order = self:getDefaultOrder(view)
    local appended = {}
    local newly_hidden_list = {}
    for menu_id, previous_list in pairs(previous_order) do
        if menu_id ~= "KOMenu:disabled" and type(previous_list) == "table"
                and type(order[menu_id]) == "table" then
            local already_there = {}
            for _, id in ipairs(order[menu_id]) do already_there[id] = true end
            -- Visible extras are slot-aligned against the stock layout;
            -- hidden extras go straight to KOMenu:disabled (they must not be
            -- double-listed in the visible list, or they would render).
            local visible_extras = {}
            for _, id in ipairs(previous_list) do
                if id ~= SEPARATOR_ID and not preset_ids[id]
                        and not already_there[id] and not appended[id] then
                    appended[id] = true
                    if previous_disabled[id] then
                        table.insert(newly_hidden_list, id)
                        logger.info("ReorderingMenus: preset applied - kept entry",
                            id, "(hidden) added since this preset was saved")
                    else
                        table.insert(visible_extras, id)
                        logger.info("ReorderingMenus: preset applied - kept entry",
                            id, "added since this preset was saved")
                    end
                end
            end
            if #visible_extras > 0 then
                insert_extras_at_stock_slots(order[menu_id], visible_extras,
                    default_order[menu_id])
            end
        end
    end
    for _, id in ipairs(newly_hidden_list) do
        if type(order["KOMenu:disabled"]) ~= "table" then
            order["KOMenu:disabled"] = {}
        end
        table.insert(order["KOMenu:disabled"], id)
    end

    -- Hidden entries live outside every list (hiding removes them from their
    -- parent), so the scan above cannot see them. Carry over any currently
    -- hidden id the preset does not know about, keeping its hidden state.
    local preset_disabled = {}
    for _, id in ipairs(order["KOMenu:disabled"] or {}) do
        preset_disabled[id] = true
    end
    for _, id in ipairs(previous_order["KOMenu:disabled"] or {}) do
        if id ~= SEPARATOR_ID and not preset_ids[id] and not preset_disabled[id]
                and not appended[id] then
            if type(order["KOMenu:disabled"]) ~= "table" then
                order["KOMenu:disabled"] = {}
            end
            table.insert(order["KOMenu:disabled"], id)
            appended[id] = true
            logger.info("ReorderingMenus: preset applied - kept hidden entry", id,
                "added since this preset was saved")
        end
    end

    -- User-created submenu titles travel in KOMenu:custom_submenus, which a
    -- preset saved before the submenu existed cannot know about. Merging the
    -- preset's registry over the current one keeps a display name for every
    -- surviving custom id instead of degrading "hello" back to a raw id label.
    local merged_customs = {}
    local previous_registry = previous_order[CUSTOM_SUBMENUS_KEY]
    if type(previous_registry) == "table" then
        for custom_id, title in pairs(previous_registry) do
            if type(title) == "string" and title ~= "" then
                merged_customs[custom_id] = title
            end
        end
    end
    if type(order[CUSTOM_SUBMENUS_KEY]) == "table" then
        for custom_id, title in pairs(order[CUSTOM_SUBMENUS_KEY]) do
            if type(title) == "string" and title ~= "" then
                merged_customs[custom_id] = title
            end
        end
    end
    if next(merged_customs) then
        order[CUSTOM_SUBMENUS_KEY] = merged_customs
    end

    -- A preset older than a created submenu knows its reference was added
    -- afterwards (kept above) but carries no content level for it. Restore
    -- each still-referenced custom's list so the level itself survives;
    -- unreferenced ids stay untouched so deletions are not resurrected.
    local function order_referenced(search_order, target_id)
        for search_key, search_list in pairs(search_order) do
            if search_key ~= "KOMenu:disabled" and search_key ~= CUSTOM_SUBMENUS_KEY
                    and type(search_list) == "table" then
                for _, child_id in ipairs(search_list) do
                    if child_id == target_id then return true end
                end
            end
        end
        return false
    end
    for custom_id in pairs(merged_customs) do
        if type(order[custom_id]) ~= "table"
                and type(previous_order[custom_id]) == "table"
                and order_referenced(order, custom_id) then
            order[custom_id] = util.tableDeepCopy(previous_order[custom_id])
            logger.info("ReorderingMenus: preset applied - restored created submenu",
                custom_id)
        end
    end

    self.orders[view] = order

    -- Re-align stock entries that were preserved from after this preset was
    -- saved: the merge above appends them at the end of their keys, but their
    -- curated default slots are still valid, so restore those positions.
    self:reconcileDefaultEntries(view)

    self.recent_moves[view] = {}
    local disabled = {}
    for _, item_id in ipairs(order["KOMenu:disabled"] or {}) do disabled[item_id] = true end
    local origins = loadPluginState().hidden_origins[view]
    for item_id in pairs(origins) do
        if not disabled[item_id] then origins[item_id] = nil end
    end
    savePluginState()
    local ok, res = self:saveOrder(view)
    return ok, res
end

function MenuOrderManager:deletePreset(view, preset_name)
    for _, b in ipairs(buildBuiltinPresets(view, self:getDefaultOrder(view))) do
        if b.id == preset_name or b.name == preset_name then
            if b.id == "builtin_default" then
                return false, _("Cannot delete the default preset.")
            end
            return self:hideBuiltinPreset(view, b.id)
        end
    end

    local dir = self:getPresetsDir(view)
    local file_path = string.format("%s/%s.lua", dir, preset_name)
    if lfs.attributes(file_path) then
        os.remove(file_path)
        return true
    end
    local clean_name = preset_name:gsub("^user_", "")
    file_path = string.format("%s/%s.lua", dir, clean_name)
    if lfs.attributes(file_path) then
        os.remove(file_path)
        return true
    end
    return false, _("Preset file not found.")
end

return MenuOrderManager

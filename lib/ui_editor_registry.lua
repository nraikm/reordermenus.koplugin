--[[--
Tracks currently open item editors so saved cross-menu moves can refresh both
the source and destination without coupling that bookkeeping to screen setup.

Lifetime model: editors are held WEAKLY (weak-key sets). An entry survives
only while the widget is referenced elsewhere — UIManager keeps every shown
dialog alive, so all legitimately open editors stay registered. If teardown
skips onClose (abnormal close, crashed dialog), the last strong reference
disappears and the next full garbage collection reclaims the entry: dead
editors cannot accumulate over long sessions and no stale callback ever
fires at an abandoned widget. Normal synchronization is unaffected while
widgets are alive; empty groups are pruned whenever the registry is read.
--]]

local logger = require("logger")

local UIEditorRegistry = {
    -- view -> menu_id -> weak-keyed SET of live editor widgets
    -- (set, not array: no holes when GC reclaims an entry mid-session).
    editors = {},
}

local function newEntrySet()
    return setmetatable({}, { __mode = "k" })
end

function UIEditorRegistry:register(view, menu_id, widget)
    if type(widget) ~= "table" then return end
    local menus = self.editors[view]
    if not menus then
        menus = {}
        self.editors[view] = menus
    end
    local entries = menus[menu_id]
    if not entries then
        entries = newEntrySet()
        menus[menu_id] = entries
    end
    entries[widget] = true
end

function UIEditorRegistry:unregister(widget)
    if type(widget) ~= "table" then return end
    for _, menus in pairs(self.editors) do
        for _, entries in pairs(menus) do
            entries[widget] = nil
        end
    end
end

-- Prune view/menu groups whose editors were all reclaimed. Called on every
-- notify so bookkeeping tables cannot grow without bound either.
function UIEditorRegistry:_compact()
    for view, menus in pairs(self.editors) do
        for menu_id, entries in pairs(menus) do
            if next(entries) == nil then menus[menu_id] = nil end
        end
        if next(menus) == nil then self.editors[view] = nil end
    end
end

-- Number of live registered editors, optionally scoped to one view.
-- Diagnostic/test helper; also forces pruning of emptied groups.
function UIEditorRegistry:countLive(view)
    self:_compact()
    if view then
        local menus = self.editors[view]
        if not menus then return 0 end
        local n = 0
        for _, entries in pairs(menus) do
            if next(entries) then n = n + 1 end
        end
        return n
    end
    local n = 0
    for _, menus in pairs(self.editors) do
        for _, entries in pairs(menus) do
            for _ in pairs(entries) do n = n + 1 end
        end
    end
    return n
end

local function notifyEditors(entries, method, item_id)
    if type(entries) ~= "table" then return end
    -- Snapshot first: sync callbacks may open/close editors, which mutates
    -- these weak sets; iterating a copy keeps that well-defined.
    local live = {}
    for widget in pairs(entries) do
        live[#live + 1] = widget
    end
    for _, widget in ipairs(live) do
        if type(widget.item_table) == "table"
                and type(widget[method]) == "function" then
            local ok, err = pcall(widget[method], widget, item_id)
            if not ok then
                logger.err("ReorderingMenus: editor sync failed:", method, err)
            end
        end
    end
end

function UIEditorRegistry:notifyMove(view, item_id, from_menu_id, to_menu_id)
    self:_compact()
    local menus = self.editors[view]
    if not menus then return end
    notifyEditors(menus[to_menu_id], "syncMovedIn", item_id)
    notifyEditors(menus[from_menu_id], "syncMovedOut", item_id)
end

return UIEditorRegistry

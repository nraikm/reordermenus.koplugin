--[[--
Reordering Menus KOReader Plugin
Allows reordering, customizing, and hiding menus and menu items in both
Book view (Reader) and Normal view (File manager).
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

-- Register the plugin's menu item into KOReader's default menu order
pcall(function()
    require("ui/plugin/insert_menu").add("reordering_menus")
end)

-- KOReader's MenuSorter crashes ("attempt to index local 'sorting_hint_menu'
-- (a nil value)") when an orphaned menu item's sorting_hint points at a menu
-- that does not exist in the rendered tree. The typical trigger is a user
-- plugin item that was never anchored in the saved order (registered after the
-- last reconciliation, or left over from an older configuration) combined with
-- this plugin hiding that hint's anchor tab: every subsequent launch then fails
-- to build the top menu at all. Neutralize such hints before sorting: items
-- whose hint target is hidden stay hidden, items pointing at an unknown menu
-- fall back to KOReader's own first-menu orphan handling.
do
    local ok_sorter, MenuSorter = pcall(require, "ui/menusorter")
    if ok_sorter and type(MenuSorter) == "table"
            and type(MenuSorter.sort) == "function"
            and not MenuSorter.reordering_menus_hint_guard then
        local orig_sort = MenuSorter.sort
        MenuSorter.sort = function(self, item_table, order)
            if type(item_table) == "table" and type(order) == "table" then
                local reachable_lists = {}
                local listed = {}
                local disabled = {}
                for _, id in ipairs(order["KOMenu:disabled"] or {}) do
                    disabled[id] = true
                end
                local function mark(list)
                    for _, id in ipairs(list or {}) do
                        listed[id] = true
                        if type(order[id]) == "table" and not reachable_lists[id] then
                            reachable_lists[id] = true
                            mark(order[id])
                        end
                    end
                end
                mark(order["KOMenu:menu_buttons"])
                for id, item in pairs(item_table) do
                    local hint = type(item) == "table" and item.sorting_hint
                    if type(hint) == "string" and not reachable_lists[hint]
                            and not listed[id] then
                        -- Only unconsumed items reach orphan handling, so an
                        -- item that is also configured under a rendered menu
                        -- must be left alone.
                        if disabled[hint] then
                            -- The hint target is deliberately hidden; keep the
                            -- item hidden with it instead of leaking it into a
                            -- visible menu.
                            item_table[id] = nil
                        else
                            -- Unknown/stale target: use stock fallback instead
                            -- of crashing on it.
                            item.sorting_hint = nil
                        end
                    end
                end
            end
            return orig_sort(self, item_table, order)
        end
        MenuSorter.reordering_menus_hint_guard = true
    end
end

-- User-created submenus have no provider widget, so KOReader's item table
-- never contains their ids and MenuSorter would silently drop them from every
-- rebuilt menu. Before sorting, synthesize a minimal entry for each created
-- submenu referenced by the order being rendered; its display title comes
-- from the order's own KOMenu:custom_submenus registry (see
-- MenuOrderManager:createSubmenu). Entries not referenced by any parent list
-- (deleted rows, hidden submenus) stay unsynthesized so they cannot leak into
-- orphan handling as "NEW:" items. The registry key itself is temporarily
-- removed because MenuSorter's generic order loop cannot know it is metadata.
do
    local ok_sorter, MenuSorter = pcall(require, "ui/menusorter")
    if ok_sorter and type(MenuSorter) == "table"
            and type(MenuSorter.sort) == "function"
            and not MenuSorter.reordering_menus_custom_submenu_guard then
        local orig_sort = MenuSorter.sort
        local REGISTRY_KEY = "KOMenu:custom_submenus"
        MenuSorter.sort = function(self, item_table, order)
            local registry = type(order) == "table" and order[REGISTRY_KEY] or nil
            if type(registry) == "table" then
                pcall(function()
                    local disabled_ids = {}
                    for _, id in ipairs(order["KOMenu:disabled"] or {}) do
                        disabled_ids[id] = true
                    end
                    local referenced = {}
                    for order_id, list in pairs(order) do
                        if order_id ~= REGISTRY_KEY and type(list) == "table" then
                            for _, child_id in ipairs(list) do
                                referenced[child_id] = true
                            end
                        end
                    end
                    for submenu_id, title in pairs(registry) do
                        if type(title) == "string" and title ~= ""
                                and referenced[submenu_id] and not disabled_ids[submenu_id]
                                and item_table[submenu_id] == nil
                                and type(order[submenu_id]) == "table" then
                            item_table[submenu_id] = { text = tostring(title) }
                        end
                    end
                end)
                -- Hide the metadata from MenuSorter's generic loop, then put
                -- it back so the caller's order table keeps its shape.
                order[REGISTRY_KEY] = nil
                local ok_sort, result = pcall(orig_sort, self, item_table, order)
                order[REGISTRY_KEY] = registry
                if not ok_sort then error(result, 0) end
                return result
            end
            return orig_sort(self, item_table, order)
        end
        MenuSorter.reordering_menus_custom_submenu_guard = true
    end
end

local UIScreens = require("ui_screens")

local ReorderingMenus = WidgetContainer:extend{
    name = "reorderingmenus",
}

function ReorderingMenus:init()
    UIScreens:initView(self.ui)
    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end
    local view = UIScreens:getCurrentView(self)
    -- The initial File Manager launch does not consistently emit
    -- ShowFileManager. Reconcile once now to repair existing order files, then
    -- once on the next UI tick after the remaining plugins have registered.
    UIScreens:reconcileRegisteredItems(self, view, true)
    UIManager:nextTick(function()
        if self.ui and self.ui.menu then
            UIScreens:reconcileRegisteredItems(self, UIScreens:getCurrentView(self), true)
        end
    end)
end

function ReorderingMenus:onReaderReady()
    UIScreens.current_view = "reader"
    UIScreens:reconcileRegisteredItems(self, "reader", true)
end

function ReorderingMenus:onShowFileManager()
    UIScreens.current_view = "filemanager"
    UIScreens:reconcileRegisteredItems(self, "filemanager", true)
end

function ReorderingMenus:showReorderScreen()
    UIScreens:showTabReorderDialog(self, UIScreens:getCurrentView(self))
end

function ReorderingMenus:addToMainMenu(menu_items)
    menu_items.reordering_menus = {
        text = _("Reorder menus"),
        sorting_hint = "more_tools",
        callback = function()
            self:showReorderScreen()
        end,
    }
end

return ReorderingMenus

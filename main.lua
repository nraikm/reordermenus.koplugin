--[[--
Reordering Menus KOReader Plugin
Allows reordering, customizing, and hiding menus and menu items in both
Book view (Reader) and Normal view (File manager).

Architecture: sparse declarative user intent. The plugin persists only what
the user actually did; every menu is materialized from the current KOReader
defaults plus that intent, written back as minimal native overrides, and left
to the stock MenuSorter. See README.md ("Architecture") for the pipeline.
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
local UIScreens = require("reorderingmenus_ui_screens")

-- Register the plugin's menu item into KOReader's default menu order.
-- ui/plugin/insert_menu is process-singleton state that mutates the shared
-- order tables directly and offers no duplicate protection ("callers are
-- expected to call add() only once"), so guard against any re-execution of
-- this module within one process before asking it to insert.
pcall(function()
    local already_inserted = false
    local ok, fm_order = pcall(require, "ui/elements/filemanager_menu_order")
    if ok and type(fm_order) == "table" and type(fm_order.more_tools) == "table" then
        for _, id in ipairs(fm_order.more_tools) do
            if id == "reordering_menus" then already_inserted = true break end
        end
    end
    if not already_inserted then
        require("ui/plugin/insert_menu").add("reordering_menus")
    end
end)

-- MenuSorter compatibility guards live in the adapter now.
KoreaderAdapter.installMenuSorterGuards()

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
    -- ShowFileManager. Refresh the live registry once now (picking up late
    -- registrations), then once more on the next UI tick.
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

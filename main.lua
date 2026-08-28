--[[--
Reordering Menus KOReader Plugin
Allows reordering, customizing, and hiding menus and menu items in Book view
and File Manager.

Architecture: sparse declarative user intent. The plugin persists only what
the user actually did; every menu is materialized from the current KOReader
defaults plus that intent, written back as minimal native overrides, and left
to the stock MenuSorter. See docs/architecture.md for the pipeline.
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
local UIScreens = require("reorderingmenus_ui_screens")

-- P1B (#11): no ui/plugin/insert_menu call. The old mechanism mutated the
-- SHARED ui/elements/*_menu_order tables (process-singleton, no duplicate
-- protection) to make this plugin a "placed" stock row. Our addToMainMenu
-- entry instead carries sorting_hint = "more_tools", and stock MenuSorter
-- attaches hinted orphans to their target menu at every build (implicit
-- anchoring) - in both reader and filemanager views, with zero writes to
-- KOReader-owned modules. Bonus: our own id is now correctly attributed to
-- THIS plugin, so disabling the plugin cleanly releases (not freezes) its
-- slot via the removal-tombstone lifecycle.
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

-- P1B (#5): no onShowFileManager handler. KOReader never emits a
-- ShowFileManager event anywhere in its frontend (verified against the
-- bundled source); FileManager plugins are registered synchronously during
-- FileManager:init(), which the plugin's init + nextTick reconciliation
-- already covers. A dead event handler was deleted, not re-timed.

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

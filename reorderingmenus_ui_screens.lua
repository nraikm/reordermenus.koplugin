--[[--
UI screens and interactive dialogs for KOReader Reordering Menus plugin.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local dump = require("dump")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local SortWidget = require("ui/widget/sortwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local util = require("util")
local _ = require("gettext")

local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local MenuTitles = require("reorderingmenus_menu_titles")
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
local UICompat = require("reorderingmenus_ui_compat")
local UIEditorModel = require("reorderingmenus_ui_editor_model")
local UIEditorRegistry = require("reorderingmenus_ui_editor_registry")

-- Stage 1: isolate KOReader-private compatibility from ordinary screen code.
UICompat.installSortWidgetSubmenuTap(SortWidget)

local UIScreens = {
    current_view = "reader", -- "reader" or "filemanager"
    needs_restart = false,
}

local EMPTY_HINT_ID = UIEditorModel.EMPTY_HINT_ID

local function emptyHintRow()
    return {
        text = _("(No items in this menu)"),
        item_id = EMPTY_HINT_ID,
        checked_func = function() return true end,
        callback = function() end,
    }
end

local function refreshPaging(widget, preferred_index)
    if not widget or type(widget.item_table) ~= "table" then return end
    widget.pages, widget.show_page = UIEditorModel.pageFor(
        #widget.item_table, widget.items_per_page, widget.show_page,
        preferred_index)
    widget:_populateItems()
end

local function showButtonMenu(buttons, options)
    options = options or {}
    local dialog = ButtonDialog:new{
        title = options.title,
        title_align = options.title_align,
        shrink_unneeded_width = options.shrink_unneeded_width,
        buttons = buttons,
        anchor = options.anchor,
    }
    UIManager:show(dialog)
    return dialog
end

function UIScreens:showError(message)
    UIManager:show(InfoMessage:new{ text = tostring(message) })
end

function UIScreens:showNotice(message)
    UIManager:show(Notification:new{ text = tostring(message) })
end

function UIScreens:reloadLiveMenu(plugin, view)
    if not (plugin and plugin.ui) then return true end
    local ok, err = MenuOrderManager:applyLiveReload(plugin.ui, view)
    if not ok then
        self:showError(string.format(
            _("The saved menu could not be refreshed live:\n%s"), tostring(err)))
        return false, err
    end
    return true
end

-- Stage 2: keep cross-editor synchronization behind one small registry.
function UIScreens:_notifyEditorsOfMove(view, item_id, from_menu_id, to_menu_id)
    UIEditorRegistry:notifyMove(view, item_id, from_menu_id, to_menu_id)
end

local function id_lists_match(a, b)
    return UIEditorModel.idsMatch(a, b)
end

-- Discarding reverts every unsaved in-memory mutation (visibility toggles,
-- staged reordering) by dropping the staged transaction and re-deriving the
-- working state from canonical intent, exactly like a restart would.
-- Already-saved actions (cross-menu moves, presets, resets) are unaffected.
local function reloadWorkingOrderFromDisk(view)
    MenuOrderManager:reloadFromDisk(view)
    return MenuOrderManager:loadOrder(view)
end

-- User-created submenus have no KOReader-provided text, so resolve their
-- display title from the order's registry before falling back to MenuTitles
-- (whose last resort is a mechanical humanize of the id).
function UIScreens:getDisplayTitle(view, item_id, live_items_by_id)
    return MenuOrderManager:getCustomSubmenuTitle(view, item_id)
        or MenuTitles:getTitle(item_id, live_items_by_id)
end

-- KOReader's MenuSorter titles a submenu marker with the content's static
-- text only (sub_menu_position.text = sub_menu_content.text), dropping
-- text_func. A submenu registered with a dynamic-only title therefore
-- renders as the literal string "nil" once it is relocated by a layout.
-- Walk the rebuilt tree and give every renderable row a usable title.
function UIScreens:sanitizeLiveMenuTree(tree)
    if type(tree) ~= "table" then return end
    for _, entry in ipairs(tree) do
        if type(entry) == "table" then
            if type(entry[1]) == "table" then
                -- A menu level array (e.g. a top-level tab's content):
                -- sanitize its rows.
                self:sanitizeLiveMenuTree(entry)
            else
                -- A rendered row: make sure it can produce a title.
                local has_title = type(entry.text) == "string"
                    or type(entry.text_func) == "function"
                if not has_title and entry.separator ~= true then
                    local ok, title = pcall(MenuTitles.getTitle, MenuTitles, entry.id)
                    entry.text = ok and title or tostring(entry.id)
                end
                if type(entry.sub_item_table) == "table" then
                    self:sanitizeLiveMenuTree(entry.sub_item_table)
                end
            end
        end
    end
end

function UIScreens:initView(ui)
    if ui and ui.document then
        self.current_view = "reader"
    else
        self.current_view = "filemanager"
    end
end

function UIScreens:getCurrentView(plugin)
    local active_plugin = plugin or self.plugin
    local ui = active_plugin and active_plugin.ui
    if ui and ui.document then
        return "reader"
    end
    return self.current_view or "filemanager"
end

function UIScreens:_collectRegisteredMenuItems(plugin)
    local active_plugin = plugin or self.plugin
    local menu = active_plugin and active_plugin.ui and active_plugin.ui.menu
    local menu_items, providers, owners = {}, {}, {}
    for _, widget in pairs(menu and menu.registered_widgets or {}) do
        if widget and type(widget.addToMainMenu) == "function" then
            local widget_name = type(widget) == "table" and widget.name or nil
            pcall(function()
                local captured = {}
                widget:addToMainMenu(captured)
                for id, item in pairs(captured) do
                    -- Deterministic attribution under collision: smallest
                    -- widget name owns the id's attributes (mirrors
                    -- KoreaderAdapter.collectLiveRegistrations). Multiple
                    -- contributors are recorded so the registry can flag the
                    -- id as having an unstable identity (no anchored pins).
                    if widget_name then
                        local key = tostring(widget_name)
                        local known = owners[id]
                        if not known then
                            owners[id] = { min = key, all = { [key] = true } }
                            providers[id] = widget_name
                            menu_items[id] = item
                        else
                            known.all[key] = true
                            if key < known.min then
                                known.min = key
                                providers[id] = widget_name
                                menu_items[id] = item
                            end
                        end
                    else
                        menu_items[id] = menu_items[id] or item
                    end
                end
            end)
        end
    end
    -- Propagate collision info into the collected items (registry reads it).
    for id, known in pairs(owners or {}) do
        local count = 0
        for _ in pairs(known.all) do count = count + 1 end
        if count > 1 and menu_items[id] then
            local names = {}
            for n in pairs(known.all) do names[#names + 1] = n end
            table.sort(names)
            menu_items[id].colliding_providers = names
        end
    end
    return menu_items, providers
end

function UIScreens:reconcileRegisteredItems(plugin, view, persist)
    if plugin then self.plugin = plugin end
    local items, providers = self:_collectRegisteredMenuItems(plugin)
    -- The materializer anchors newcomers implicitly; this only refreshes the
    -- ephemeral base registry so projections reflect current contributions.
    local changed = MenuOrderManager:reconcileRegisteredItems(view, items, providers)
    if changed and persist then return MenuOrderManager:saveOrder(view) end
    return changed
end

function UIScreens:reconcileLiveMenuItems(plugin, view, menu_id)
    local live_ids = self:_getLiveMenuItems(plugin, menu_id)
    return MenuOrderManager:reconcileMenuItems(view, menu_id, live_ids)
end

function UIScreens:promptRestart(msg)
    local message_text = msg or _("Menu order changes have been saved. Would you like to restart KOReader now for all changes to take full effect?")
    UIManager:show(ConfirmBox:new{
        text = message_text,
        ok_text = _("Restart now"),
        ok_callback = function()
            UIManager:broadcastEvent(Event:new("Restart"))
        end,
        cancel_text = _("Restart later"),
    })
end

function UIScreens:checkPromptRestartOnExit()
    if not self.needs_restart then return end
    self.needs_restart = false
    UIManager:nextTick(function()
        self:promptRestart()
    end)
end

function UIScreens:_getHiddenForMenu(view, menu_id)
    local disabled = MenuOrderManager:getDisabledItems(view)
    if #disabled == 0 then return {} end
    local default_order = MenuOrderManager:getDefaultOrder(view)
    local hidden_for_menu = {}
    local default_list = default_order[menu_id] or {}
    for _, item_id in ipairs(disabled) do
        if MenuOrderManager:getHiddenItemParent(view, item_id) == menu_id then
            table.insert(hidden_for_menu, item_id)
        else
            for _, default_id in ipairs(default_list) do
                if default_id == item_id then
                    table.insert(hidden_for_menu, item_id)
                    break
                end
            end
        end
    end
    return hidden_for_menu
end

-- Resolve the authoritative live menu tree, preferring the active menu and
-- falling back to the topmost KOReader base window when a plugin instance
-- still holds an older reference.
function UIScreens:_resolveTabItemTable(plugin)
    local menu = plugin and plugin.ui and plugin.ui.menu
    local function getTabItemTable(active_menu)
        if not active_menu then return nil end
        if type(active_menu.tab_item_table) ~= "table"
                and type(active_menu.setUpdateItemTable) == "function" then
            pcall(active_menu.setUpdateItemTable, active_menu)
        end
        if type(active_menu.tab_item_table) == "table" then
            return active_menu.tab_item_table
        end
    end

    local tab_item_table = getTabItemTable(menu)
    if type(tab_item_table) ~= "table" then
        for i = #(UIManager._window_stack or {}), 1, -1 do
            local entry = UIManager._window_stack[i]
            local widget = entry and (entry.widget or entry)
            local candidates = {
                widget or false,
                widget and widget.ui or false,
                widget and widget.show_parent or false,
            }
            for _, candidate in ipairs(candidates) do
                local active_menu = candidate and candidate.menu
                tab_item_table = getTabItemTable(active_menu)
                if type(tab_item_table) == "table" then break end
            end
            if type(tab_item_table) == "table" then break end
        end
    end
    if type(tab_item_table) ~= "table" then return nil end
    return tab_item_table
end

-- Return the direct children of a menu as KOReader currently renders them.
-- Depending on where a menu lives, KOReader may represent its contents either
-- in sub_item_table or directly in the menu table itself.
function UIScreens:_getLiveMenuItems(plugin, menu_id)
    local tab_item_table = self:_resolveTabItemTable(plugin)
    if type(tab_item_table) ~= "table" then
        return {}, {}, false
    end

    local live_menu
    local ok_sorter, MenuSorter = pcall(require, "ui/menusorter")
    if ok_sorter and MenuSorter and MenuSorter.findById then
        live_menu = MenuSorter:findById(tab_item_table, menu_id)
    end

    if not live_menu then
        return {}, {}, false
    end

    local children = type(live_menu.sub_item_table) == "table"
        and live_menu.sub_item_table or live_menu
    local ids = {}
    local items_by_id = {}
    for _, item in ipairs(children) do
        if type(item) == "table" and item.id
                and item.id ~= MenuOrderManager.SEPARATOR_ID then
            table.insert(ids, item.id)
            items_by_id[item.id] = item
        end
    end
    return ids, items_by_id, true
end

-- Every id KOReader could render right now: anything present in the rebuilt
-- live tree plus everything currently registered widgets would contribute to
-- menu_items. Used to keep entries whose provider is gone (uninstalled or
-- disabled plugin) out of the editors entirely.
function UIScreens:_collectRenderableIds(plugin)
    local ids = {}
    local ok_tree, tree = pcall(self._resolveTabItemTable, self, plugin)
    if ok_tree and type(tree) == "table" then
        local function walk(node)
            for _, entry in ipairs(node) do
                if type(entry) == "table" then
                    if entry.id then ids[entry.id] = true end
                    if type(entry.sub_item_table) == "table" then
                        walk(entry.sub_item_table)
                    elseif #entry > 0 then
                        walk(entry)
                    end
                end
            end
        end
        walk(tree)
    end
    local ok_collect, registered = pcall(self._collectRegisteredMenuItems, self, plugin)
    if ok_collect and type(registered) == "table" then
        for id in pairs(registered) do
            ids[id] = true
        end
    end
    return ids
end

-- Keep configured ordering for items that are actually registered, then add
-- newly registered plugin items in their live KOReader order. Missing entries
-- are returned separately so saving another change does not destroy data for a
-- feature that may only be temporarily unavailable on this device/document.
--
-- renderable_ids (optional): set of ids KOReader can currently render anywhere
-- (live tree + registered widget contributions). When provided, configured
-- ids absent from it - e.g. entries whose provider plugin was uninstalled -
-- are kept out of the editor display entirely while unavailable_items still
-- preserves them in the saved order for a future reinstall. Callers that omit
-- it get the older, always-visible behaviour.
function UIScreens:_mergeConfiguredAndLiveItems(
        configured_items, hidden_items, live_ids, has_live_menu, recent_moves, menu_id,
        renderable_ids)
    local hidden = {}
    for _, id in ipairs(hidden_items or {}) do hidden[id] = true end

    -- A recent cross-menu move record is { from = ..., to = ... }. The live
    -- tree may still show the item in its old menu; trust the record instead.
    local function moved_elsewhere(id)
        local rec = recent_moves and recent_moves[id]
        return rec ~= nil and rec.to ~= menu_id
    end

    local live = {}
    for _, id in ipairs(live_ids or {}) do
        -- Ignore a stale live copy left in the old menu after a move.
        if not moved_elsewhere(id) then
            live[id] = true
        end
    end

    local merged = {}
    local seen = {}
    local unavailable = {}
    for _, id in ipairs(configured_items or {}) do
        if id == MenuOrderManager.SEPARATOR_ID then
            table.insert(merged, id)
        elseif hidden[id] then
            -- Hidden entries are appended by the caller with their hidden state.
        elseif not has_live_menu or live[id]
                or (recent_moves and recent_moves[id]
                    and recent_moves[id].to == menu_id) then
            if not seen[id] then
                table.insert(merged, id)
                seen[id] = true
            end
        else
            -- Missing from the current live snapshot. The snapshot can be
            -- stale (built before a reset restored the item, before a late
            -- registering plugin ran, or after a failed rebuild), so hiding
            -- the row would make a configured item unmanageable - the
            -- reported "plugin items disappear from the editor but stay in
            -- the menu" bug. Keep it visible as long as KOReader could render
            -- it somewhere; entries no provider can produce are dropped from
            -- the display entirely. unavailable_items still preserves both in
            -- the saved order.
            local rec = recent_moves and recent_moves[id]
            local moved_away = rec ~= nil and rec.to ~= menu_id
            if not moved_away and (renderable_ids == nil or renderable_ids[id])
                    and not seen[id] then
                table.insert(merged, id)
                seen[id] = true
            end
            table.insert(unavailable, id)
        end
    end

    if has_live_menu then
        for _, id in ipairs(live_ids or {}) do
            if not moved_elsewhere(id)
                    and not hidden[id] and not seen[id] then
                table.insert(merged, id)
                seen[id] = true
            end
        end
    end
    return merged, unavailable
end

function UIScreens:saveAndApply(plugin, view, silent)
    local active_plugin = plugin or self.plugin
    local ui = active_plugin and active_plugin.ui
    self:reconcileRegisteredItems(active_plugin, view, false)
    local ok, path = MenuOrderManager:saveOrder(view)
    if ok then
        self.needs_restart = true
        if ui then
            self:reloadLiveMenu(active_plugin, view)
        end
        local view_name = view == "reader" and _("Book view") or _("Normal view")
        if not silent then
            self:showNotice(string.format(_("%s menu order saved."), view_name))
        end
        return true, path
    else
        self:showError(string.format(_("Error saving configuration:\n%s"),
            tostring(path)))
        return false, path
    end
end

function UIScreens:prepareForRemoval(plugin)
    local restored = KoreaderAdapter.prepareForPluginRemoval()
    local count = #restored.reader + #restored.filemanager
    if plugin and plugin.ui then
        self:reloadLiveMenu(plugin, self:getCurrentView(plugin))
    end
    if not restored.ok then
        self:showError(string.format(
            _("Restored %d item(s), but %d operation(s) failed. Do not remove the plugin yet."),
            count, #restored.failures))
        return false, restored
    end
    self:showError(count > 0
        and string.format(
            _("Restored %d hidden item(s). It is now safe to remove Reordering Menus."),
            count)
        or _("Nothing was hidden. It is safe to remove Reordering Menus."))
    return true, restored
end

function UIScreens:confirmResetSubmenu(plugin, view, menu_id, menu_title, on_success)
    UIManager:show(ConfirmBox:new{
        text = string.format(_("Reset %s menu to default?"), menu_title),
        ok_text = _("Reset"),
        ok_callback = function()
            local reset_ok, pulled_back = MenuOrderManager:resetSubmenu(view, menu_id)
            if not reset_ok then
                self:showError(string.format(
                    _("No default layout is available for %s."), menu_title))
                return
            end

            -- Items pulled back to this menu by the reset leave their old
            -- locations: drop them from any still-open editors there (e.g. a
            -- parent menu editor during drill-down) so a later save of those
            -- stale snapshots cannot duplicate the items.
            for item_id, old_parent in pairs(pulled_back or {}) do
                self:_notifyEditorsOfMove(view, item_id, old_parent, menu_id)
            end

            self:reconcileRegisteredItems(plugin, view, false)
            local ok, err = MenuOrderManager:saveOrder(view)
            if not ok then
                self:showError(string.format(
                    _("Error saving configuration:\n%s"), tostring(err)))
                return
            end
            if plugin and plugin.ui then
                self:reloadLiveMenu(plugin, view)
            end
            if on_success then on_success() end
        end,
    })
end

-- =========================================================================
-- Top Tabs Reorder & Visibility Screen (SortWidget) - unified
-- =========================================================================

function UIScreens:showTabReorderDialog(plugin, view, on_close_callback)
    if plugin then self.plugin = plugin end
    view = view or self:getCurrentView(plugin)
    local sort_widget
    local function makeTabItem(tid)
        local tab_title = MenuTitles:getTitle(tid)
        local icon = MenuTitles:getIcon(tid)
        local display_text = icon and string.format("[%s] %s", tab_title, tid) or tab_title
        return {
            text = display_text,
            tab_id = tid,
            item_id = tid,
            is_submenu = true,
            onSubmenuTap = function()
                self:showItemSortWidget(plugin, view, tid, function()
                    if sort_widget then sort_widget:_populateItems() end
                end)
            end,
            checked_func = function()
                return not MenuOrderManager:isItemHidden(view, tid)
            end,
            callback = function()
                local is_hidden = MenuOrderManager:isItemHidden(view, tid)
                if not is_hidden then
                    if MenuOrderManager:isTabProtected(tid) then
                        UIManager:show(Notification:new{
                            text = string.format(
                                _("%s cannot be hidden."),
                                MenuTitles:getTitle(tid)),
                        })
                        return
                    end
                    -- Area 12 policy: on KOReader builds WITHOUT the upstream
                    -- sorting_hint nil-guard, a hidden tab can crash stock
                    -- KOReader at startup once this plugin is removed (other
                    -- plugins' orphaned hints point at the hidden id). Warn
                    -- once per session and point at the mitigation.
                    if KoreaderAdapter.tabHidingSafety() == "unsafe"
                            and not self._tab_hide_warned then
                        self._tab_hide_warned = true
                        UIManager:show(InfoMessage:new{
                            text = _("Note: this KOReader version has no upstream fix for hidden-menu crashes. If you later remove Reordering Menus, use \"Prepare for plugin removal\" first, or other plugins may fail to start."),
                            timeout = 8,
                        })
                    end
                    self:reconcileLiveMenuItems(plugin, view, tid)
                    self:reconcileRegisteredItems(plugin, view, false)
                end
                MenuOrderManager:setTabHidden(view, tid, not is_hidden)
            end,
            hold_callback = function(self_item, refresh_func)
                local dialog
                local buttons = {
                    {{
                        text = _("Edit submenu contents →"),
                        callback = function()
                            UIManager:close(dialog)
                            self:showItemSortWidget(plugin, view, tid, function()
                                if refresh_func then refresh_func() end
                            end)
                        end,
                    }},
                    {{
                        text = _("Hide this tab"),
                        callback = function()
                            UIManager:close(dialog)
                            if MenuOrderManager:isTabProtected(tid) then
                                UIManager:show(Notification:new{
                                    text = string.format(
                                        _("%s cannot be hidden."),
                                        MenuTitles:getTitle(tid)),
                                })
                                return
                            end
                            self:reconcileLiveMenuItems(plugin, view, tid)
                            self:reconcileRegisteredItems(plugin, view, false)
                            MenuOrderManager:setTabHidden(view, tid, true)
                            if refresh_func then refresh_func() end
                        end,
                    }},
                }
                dialog = ButtonDialog:new{
                    title = string.format(_("“%s”"), MenuTitles:getTitle(tid)),
                    title_align = "center",
                    buttons = buttons,
                }
                UIManager:show(dialog)
            end,
        }
    end

    local function buildSortItems()
        local items = {}
        local seen = {}
        for _, tab_id in ipairs(MenuOrderManager:getTabs(view)) do
            seen[tab_id] = true
            table.insert(items, makeTabItem(tab_id))
        end
        for _, tab_id in ipairs(MenuOrderManager:getAllKnownTabs(view)) do
            if not seen[tab_id] then
                table.insert(items, makeTabItem(tab_id))
            end
        end
        return items
    end

    local sort_items = buildSortItems()
    -- Unsaved-change tracking for the title-bar close button. Footer buttons
    -- keep their original behaviour: the check icon saves and closes, the
    -- exit icon closes without asking.
    local last_saved_disabled = util.tableDeepCopy(MenuOrderManager:getDisabledItems(view))
    local suppress_unsaved_check = false
    local function mark_tabs_saved()
        last_saved_disabled = util.tableDeepCopy(MenuOrderManager:getDisabledItems(view))
    end
    local function tabs_have_unsaved_changes()
        if not sort_widget or type(sort_widget.item_table) ~= "table" then return false end
        local new_tabs = {}
        for __, sort_item in ipairs(sort_widget.item_table) do
            local tid = sort_item.tab_id
            if tid and not MenuOrderManager:isItemHidden(view, tid) then
                table.insert(new_tabs, tid)
            end
        end
        if not id_lists_match(new_tabs, MenuOrderManager:getTabs(view)) then
            return true
        end
        return not id_lists_match(
            MenuOrderManager:getDisabledItems(view), last_saved_disabled)
    end
    local function save_tab_model()
        local source_items = (sort_widget and sort_widget.item_table) or sort_items
        local new_tabs = {}
        for __, sort_item in ipairs(source_items) do
            local tid = sort_item.tab_id
            if not MenuOrderManager:isItemHidden(view, tid) then
                table.insert(new_tabs, tid)
            end
        end
        MenuOrderManager:reorderTabs(view, new_tabs)
        if not self:saveAndApply(plugin, view) then return false end
        if sort_widget then
            sort_widget.marked = 0
            sort_widget.orig_item_table = nil
        end
        mark_tabs_saved()
        return true
    end
    local function refreshSortItems()
        if not sort_widget then return end
        sort_widget.item_table = buildSortItems()
        sort_widget.orig_item_table = nil
        sort_widget.marked = 0
        sort_widget.show_page = 1
        refreshPaging(sort_widget)
        mark_tabs_saved()
    end

    local title_view = view == "reader" and _("Book view") or _("Normal view")
    local reset_menu_name = view == "reader" and _("Book") or _("Normal")
    sort_widget = SortWidget:new{
        title = string.format("%s (%s)", _("Reorder menus"), title_view),
        item_table = sort_items,
        callback = function()
            save_tab_model()
        end,
    }
    local orig_on_close = sort_widget.onClose
    sort_widget.onClose = function(this)
        local ret = orig_on_close(this)
        if on_close_callback then
            on_close_callback()
        else
            self:checkPromptRestartOnExit()
        end
        return ret
    end
    -- The title-bar X asks what to do with unsaved edits; every other close
    -- path (footer exit icon, Back key, programmatic closes after saves)
    -- keeps closing directly.
    if sort_widget.title_bar and sort_widget.title_bar.right_button then
        sort_widget.title_bar.right_button.callback = function()
            if suppress_unsaved_check or not tabs_have_unsaved_changes() then
                sort_widget:onClose()
                return
            end
            UIManager:show(ConfirmBox:new{
                text = string.format(_("Save changes to %s?"), title_view),
                ok_text = _("Save"),
                ok_callback = function()
                    if save_tab_model() then sort_widget:onClose() end
                end,
                other_buttons = {{
                    {
                        text = _("Discard changes"),
                        callback = function()
                            reloadWorkingOrderFromDisk(view)
                            sort_widget:onClose()
                        end,
                    },
                }},
                cancel_text = _("Cancel"),
                cancel_callback = function() end,
            })
        end
    end
    -- Top-level: add Edit submenu in hamburger, same as when continuing moving in submenu
    local outer_self_tab = self
    function sort_widget:onShowWidgetMenu()
        local this = self
        local dialog
        local buttons = {
            {{
                text = _("Sort A to Z"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    this:sortItems("natural")
                end,
            }},
            {{
                text = _("Sort Z to A"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    this:sortItems("natural", true)
                end,
            }},
            {{
                text = _("Mirror changes (Book & Normal)"),
                align = "left",
                checked_func = function()
                    return MenuOrderManager:isMirroringEnabled()
                end,
                callback = function()
                    local enabled = not MenuOrderManager:isMirroringEnabled()
                    local ok, err = MenuOrderManager:setMirroringEnabled(enabled)
                    if not ok then
                        outer_self_tab:showError(err)
                        return
                    end
                    UIManager:show(Notification:new{
                        text = enabled
                            and _("Changes are now mirrored to the other view.")
                            or _("Changes are no longer mirrored."),
                    })
                end,
            }},
            {{
                text = _("Keep hidden entries in their position"),
                align = "left",
                checked_func = function()
                    return MenuOrderManager:isHiddenInPlace()
                end,
                callback = function()
                    local enabled = not MenuOrderManager:isHiddenInPlace()
                    local ok, err = MenuOrderManager:setHiddenInPlace(enabled)
                    if not ok then
                        outer_self_tab:showError(err)
                        return
                    end
                    UIManager:show(Notification:new{
                        text = enabled
                            and _("Hidden entries stay in place.")
                            or _("Hidden entries move to the bottom."),
                    })
                end,
            }},
        }
        local selected_submenu_id
        local selected_submenu_title
        if this.marked > 0 then
            local sel = this.item_table[this.marked]
            if sel and sel.tab_id then
                selected_submenu_id = sel.tab_id
                selected_submenu_title = MenuTitles:getTitle(sel.tab_id)
                table.insert(buttons, 1, {{
                    text = string.format(_("Edit submenu “%s” →"), selected_submenu_title),
                    align = "left",
                    callback = function()
                        UIManager:close(dialog)
                        outer_self_tab:showItemSortWidget(plugin, view, sel.tab_id, function()
                            this:_populateItems()
                        end)
                    end,
                }})
            end
        end
        table.insert(buttons, {{
            text = _("Presets…"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                outer_self_tab:showPresetsMenu(plugin, view, function(preset_applied)
                    if preset_applied then
                        refreshSortItems()
                    end
                end)
            end,
        }})
        table.insert(buttons, {{
            text = string.format(_("Reset %s menu"), reset_menu_name),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("Reset %s menu to default?"), reset_menu_name),
                    ok_text = _("Reset"),
                    ok_callback = function()
                        local reset_ok, reset_err = MenuOrderManager:resetOrder(view)
                        if not reset_ok then
                            outer_self_tab:showError(reset_err)
                            return
                        end
                        outer_self_tab:reloadLiveMenu(plugin, view)
                        UIManager:nextTick(function()
                            outer_self_tab:showTabReorderDialog(plugin, view)
                        end)
                        suppress_unsaved_check = true
                        this:onClose()
                    end,
                })
            end,
        }})
        table.insert(buttons, {{
            text = _("Prepare for plugin removal"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = _("Unhide every hidden menu item and tab in both views?\n\nDo this before disabling or uninstalling Reordering Menus if any item was hidden: without this plugin's safety net, other plugins pointing at a hidden menu could crash KOReader at startup."),
                    ok_text = _("Unhide all"),
                    ok_callback = function()
                        outer_self_tab:prepareForRemoval(plugin)
                    end,
                })
            end,
        }})
        if selected_submenu_id then
            table.insert(buttons, {{
                text = string.format(_("Reset %s menu"), selected_submenu_title),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    outer_self_tab:confirmResetSubmenu(plugin, view, selected_submenu_id, selected_submenu_title, refreshSortItems)
                end,
            }})
        end
        table.insert(buttons, {{
            text = _("Reset all menus"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = _("Reset all menus for both views to default?"),
                    ok_text = _("Reset all"),
                    ok_callback = function()
                        local reader_ok, reader_err = MenuOrderManager:resetOrder("reader")
                        if not reader_ok then
                            outer_self_tab:showError(reader_err)
                            return
                        end
                        local fm_ok, fm_err = MenuOrderManager:resetOrder("filemanager")
                        if not fm_ok then
                            outer_self_tab:showError(fm_err)
                            return
                        end
                        outer_self_tab:reloadLiveMenu(plugin, view)
                        UIManager:nextTick(function()
                            outer_self_tab:showTabReorderDialog(plugin, view)
                        end)
                        suppress_unsaved_check = true
                        this:onClose()
                    end,
                })
            end,
        }})
        dialog = showButtonMenu(buttons, {
            shrink_unneeded_width = true,
            anchor = function()
                return this.title_bar.left_button.image.dimen
            end,
        })
        return true
    end
    UIManager:show(sort_widget)
end

-- =========================================================================
-- Menu & Submenu Browser Screen - DIRECT to SortWidget (cleaned)
-- =========================================================================

function UIScreens:showMenuBrowser(plugin, view, on_close_callback)
    -- Selection interface removed per request: just open unified reordering interface
    -- Previously showed Menu with top tabs; now directly drills via SortWidget double-tap
    return self:showTabReorderDialog(plugin, view, on_close_callback)
end

-- =========================================================================
-- Menu Item Customizer Screen - DEPRECATED wrapper (kept for compatibility)
-- Now simply forwards to the standard SortWidget interface.
-- =========================================================================

function UIScreens:showMenuItemCustomizer(plugin, view, menu_id, on_close_callback)
    -- Compatibility shim: directly open unified SortWidget.
    -- Previously this showed an intermediate menu with duplicate separator / per-item list.
    -- Now all actions are inside SortWidget (drag, checkbox hide, hold to move, widget menu for separators).
    return self:showItemSortWidget(plugin, view, menu_id, on_close_callback)
end

-- =========================================================================
-- Item Sort Widget Screen - UNIFIED reordering interface
-- Handles reorder, hide/show (checkbox), separators, move between menus via long-press
-- =========================================================================

-- Ask for a name and create an empty submenu under menu_id. The editor's
-- current (possibly unsaved) model is staged into the working order first so
-- the immediate save cannot silently drop pending edits, mirroring how a
-- cross-menu move stages pending_source_order. insert_idx is the 1-based
-- position of the new entry inside that staged list;
-- get_staged_order supplies the editor's persistent-order projection.
-- on_created(new_id, title) runs only after a successful save.
function UIScreens:showCreateSubmenuDialog(
        plugin, view, menu_id, insert_idx, get_staged_order, on_created)
    if plugin then self.plugin = plugin end
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Create submenu"),
        input_hint = _("e.g. My tools"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Create"),
                    is_enter_default = true,
                    callback = function()
                        local name = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if not name or not name:match("%S") then return end
                        name = util.trim(name)
                        local order = MenuOrderManager:loadOrder(view)
                        if type(order[menu_id]) ~= "table" then
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("No default layout is available for %s."),
                                    self:getDisplayTitle(view, menu_id)),
                            })
                            return
                        end
                        -- Stage pending editor edits first so creation lands
                        -- on top of them inside the same atomic save.
                        if type(get_staged_order) == "function" then
                            MenuOrderManager:stageList(view, menu_id, get_staged_order())
                        end
                        local ok, result = MenuOrderManager:createSubmenu(
                            view, menu_id, name, insert_idx)
                        if not ok then
                            self:showError(result)
                            return
                        end
                        if not self:saveAndApply(plugin, view, true) then return end
                        if on_created then
                            on_created(result, name)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function UIScreens:showItemSortWidget(plugin, view, menu_id, on_close_callback)
    if plugin then self.plugin = plugin end
    local menu_title = self:getDisplayTitle(view, menu_id)
    local configured_items = MenuOrderManager:getMenuItems(view, menu_id)

    local hidden_for_menu = self:_getHiddenForMenu(view, menu_id)
    local hidden_set = {}
    for _, id in ipairs(hidden_for_menu) do hidden_set[id] = true end
    -- Also retain malformed/older configurations that left a disabled item in
    -- its menu list instead of removing it.
    for _, id in ipairs(configured_items) do
        if id ~= MenuOrderManager.SEPARATOR_ID
                and MenuOrderManager:isItemHidden(view, id) and not hidden_set[id] then
            table.insert(hidden_for_menu, id)
            hidden_set[id] = true
        end
    end

    local live_ids, live_items_by_id, has_live_menu = self:_getLiveMenuItems(plugin, menu_id)
    -- Configured entries that no installed plugin provides and that the
    -- rebuilt menu does not contain cannot render anywhere (uninstalled or
    -- disabled provider, doc-only item seen from the other view). They stay
    -- out of the editor display entirely - unavailable_items keeps them
    -- persisted so a reinstall restores them at their configured position.
    local renderable_ids = self:_collectRenderableIds(plugin)
    local items, unavailable_items = self:_mergeConfiguredAndLiveItems(
        configured_items, hidden_for_menu, live_ids, has_live_menu,
        MenuOrderManager:getRecentMoves(view), menu_id, renderable_ids
    )

    local sort_widget
    local getCurrentEditorOrder
    local refreshEditorAfterMove
    -- Forward declaration: row hold-callbacks (e.g. restore-default) run only
    -- after the unsaved-change block below assigns this.
    local suppress_unsaved_check
    -- Forward declarations: row hold-callbacks (e.g. deleting a created
    -- submenu) run only after these are assigned below.
    local mark_editor_saved
    local resetEditorPaging

    local function create_sep_item()
        local this_entry
        this_entry = {
            text = _("--- Separator ---"),
            item_id = MenuOrderManager.SEPARATOR_ID,
            checked_func = function() return true end,
            hold_callback = function(self_item, refresh_func)
                UIManager:show(ConfirmBox:new{
                    text = _("Delete this separator?"),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        if sort_widget and sort_widget.item_table then
                            for i, sit in ipairs(sort_widget.item_table) do
                                if sit == this_entry then
                                    table.remove(sort_widget.item_table, i)
                                    sort_widget.marked = 0
                                    refreshPaging(sort_widget)
                                    if refresh_func then refresh_func() end
                                    self:showNotice(_("Separator deleted."))
                                    break
                                end
                            end
                        end
                    end,
                })
            end,
        }
        return this_entry
    end

    -- Build ordered list: visible items + hidden items for this menu at bottom (unchecked)
    local sort_items = {}
    local seen_hidden = {}

    -- Assigned once resetEditorPaging exists below: moves a row object between
    -- the visible section and the trailing hidden section of the editor model,
    -- so visibility toggles are immediately reflected instead of leaving the
    -- row stuck looking unchanged ("can't unhide").
    local move_row_within_editor

    local function makeSortItem(id, submenu_flag, disp_text)
        local this_id = id
        local is_sub = submenu_flag
        local text_for_closure = disp_text
        local submenu_cb = nil
        if is_sub then
            submenu_cb = function()
                self:showItemSortWidget(plugin, view, this_id, function()
                    if sort_widget then sort_widget:_populateItems() end
                end)
            end
        end
        local entry
        entry = {
            text = text_for_closure,
            item_id = this_id,
            is_submenu = is_sub,
            onSubmenuTap = submenu_cb,
            checked_func = function()
                return not MenuOrderManager:isItemHidden(view, this_id)
            end,
            callback = function()
                local is_hidden = MenuOrderManager:isItemHidden(view, this_id)
                if not is_hidden and MenuOrderManager:isItemProtected(this_id) then
                    UIManager:show(Notification:new{
                        text = string.format(
                            _("%s cannot be hidden."),
                            self:getDisplayTitle(view, this_id, live_items_by_id)),
                    })
                    return
                end
                MenuOrderManager:setItemHidden(view, this_id, not is_hidden, menu_id)
                if move_row_within_editor then
                    move_row_within_editor(entry, not is_hidden)
                end
                if is_hidden then
                    UIManager:show(Notification:new{
                        text = string.format(
                            _("Restored “%s”."),
                            self:getDisplayTitle(view, this_id, live_items_by_id)),
                    })
                end
            end,
            hold_callback = function(self_item, refresh_func)
                local dialog
                local buttons = {
                    {
                        {
                            text = _("Move to another menu…"),
                            callback = function()
                                UIManager:close(dialog)
                                self:showDestinationMenuChooser(
                                    plugin, view, this_id, menu_id,
                                    function(moved_item_id)
                                        if refreshEditorAfterMove then
                                            refreshEditorAfterMove(moved_item_id)
                                        elseif refresh_func then
                                            refresh_func()
                                        end
                                    end,
                                    getCurrentEditorOrder and getCurrentEditorOrder() or nil
                                )
                            end,
                        }
                    },
                    {
                        {
                            text = _("Hide this item"),
                            callback = function()
                                UIManager:close(dialog)
                                if MenuOrderManager:isItemProtected(this_id) then
                                    UIManager:show(Notification:new{
                                        text = string.format(
                                            _("%s cannot be hidden."),
                                            self:getDisplayTitle(view, this_id, live_items_by_id)),
                                    })
                                    return
                                end
                                MenuOrderManager:setItemHidden(view, this_id, true, menu_id)
                                if move_row_within_editor then
                                    move_row_within_editor(entry, true)
                                end
                                if refresh_func then refresh_func() end
                            end,
                        }
                    },
                    {
                        {
                            text = _("Restore default placement"),
                            callback = function()
                                UIManager:close(dialog)
                                local ok_restore, err_restore =
                                    MenuOrderManager:restoreItemDefault(view, this_id)
                                if ok_restore then
                                    suppress_unsaved_check = true
                                    if not self:saveAndApply(plugin, view, true) then
                                        suppress_unsaved_check = false
                                        return
                                    end
                                    UIManager:show(Notification:new{
                                        text = string.format(
                                            _("Restored “%s”."),
                                            MenuTitles:getTitle(this_id, live_items_by_id)),
                                    })
                                    sort_widget:onClose()
                                    UIManager:nextTick(function()
                                        self:showItemSortWidget(plugin, view, menu_id)
                                    end)
                                else
                                    self:showError(err_restore)
                                    if refresh_func then refresh_func() end
                                end
                            end,
                        }
                    },
                }
                if is_sub then
                    table.insert(buttons, {
                        {
                            text = _("Edit submenu contents →"),
                            callback = function()
                                UIManager:close(dialog)
                                self:showItemSortWidget(plugin, view, this_id, function()
                                    if refresh_func then refresh_func() end
                                end)
                            end,
                        }
                    })
                end
                if is_sub and MenuOrderManager:isCustomSubmenu(view, this_id) then
                    table.insert(buttons, {
                        {
                            text = _("Delete this submenu…"),
                            callback = function()
                                UIManager:close(dialog)
                                local submenu_title = self:getDisplayTitle(view, this_id, live_items_by_id)
                                UIManager:show(ConfirmBox:new{
                                    text = string.format(_("Delete the empty submenu “%s”?"), submenu_title),
                                    ok_text = _("Delete"),
                                    ok_callback = function()
                                        local ok, err = MenuOrderManager:deleteCustomSubmenu(view, this_id)
                                        if not ok then
                                            self:showError(err)
                                            return
                                        end
                                        if sort_widget and type(sort_widget.item_table) == "table" then
                                            UIEditorModel.removeRowsById(
                                                sort_widget.item_table, this_id)
                                            if #sort_widget.item_table == 0 then
                                                table.insert(sort_widget.item_table,
                                                    emptyHintRow())
                                            end
                                            resetEditorPaging()
                                        end
                                        if not self:saveAndApply(plugin, view, true) then
                                            return
                                        end
                                        if mark_editor_saved then mark_editor_saved() end
                                        self:showNotice(string.format(
                                            _("Submenu “%s” deleted."), submenu_title))
                                        if refresh_func then refresh_func() end
                                    end,
                                })
                            end,
                        }
                    })
                end
                dialog = ButtonDialog:new{
                    title = string.format(_("“%s”"), self:getDisplayTitle(view, this_id, live_items_by_id)),
                    title_align = "center",
                    buttons = buttons,
                }
                UIManager:show(dialog)
            end,
        }
        return entry
    end

    -- How hidden entries are presented: "in place" keeps each dimmed row at
    -- the position it occupied among visible entries; "bottom" collects them
    -- into the trailing hidden section.
    local hidden_in_place = MenuOrderManager:isHiddenInPlace()

    for idx, item_id in ipairs(items) do
        local is_sep = (item_id == MenuOrderManager.SEPARATOR_ID)
        if is_sep then
            table.insert(sort_items, create_sep_item())
        else
            local item_title = self:getDisplayTitle(view, item_id, live_items_by_id)
            -- Only KOReader order-table submenus are editable here. A plugin may
            -- expose its own sub_item_table (for example HTTP Inspector), but
            -- its internal arrangement is owned by that plugin and cannot be
            -- safely persisted through KOReader's menu order.
            local is_submenu = MenuOrderManager:isSubmenu(view, item_id)
            local display_text = string.format("%s%s", is_submenu and "[+] " or "", item_title)
            table.insert(sort_items, makeSortItem(item_id, is_submenu, display_text))
        end
    end

    local function make_hidden_row(hid)
        local this_id = hid
        local item_title = self:getDisplayTitle(view, this_id, live_items_by_id)
        local is_submenu = MenuOrderManager:isSubmenu(view, this_id)
        local display_text = string.format("%s%s (%s)", is_submenu and "[+] " or "",
            item_title, _("hidden"))
        local entry
        entry = {
            text = display_text,
            item_id = this_id,
            is_submenu = is_submenu,
            dim = true,
            is_hidden_row = true,
            checked_func = function()
                return false -- hidden => unchecked
            end,
            callback = function()
                -- Tapping checkbox restores
                MenuOrderManager:setItemHidden(view, this_id, false, menu_id)
                if move_row_within_editor then
                    move_row_within_editor(entry, false)
                end
                UIManager:show(Notification:new{
                    text = string.format(
                        _("Restored “%s”."),
                        self:getDisplayTitle(view, this_id, live_items_by_id)),
                })
            end,
            hold_callback = function(self_item, refresh_func)
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("Restore “%s” to this menu?"),
                        self:getDisplayTitle(view, this_id, live_items_by_id)),
                    ok_text = _("Restore"),
                    ok_callback = function()
                        MenuOrderManager:setItemHidden(view, this_id, false, menu_id)
                        if move_row_within_editor then
                            move_row_within_editor(entry, false)
                        end
                        if refresh_func then refresh_func() end
                    end,
                })
            end,
        }
        return entry
    end

    -- Bottom mode appends in disabled-list order. Preserve-location mode
    -- walks backwards so chains stay stable: several hidden entries sharing
    -- one anchor are re-inserted after it in their original relative order.
    local function append_hidden_row(hid)
        seen_hidden[hid] = true
        local entry = make_hidden_row(hid)
        if not hidden_in_place then
            table.insert(sort_items, entry)
            return
        end
        -- Preserve-location mode: re-insert right after the recorded previous
        -- visible sibling so the dimmed row sits where the entry used to.
        local anchor_id = MenuOrderManager:getHiddenAnchor(view, hid)
        if anchor_id then
            for j, r in ipairs(sort_items) do
                if r.item_id == anchor_id then
                    table.insert(sort_items, j + 1, entry)
                    return
                end
            end
        end
        table.insert(sort_items, entry) -- anchor gone: bottom fallback
    end

    local function maybe_append_hidden(hid)
        -- Only add if not already visible (shouldn't be)
        local already = false
        for __, it in ipairs(items) do
            if it == hid then already = true; break end
        end
        if not already and not seen_hidden[hid] then
            append_hidden_row(hid)
        end
    end

    if hidden_in_place then
        for i = #hidden_for_menu, 1, -1 do
            maybe_append_hidden(hidden_for_menu[i])
        end
    else
        for __, hid in ipairs(hidden_for_menu) do
            maybe_append_hidden(hid)
        end
    end

    -- If no items and no hidden, add hint
    if #sort_items == 0 then
        table.insert(sort_items, emptyHintRow())
    end

    local function buildOrderFromSortItems(source_items)
        local new_list = {}
        for _, sort_item in ipairs(source_items or {}) do
            local iid = sort_item.item_id
            if iid == EMPTY_HINT_ID then
                -- skip hint
            elseif iid == MenuOrderManager.SEPARATOR_ID or not MenuOrderManager:isItemHidden(view, iid) then
                table.insert(new_list, iid)
            end
        end
        return new_list
    end

    -- Heal this editor's row snapshot against cross-menu moves performed after
    -- it was opened. Drill-down keeps parent editors alive with outdated rows;
    -- saving such a snapshot used to drop an item just moved into this menu
    -- (its orphan was then re-anchored to its stock parent, visually reverting
    -- the move) or resurrect an item moved away from it.
    local function healAgainstRecentMoves(new_list, present)
        local recent_moves = MenuOrderManager:getRecentMoves(view)
        local healed = {}
        for _, id in ipairs(new_list) do
            local rec = recent_moves[id]
            if id == MenuOrderManager.SEPARATOR_ID or not rec or rec.to == menu_id then
                table.insert(healed, id)
            end
            -- else: moved to another menu since this editor opened; dropping
            -- the stale row keeps a save from resurrecting it here.
        end
        for id, rec in pairs(recent_moves) do
            if rec.to == menu_id and not present[id]
                    and not MenuOrderManager:isItemHidden(view, id) then
                table.insert(healed, id)
                present[id] = true
            end
        end
        return healed
    end

    local function buildPersistentOrder(source_items)
        local new_list = buildOrderFromSortItems(source_items)
        local present = {}
        for _, id in ipairs(new_list) do
            if id ~= MenuOrderManager.SEPARATOR_ID then present[id] = true end
        end
        new_list = healAgainstRecentMoves(new_list, present)
        for _, id in ipairs(unavailable_items) do
            if not present[id] and not MenuOrderManager:isItemHidden(view, id) then
                table.insert(new_list, id)
                present[id] = true
            end
        end
        return new_list
    end

    -- A cross-menu move is saved immediately. Include any pending drag, sort,
    -- separator, or visibility changes from this editor in that same save so
    -- opening the destination chooser cannot silently discard them.
    getCurrentEditorOrder = function()
        local source_items = (sort_widget and sort_widget.item_table) or sort_items
        return buildPersistentOrder(source_items)
    end

    -- The SortWidget owns a separate UI model from MenuOrderManager. Merely
    -- repainting it after a move leaves the old row and parent/index captured
    -- in its callbacks; the next separator/sort/OK action can then put the item
    -- back in its source menu. Remove it from the editor model and reset all
    -- selection/paging state to the newly saved source menu instead.
    --
    -- Live interface sync for cross-menu moves performed while this editor is
    -- open (e.g. a parent menu editor during drill-down). The destination
    -- editor gains a visible row for the moved item; source editors drop it.
    -- Defined as methods: _notifyEditorsOfMove invokes them as
    -- widget:syncMovedIn(item_id).
    local syncMovedIn
    local syncMovedOut

    resetEditorPaging = function()
        sort_widget.orig_item_table = nil
        sort_widget.marked = 0
        refreshPaging(sort_widget)
    end

    -- Relocate a row object between the visible block and the trailing hidden
    -- section of the editor model. Hiding appends to the end of the hidden
    -- section; unhiding inserts just before the first remaining hidden row
    -- (i.e. at the end of the visible block). Text and checkbox state are
    -- rewritten in the same step: hidden rows carry a baked-in " (hidden)"
    -- label and a constant-false checkbox, both of which must flip when the
    -- item is restored.
    move_row_within_editor = function(entry, to_hidden)
        if not sort_widget or type(sort_widget.item_table) ~= "table"
                or not entry then return end
        entry.text = string.format("%s%s%s",
            entry.is_submenu and "[+] " or "",
            tostring(UIScreens:getDisplayTitle(view, entry.item_id, live_items_by_id)),
            to_hidden and string.format(" (%s)", _("hidden")) or "")
        entry.checked_func = function()
            return not MenuOrderManager:isItemHidden(view, entry.item_id)
        end
        entry.dim = to_hidden and true or nil
        entry.is_hidden_row = to_hidden and true or nil

        -- Preserve-location mode: the row keeps its exact position; only its
        -- presentation flipped. Bottom mode relocates it into/out of the
        -- trailing hidden section as before.
        if MenuOrderManager:isHiddenInPlace() then
            resetEditorPaging()
            return
        end

        UIEditorModel.removeRow(sort_widget.item_table, entry)
        local insert_at = #sort_widget.item_table + 1
        if not to_hidden then
            insert_at = UIEditorModel.firstRowIndex(sort_widget.item_table,
                function(row) return row.is_hidden_row end) or insert_at
        end
        UIEditorModel.insertRow(sort_widget.item_table, insert_at, entry)
        resetEditorPaging()
    end

    -- Defined as methods: _notifyEditorsOfMove invokes them as
    -- widget:syncMovedIn(item_id).
    syncMovedIn = function(self, moved_item_id)
        if not sort_widget or type(sort_widget.item_table) ~= "table" then return end
        for _, row in ipairs(sort_widget.item_table) do
            if row.item_id == moved_item_id then
                return
            end
        end
        UIEditorModel.removeEmptyHints(sort_widget.item_table)
        local is_submenu = MenuOrderManager:isSubmenu(view, moved_item_id)
        local item_title = UIScreens:getDisplayTitle(view, moved_item_id, live_items_by_id)
        local new_row = makeSortItem(moved_item_id, is_submenu,
            string.format("%s%s", is_submenu and "[+] " or "", item_title))
        local insert_at = #sort_widget.item_table + 1
        if not MenuOrderManager:isHiddenInPlace() then
            -- Bottom mode: land ahead of the trailing hidden section.
            insert_at = UIEditorModel.firstRowIndex(sort_widget.item_table,
                function(row) return row.is_hidden_row end) or insert_at
        end
        UIEditorModel.insertRow(sort_widget.item_table, insert_at, new_row)
        resetEditorPaging()
        if mark_editor_saved then mark_editor_saved() end
    end

    syncMovedOut = function(self, moved_item_id)
        if not sort_widget or type(sort_widget.item_table) ~= "table" then return end
        if UIEditorModel.removeRowsById(sort_widget.item_table, moved_item_id) == 0 then
            return
        end
        resetEditorPaging()
        if mark_editor_saved then mark_editor_saved() end
    end

    refreshEditorAfterMove = function(moved_item_id)
        if not sort_widget or not sort_widget.item_table then return end
        UIEditorModel.removeRowsById(sort_widget.item_table, moved_item_id)
        if #sort_widget.item_table == 0 then
            table.insert(sort_widget.item_table, emptyHintRow())
        end
        resetEditorPaging()
        if mark_editor_saved then mark_editor_saved() end
    end

    -- Unsaved-change tracking for the title-bar close button. Footer buttons
    -- keep their original behaviour: the check icon saves and closes, the
    -- exit icon closes without asking. The editor model is compared against
    -- the same normalization the save path produces (buildPersistentOrder),
    -- captured at open and refreshed at every save point - this keeps
    -- provider-less preserved entries from ever registering as edits, while
    -- drags, sorts, separators and visibility toggles all register.
    suppress_unsaved_check = false
    local last_saved_model = buildPersistentOrder(sort_items)
    mark_editor_saved = function()
        if sort_widget and type(sort_widget.item_table) == "table" then
            last_saved_model = buildPersistentOrder(sort_widget.item_table)
        else
            last_saved_model = buildPersistentOrder(sort_items)
        end
    end
    local function editor_has_unsaved_changes()
        if not sort_widget or type(sort_widget.item_table) ~= "table" then return false end
        return not id_lists_match(
            buildPersistentOrder(sort_widget.item_table), last_saved_model)
    end
    local function save_editor_model()
        local source_items = (sort_widget and sort_widget.item_table) or sort_items
        -- The editor model is translated into minimal intent operations
        -- against the freshly materialized baseline and committed atomically.
        MenuOrderManager:stageList(view, menu_id,
            buildPersistentOrder(source_items))
        local saved = self:saveAndApply(plugin, view)
        if not saved then return false end
        -- Ensure check always goes up a level
        if sort_widget then
            sort_widget.marked = 0
            sort_widget.orig_item_table = nil
        end
        mark_editor_saved()
        return true
    end

    sort_widget = SortWidget:new{
        title = string.format("%s - %s", _("Reorder"), menu_title),
        item_table = sort_items,
        callback = function()
            save_editor_model()
        end,
    }
    sort_widget.syncMovedIn = syncMovedIn
    sort_widget.syncMovedOut = syncMovedOut
    UIEditorRegistry:register(view, menu_id, sort_widget)

    local orig_on_close = sort_widget.onClose
    sort_widget.onClose = function(this)
        UIEditorRegistry:unregister(this)
        local ret = orig_on_close(this)
        if on_close_callback then
            on_close_callback()
        else
            self:checkPromptRestartOnExit()
        end
        return ret
    end

    -- The title-bar X asks what to do with unsaved edits; every other close
    -- path (footer exit icon, Back key, programmatic closes after saves)
    -- keeps closing directly.
    if sort_widget.title_bar and sort_widget.title_bar.right_button then
        sort_widget.title_bar.right_button.callback = function()
            if suppress_unsaved_check or not editor_has_unsaved_changes() then
                sort_widget:onClose()
                return
            end
            UIManager:show(ConfirmBox:new{
                text = string.format(_("Save changes to “%s”?"), menu_title),
                ok_text = _("Save"),
                ok_callback = function()
                    if save_editor_model() then sort_widget:onClose() end
                end,
                other_buttons = {{
                    {
                        text = _("Discard changes"),
                        callback = function()
                            reloadWorkingOrderFromDisk(view)
                            sort_widget:onClose()
                        end,
                    },
                }},
                cancel_text = _("Cancel"),
                cancel_callback = function() end,
            })
        end
    end

    local outer_self_item = self
    function sort_widget:onShowWidgetMenu()
        local this = self
        local dialog
        local sep_text = this.marked > 0 and _("Insert separator after selection") or _("Add separator at bottom")
        local sep_msg = this.marked > 0 and _("Separator inserted after.") or _("Separator added at bottom.")
        -- Mirror the separator placement rules: nothing selected appends at
        -- the bottom, a marked row inserts the new entry right after it.
        local submenu_insert_pos = this.marked > 0 and this.marked + 1 or #this.item_table + 1
        -- Map the editor-model position onto the persisted list: count the
        -- staged entries the rows before the insertion point account for.
        -- Hidden rows and the empty hint never match and are skipped.
        local function persistedIndexForEditorPos(pos)
            return UIEditorModel.persistedIndexForRowPosition(
                this.item_table, pos, getCurrentEditorOrder(), EMPTY_HINT_ID)
        end
        local buttons = {
            {{
                text = sep_text,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    local insert_pos
                    if this.marked > 0 then
                        insert_pos = this.marked + 1
                    else
                        insert_pos = #this.item_table + 1
                    end
                    local new_sep = create_sep_item()
                    UIEditorModel.removeEmptyHints(this.item_table)
                    insert_pos = UIEditorModel.insertRow(
                        this.item_table, insert_pos, new_sep)
                    this.marked = insert_pos
                    refreshPaging(this, insert_pos)
                    outer_self_item:showNotice(sep_msg)
                end,
            }},
            {{
                text = this.marked > 0
                    and _("Insert submenu after selection") or _("Add submenu at bottom"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    outer_self_item:showCreateSubmenuDialog(
                        plugin, view, menu_id,
                        persistedIndexForEditorPos(submenu_insert_pos),
                        getCurrentEditorOrder,
                        function(new_id, title)
                            UIEditorModel.removeEmptyHints(this.item_table)
                            local new_row = makeSortItem(new_id, true, "[+] " .. title)
                            submenu_insert_pos = UIEditorModel.insertRow(
                                this.item_table, submenu_insert_pos, new_row)
                            this.marked = submenu_insert_pos
                            refreshPaging(this, submenu_insert_pos)
                            outer_self_item:showNotice(string.format(
                                _("Submenu “%s” created."), title))
                            mark_editor_saved()
                        end)
                end,
            }},
            {{
                text = _("Move item to another menu…"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    if this.marked > 0 and this.item_table[this.marked] then
                        local iid = this.item_table[this.marked].item_id
                        if iid and iid ~= MenuOrderManager.SEPARATOR_ID and iid ~= EMPTY_HINT_ID then
                            outer_self_item:showDestinationMenuChooser(
                                plugin, view, iid, menu_id,
                                function(moved_item_id)
                                    refreshEditorAfterMove(moved_item_id)
                                end,
                                getCurrentEditorOrder()
                            )
                        else
                            outer_self_item:showError(
                                _("Select a regular item first (tap to mark)."))
                        end
                    else
                        outer_self_item:showError(
                            _("Mark an item first (tap its row), then use this to move it."))
                    end
                end,
            }},
            {{
                text = _("Sort A to Z"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    this:sortItems("natural")
                end,
            }},
            {{
                text = _("Sort Z to A"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    this:sortItems("natural", true)
                end,
            }},
        }
        local selected_submenu_id
        local selected_submenu_title
        if this.marked > 0 then
            local sel = this.item_table[this.marked]
            if sel and sel.item_id and sel.is_submenu then
                selected_submenu_id = sel.item_id
                selected_submenu_title = outer_self_item:getDisplayTitle(view, sel.item_id, live_items_by_id)
                table.insert(buttons, {{
                    text = string.format(_("Edit submenu “%s” →"), selected_submenu_title),
                    align = "left",
                    callback = function()
                        UIManager:close(dialog)
                        outer_self_item:showItemSortWidget(plugin, view, sel.item_id, function()
                            this:_populateItems()
                        end)
                    end,
                }})
            end
        end
        table.insert(buttons, {{
            text = string.format(_("Presets for %s…"), menu_title),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                local current_menu_items = buildOrderFromSortItems(this.item_table)
                outer_self_item:showSubmenuPresetsMenu(plugin, view, menu_id, menu_title, function(preset_applied)
                    if preset_applied then
                        UIManager:nextTick(function()
                            outer_self_item:showItemSortWidget(plugin, view, menu_id, on_close_callback)
                        end)
                        suppress_unsaved_check = true
                        this:onClose()
                    end
                end, current_menu_items)
            end,
        }})
        table.insert(buttons, {{
            text = string.format(_("Reset %s menu"), menu_title),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                outer_self_item:confirmResetSubmenu(plugin, view, menu_id, menu_title, function()
                    UIManager:nextTick(function()
                        outer_self_item:showItemSortWidget(plugin, view, menu_id, on_close_callback)
                    end)
                    suppress_unsaved_check = true
                    this:onClose()
                end)
            end,
        }})
        if selected_submenu_id then
            table.insert(buttons, {{
                text = string.format(_("Reset %s menu"), selected_submenu_title),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    outer_self_item:confirmResetSubmenu(plugin, view, selected_submenu_id, selected_submenu_title, function()
                        -- The reset saved a new layout for the submenu; reopen
                        -- this editor fresh instead of repainting stale rows,
                        -- so the close check compares against reality.
                        UIManager:nextTick(function()
                            outer_self_item:showItemSortWidget(plugin, view, menu_id, on_close_callback)
                        end)
                        suppress_unsaved_check = true
                        this:onClose()
                    end)
                end,
            }})
        end
        table.insert(buttons, {{
            text = _("Reset all menus"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = _("Reset all menus for both views to default?"),
                    ok_text = _("Reset all"),
                    ok_callback = function()
                        local reader_ok, reader_err = MenuOrderManager:resetOrder("reader")
                        if not reader_ok then
                            outer_self_item:showError(reader_err)
                            return
                        end
                        local fm_ok, fm_err = MenuOrderManager:resetOrder("filemanager")
                        if not fm_ok then
                            outer_self_item:showError(fm_err)
                            return
                        end
                        outer_self_item:reloadLiveMenu(plugin, view)
                        UIManager:nextTick(function()
                            outer_self_item:showTabReorderDialog(plugin, view)
                        end)
                        suppress_unsaved_check = true
                        this:onClose()
                    end,
                })
            end,
        }})
        table.insert(buttons, {{
            text = _("Prepare for plugin removal"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                UIManager:show(ConfirmBox:new{
                    text = _("Unhide every hidden menu item and tab in both views?\n\nDo this before disabling or uninstalling Reordering Menus if any item was hidden: without this plugin's safety net, other plugins pointing at a hidden menu could crash KOReader at startup."),
                    ok_text = _("Unhide all"),
                    ok_callback = function()
                        outer_self_item:prepareForRemoval(plugin)
                    end,
                })
            end,
        }})
        dialog = showButtonMenu(buttons, {
            shrink_unneeded_width = true,
            anchor = function()
                return this.title_bar.left_button.image.dimen
            end,
        })
        return true
    end

    UIManager:show(sort_widget)
end

-- =========================================================================
-- Detailed Item Action Dialog (kept for search & compatibility)
-- Now streamlined: only used via search results or hold callback
-- =========================================================================

function UIScreens:showItemActionDialog(plugin, view, menu_id, item_id, idx, on_update_callback)
    if plugin then self.plugin = plugin end
    local is_sep = (item_id == MenuOrderManager.SEPARATOR_ID)
    local item_title = is_sep and _("Separator") or self:getDisplayTitle(view, item_id)
    local items = MenuOrderManager:getMenuItems(view, menu_id)
    local total_items = #items

    local actions = {}

    if not is_sep then
        if idx > 1 then
            table.insert(actions, {
                text = _("Move up"),
                callback = function()
                    MenuOrderManager:moveItem(view, menu_id, idx, idx - 1)
                    if not self:saveAndApply(plugin, view) then return end
                    on_update_callback()
                end,
            })
        end
        if idx < total_items then
            table.insert(actions, {
                text = _("Move down"),
                callback = function()
                    MenuOrderManager:moveItem(view, menu_id, idx, idx + 1)
                    if not self:saveAndApply(plugin, view) then return end
                    on_update_callback()
                end,
            })
        end
        if idx > 1 then
            table.insert(actions, {
                text = _("Move to top"),
                callback = function()
                    MenuOrderManager:moveItem(view, menu_id, idx, 1)
                    if not self:saveAndApply(plugin, view) then return end
                    on_update_callback()
                end,
            })
        end
        if idx < total_items then
            table.insert(actions, {
                text = _("Move to bottom"),
                callback = function()
                    MenuOrderManager:moveItem(view, menu_id, idx, total_items)
                    if not self:saveAndApply(plugin, view) then return end
                    on_update_callback()
                end,
            })
        end
        table.insert(actions, {
            text = _("Move to another menu…"),
            separator = true,
            callback = function()
                self:showDestinationMenuChooser(plugin, view, item_id, menu_id, on_update_callback)
            end,
        })
        table.insert(actions, {
            text = _("Hide / disable this item"),
            callback = function()
                if MenuOrderManager:isItemProtected(item_id) then
                    UIManager:show(Notification:new{
                        text = string.format(
                            _("%s cannot be hidden."),
                            self:getDisplayTitle(view, item_id)),
                    })
                    return
                end
                MenuOrderManager:setItemHidden(view, item_id, true, menu_id)
                if not self:saveAndApply(plugin, view) then return end
                on_update_callback()
            end,
        })
        table.insert(actions, {
            text = _("Restore default placement"),
            callback = function()
                local ok_restore, err_restore =
                    MenuOrderManager:restoreItemDefault(view, item_id)
                if ok_restore then
                    if not self:saveAndApply(plugin, view) then return end
                    self:showNotice(string.format(
                        _("Restored “%s”."), self:getDisplayTitle(view, item_id)))
                else
                    self:showError(err_restore)
                end
                on_update_callback()
            end,
        })
        if MenuOrderManager:isSubmenu(view, item_id) then
            table.insert(actions, {
                text = _("Open and reorder this submenu"),
                separator = true,
                callback = function()
                    self:showItemSortWidget(plugin, view, item_id, on_update_callback)
                end,
            })
        end
    else
        if idx > 1 then
            table.insert(actions, {
                text = _("Move separator up"),
                callback = function()
                    MenuOrderManager:moveItem(view, menu_id, idx, idx - 1)
                    if not self:saveAndApply(plugin, view) then return end
                    on_update_callback()
                end,
            })
        end
        if idx < total_items then
            table.insert(actions, {
                text = _("Move separator down"),
                callback = function()
                    MenuOrderManager:moveItem(view, menu_id, idx, idx + 1)
                    if not self:saveAndApply(plugin, view) then return end
                    on_update_callback()
                end,
            })
        end
        table.insert(actions, {
            text = _("Delete separator"),
            callback = function()
                MenuOrderManager:removeSeparator(view, menu_id, idx)
                if not self:saveAndApply(plugin, view) then return end
                on_update_callback()
            end,
        })
    end

    local action_dialog
    action_dialog = Menu:new{
        title = string.format("%s: %s", _("Action for"), item_title),
        item_table = actions,
    }
    UIManager:show(action_dialog)
end

-- =========================================================================
-- Destination Menu Chooser (Move item to another tab or submenu)
-- =========================================================================

-- Target order for the destination chooser:
--   1. Submenus that live in the same menu as the moved item, in their
--      configured order - the most likely "file this deeper" destinations.
--   2. The parent chain of the source menu, nearest ancestor first - the most
--      likely "this belongs one level up" destinations.
--   3. Every other menu and tab in their standard listing order.
function UIScreens:_getPrioritizedMoveTargets(view, from_menu_id)
    local ordered = {}
    local seen = {}
    local function push(menu_id)
        if menu_id and not seen[menu_id] then
            seen[menu_id] = true
            table.insert(ordered, menu_id)
        end
    end

    for _, item_id in ipairs(MenuOrderManager:getMenuItems(view, from_menu_id)) do
        if item_id ~= MenuOrderManager.SEPARATOR_ID
                and MenuOrderManager:isSubmenu(view, item_id) then
            push(item_id)
        end
    end

    local walker = from_menu_id
    local guard = 0
    while walker and guard < 32 do
        guard = guard + 1
        local parent = MenuOrderManager:getParentMenu(view, walker)
        if not parent or seen[parent] then break end
        push(parent)
        walker = parent
    end

    for __, entry in ipairs(MenuOrderManager:getAllMenusAndSubmenus(view)) do
        push(entry.id)
    end

    return ordered
end

function UIScreens:showDestinationMenuChooser(
        plugin, view, item_id, from_menu_id, on_moved_callback, pending_source_order)
    if plugin then self.plugin = plugin end
    local all_menus = MenuOrderManager:getAllMenusAndSubmenus(view)
    local entries_by_id = {}
    for __, entry in ipairs(all_menus) do
        entries_by_id[entry.id] = entry
    end
    local choices = {}

    local chooser_dialog
    for __, target_mid in ipairs(self:_getPrioritizedMoveTargets(view, from_menu_id)) do
        local entry = entries_by_id[target_mid]
        if entry then
            local can_move = MenuOrderManager:canMoveItemToMenu(view, item_id, from_menu_id, target_mid)
            if can_move then
                local is_tab = entry.is_tab
                local title = self:getDisplayTitle(view, target_mid)
                local prefix = is_tab and "[Tab] " or "[Menu] "

                table.insert(choices, {
                    text = string.format("%s%s", prefix, title),
                    callback = function()
                        -- The open source editor may contain unsaved reordering or
                        -- separators. Stage that exact model only when a destination
                        -- is selected (not when the chooser is merely opened).
                        local had_pending = type(pending_source_order) == "table"
                        if had_pending then
                            -- Snapshot the staged intent so a failed move can
                            -- put everything back exactly as it was.
                            MenuOrderManager:backupOrder(view)
                            MenuOrderManager:stageList(view, from_menu_id,
                                util.tableDeepCopy(pending_source_order))
                        end
                        local moved, err = MenuOrderManager:moveItemToMenu(view, item_id, from_menu_id, target_mid)
                        if not moved then
                            if had_pending then
                                MenuOrderManager:restoreOrder(view)
                            end
                            self:showError(err
                                or _("This item cannot be moved to that menu."))
                            return
                        end
                        -- Update every open editor interface right away: the
                        -- destination menu's editor (e.g. a parent menu during
                        -- drill-down) shows the moved item; source editors drop it.
                        self:_notifyEditorsOfMove(view, item_id, from_menu_id, target_mid)
                        -- The move confirmation is the only feedback needed here;
                        -- skip saveAndApply's separate "menu order saved" toast.
                        if not self:saveAndApply(plugin, view, true) then
                            if had_pending then MenuOrderManager:restoreOrder(view) end
                            return
                        end
                        -- The move is done: leave only the confirmation on screen.
                        if chooser_dialog then
                            UIManager:close(chooser_dialog)
                            chooser_dialog = nil
                        end
                        self:showNotice(string.format(_("Moved to %s."), title))
                        if on_moved_callback then
                            on_moved_callback(item_id, from_menu_id, target_mid)
                        end
                    end,
                })
            end
        end
    end

    chooser_dialog = Menu:new{
        title = string.format(_("Move “%s” to:"), self:getDisplayTitle(view, item_id)),
        item_table = choices,
    }
    UIManager:show(chooser_dialog)
end

-- =========================================================================
-- Hidden Items Manager Screen
-- =========================================================================

function UIScreens:showHiddenItemsManager(plugin, view, on_close_callback)
    if plugin then self.plugin = plugin end
    local disabled = MenuOrderManager:getDisabledItems(view)
    local function refresh()
        self:showHiddenItemsManager(plugin, view, on_close_callback)
    end

    if #disabled == 0 then
        self:showError(_("No items are currently hidden in this view."))
        return
    end

    local items = {
        {
            text = _("Unhide all items"),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Unhide and restore all hidden items to their default locations?"),
                    ok_text = _("Unhide all"),
                    ok_callback = function()
                        for __, id in ipairs(util.tableDeepCopy(disabled)) do
                            MenuOrderManager:setItemHidden(view, id, false)
                        end
                        if not self:saveAndApply(plugin, view) then return end
                        if on_close_callback then on_close_callback() end
                    end,
                })
            end,
            separator = true,
        },
    }

    for __, item_id in ipairs(disabled) do
        local title = self:getDisplayTitle(view, item_id)
        local desc = MenuTitles:getDescription(item_id)
        local label = desc and string.format("%s (%s)", title, desc) or title

        table.insert(items, {
            text = label,
            help_text = _("Tap to unhide and restore this item."),
            callback = function()
                MenuOrderManager:setItemHidden(view, item_id, false)
                if not self:saveAndApply(plugin, view) then return end
                self:showNotice(string.format(_("Restored “%s”."), title))
                refresh()
            end,
        })
    end

    local dialog
    dialog = Menu:new{
        title = string.format("%s (%d)", _("Hidden items"), #disabled),
        item_table = items,
        on_close = function()
            if on_close_callback then
                on_close_callback()
            else
                self:checkPromptRestartOnExit()
            end
        end,
    }
    UIManager:show(dialog)
end

-- =========================================================================
-- Search Dialog & Search Results
-- =========================================================================

function UIScreens:showSearchDialog(plugin, view, on_close_callback)
    if plugin then self.plugin = plugin end
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Search menu items"),
        input_hint = _("e.g. font, wifi, timer, toc, gesture"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                        if on_close_callback then
                            on_close_callback()
                        else
                            self:checkPromptRestartOnExit()
                        end
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if query and query:match("%S") then
                            self:showSearchResults(plugin, view, query, on_close_callback)
                        else
                            if on_close_callback then
                                on_close_callback()
                            else
                                self:checkPromptRestartOnExit()
                            end
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function UIScreens:showSearchResults(plugin, view, query, on_close_callback)
    if plugin then self.plugin = plugin end
    local clean_query = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local all_menus = MenuOrderManager:getAllMenusAndSubmenus(view)
    local disabled = MenuOrderManager:getDisabledItems(view)

    local matches = {}
    local seen = {}

    for __, menu_entry in ipairs(all_menus) do
        local mid = menu_entry.id
        local items = MenuOrderManager:getMenuItems(view, mid)
        for idx, item_id in ipairs(items) do
            if item_id ~= MenuOrderManager.SEPARATOR_ID and not seen[item_id] then
                local title = self:getDisplayTitle(view, item_id):lower()
                if item_id:lower():find(clean_query, 1, true) or title:find(clean_query, 1, true) then
                    seen[item_id] = true
                    table.insert(matches, {
                        item_id = item_id,
                        menu_id = mid,
                        idx = idx,
                        is_hidden = false,
                    })
                end
            end
        end
    end

    for __, item_id in ipairs(disabled) do
        if not seen[item_id] then
            local title = self:getDisplayTitle(view, item_id):lower()
            if item_id:lower():find(clean_query, 1, true) or title:find(clean_query, 1, true) then
                seen[item_id] = true
                table.insert(matches, {
                    item_id = item_id,
                    menu_id = nil,
                    idx = nil,
                    is_hidden = true,
                })
            end
        end
    end

    if #matches == 0 then
        self:showError(string.format(
            _("No menu items matching “%s” were found."), query))
        return
    end

    local result_items = {}
    for __, match in ipairs(matches) do
        local item_id = match.item_id
        local title = self:getDisplayTitle(view, item_id)
        local location = match.is_hidden and _("Hidden") or self:getDisplayTitle(view, match.menu_id)
        local status_prefix = match.is_hidden and "[Hidden] " or ""
        local row_text = string.format("%s%s [%s: %s]", status_prefix, title, _("in"), location)

        table.insert(result_items, {
            text = row_text,
            callback = function()
                if match.is_hidden then
                    MenuOrderManager:setItemHidden(view, item_id, false)
                    if not self:saveAndApply(plugin, view) then return end
                    self:showNotice(string.format(_("Unhid “%s”."), title))
                    self:showSearchResults(plugin, view, query, on_close_callback)
                else
                    self:showItemActionDialog(plugin, view, match.menu_id, item_id, match.idx, function()
                        self:showSearchResults(plugin, view, query, on_close_callback)
                    end)
                end
            end,
        })
    end

    local results_dialog
    results_dialog = Menu:new{
        title = string.format(_("Search: “%s” (%d found)"), query, #matches),
        item_table = result_items,
        on_close = function()
            if on_close_callback then
                on_close_callback()
            else
                self:checkPromptRestartOnExit()
            end
        end,
    }
    UIManager:show(results_dialog)
end

-- =========================================================================
-- Raw Configuration Viewer (TextViewer)
-- =========================================================================

function UIScreens:showRawConfigViewer(_, view)
    local order = MenuOrderManager:loadOrder(view)
    local serialized = "-- Configuration for " .. (view == "reader" and "Book view" or "Normal view") .. "\nreturn " .. dump(order, nil, true)
    local viewer = TextViewer:new{
        title = string.format("%s (%s)", _("Menu configuration"), view == "reader" and _("Book view") or _("Normal view")),
        text = serialized,
        alignment = "left",
        auto_para_direction = false,
    }
    UIManager:show(viewer)
end

-- =========================================================================
-- Preset Management UI
-- =========================================================================

local function submenuPresetPrefix(preset)
    return preset.include_submenus and "[Nested] " or "[Direct] "
end

function UIScreens:showSaveSubmenuPresetDialog(plugin, view, menu_id, menu_title, include_submenus, on_close_callback, current_menu_items)
    if plugin then self.plugin = plugin end
    local input_dialog
    input_dialog = InputDialog:new{
        title = include_submenus
            and string.format(_("Save %s and nested menus"), menu_title)
            or string.format(_("Save %s menu order"), menu_title),
        input_hint = _("e.g. My preferred order"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                        if on_close_callback then on_close_callback() end
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local name = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if name and name:match("%S") then
                            local ok, result = MenuOrderManager:saveSubmenuPreset(
                                view, menu_id, menu_title, name, include_submenus, current_menu_items
                            )
                            if ok then
                                UIManager:show(Notification:new{
                                    text = string.format(_("Saved preset “%s” for %s."), name, menu_title),
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = string.format(_("Error saving submenu preset:\n%s"), tostring(result)),
                                })
                            end
                        end
                        if on_close_callback then on_close_callback() end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function UIScreens:showDeleteSubmenuPresetMenu(plugin, view, menu_id, menu_title, on_close_callback)
    if plugin then self.plugin = plugin end
    local presets = MenuOrderManager:listSubmenuPresets(view, menu_id)
    if #presets == 0 then
        UIManager:show(InfoMessage:new{ text = _("No submenu presets to delete.") })
        if on_close_callback then on_close_callback() end
        return
    end

    local items = {}
    local dialog
    for _, preset in ipairs(presets) do
        local current_preset = preset
        table.insert(items, {
            text = submenuPresetPrefix(current_preset) .. current_preset.name,
            help_text = current_preset.description,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("Delete preset “%s” for %s?"), current_preset.name, menu_title),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        local ok, err = MenuOrderManager:deleteSubmenuPreset(view, menu_id, current_preset)
                        if ok then
                            UIManager:show(Notification:new{
                                text = string.format(_("Deleted preset “%s”."), current_preset.name),
                            })
                            dialog.on_close = nil
                            UIManager:close(dialog)
                            if on_close_callback then on_close_callback() end
                        else
                            UIManager:show(InfoMessage:new{ text = tostring(err or _("Failed to delete.")) })
                        end
                    end,
                })
            end,
        })
    end

    dialog = Menu:new{
        title = string.format(_("Delete presets for %s"), menu_title),
        item_table = items,
        on_close = on_close_callback,
    }
    UIManager:show(dialog)
end

function UIScreens:showSubmenuPresetsMenu(plugin, view, menu_id, menu_title, on_close_callback, current_menu_items)
    if plugin then self.plugin = plugin end
    local presets = MenuOrderManager:listSubmenuPresets(view, menu_id)
    local preset_applied = false
    local items = {}
    local menu_dialog

    local function closeForNavigation()
        menu_dialog.on_close = nil
        UIManager:close(menu_dialog)
    end

    table.insert(items, {
        text = _("Save this menu order…"),
        help_text = _("Capture only the direct item order of this menu. Visibility is unchanged."),
        callback = function()
            closeForNavigation()
            self:showSaveSubmenuPresetDialog(plugin, view, menu_id, menu_title, false, function()
                self:showSubmenuPresetsMenu(plugin, view, menu_id, menu_title, on_close_callback, current_menu_items)
            end, current_menu_items)
        end,
    })
    table.insert(items, {
        text = _("Save with nested submenu orders…"),
        help_text = _("Capture this menu order and the order of every submenu below it."),
        callback = function()
            closeForNavigation()
            self:showSaveSubmenuPresetDialog(plugin, view, menu_id, menu_title, true, function()
                self:showSubmenuPresetsMenu(plugin, view, menu_id, menu_title, on_close_callback, current_menu_items)
            end, current_menu_items)
        end,
        separator = true,
    })

    for _, preset in ipairs(presets) do
        local current_preset = preset
        table.insert(items, {
            text = submenuPresetPrefix(current_preset) .. current_preset.name,
            help_text = current_preset.description,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("Apply preset “%s” to %s?"), current_preset.name, menu_title),
                    ok_text = _("Apply"),
                    ok_callback = function()
                        local ok, err = MenuOrderManager:loadSubmenuPreset(view, menu_id, current_preset, current_menu_items)
                        if ok then
                            preset_applied = true
                            self.needs_restart = true
                            self:reloadLiveMenu(plugin, view)
                            UIManager:show(Notification:new{
                                text = string.format(_("Loaded preset “%s” for %s."), current_preset.name, menu_title),
                            })
                            UIManager:close(menu_dialog)
                        else
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("Failed to load submenu preset:\n%s"), tostring(err)),
                            })
                        end
                    end,
                })
            end,
        })
    end

    if #presets > 0 then
        table.insert(items, {
            text = _("Delete preset…"),
            help_text = string.format(_("Delete a saved preset for %s."), menu_title),
            callback = function()
                closeForNavigation()
                self:showDeleteSubmenuPresetMenu(plugin, view, menu_id, menu_title, function()
                    self:showSubmenuPresetsMenu(plugin, view, menu_id, menu_title, on_close_callback, current_menu_items)
                end)
            end,
            separator = true,
        })
    end

    menu_dialog = Menu:new{
        title = string.format(_("Presets for %s"), menu_title),
        item_table = items,
        on_close = function()
            if on_close_callback then on_close_callback(preset_applied) end
        end,
    }
    UIManager:show(menu_dialog)
end

function UIScreens:showPresetsMenu(plugin, view, on_close_callback)
    if plugin then self.plugin = plugin end
    local view_label = (view == "reader") and _("Book view") or _("Normal view")
    local presets = MenuOrderManager:getAllPresets(view)
    local preset_applied = false

    local items = {}
    local menu_dialog

    -- Save action at top (normal menu entry) - close current before opening save dialog to avoid stacking
    table.insert(items, {
        text = _("Save current as preset…"),
        help_text = _("Save the current menu layout with a custom name."),
        callback = function()
            UIManager:close(menu_dialog)
            self:showSavePresetDialog(plugin, view, function()
                self:showPresetsMenu(plugin, view, on_close_callback)
            end)
        end,
        separator = true,
    })

    -- Direct list of all presets in the same normal Menu (no additional interface)
    for __, preset in ipairs(presets) do
        local prefix = preset.is_builtin and "[Built-in] " or "[Custom] "
        -- capture preset for closure
        local cur_preset = preset
        table.insert(items, {
            text = prefix .. cur_preset.name,
            help_text = cur_preset.description,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("Apply preset “%s”?"), cur_preset.name),
                    ok_text = _("Apply"),
                    ok_callback = function()
                        local ok, err = MenuOrderManager:loadPreset(view, cur_preset)
                        if ok then
                            self:reconcileRegisteredItems(plugin, view, true)
                            preset_applied = true
                            self.needs_restart = true
                            self:reloadLiveMenu(plugin, view)
                            UIManager:close(menu_dialog)
                            UIManager:show(Notification:new{
                                text = string.format(_("Loaded preset “%s”."), cur_preset.name),
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("Failed to load preset:\n%s"), tostring(err)),
                            })
                        end
                    end,
                })
            end,
            hold_callback = function()
                -- Long-press overwrites the preset with the current layout.
                if cur_preset.is_builtin then
                    UIManager:show(InfoMessage:new{
                        text = _("Built-in presets cannot be updated."),
                    })
                    return
                end
                UIManager:show(ConfirmBox:new{
                    text = string.format(
                        _("Update preset “%s” with the current layout?"), cur_preset.name),
                    ok_text = _("Update"),
                    ok_callback = function()
                        local ok, err = MenuOrderManager:updatePreset(view, cur_preset)
                        if ok then
                            UIManager:show(Notification:new{
                                text = string.format(
                                    _("Updated preset “%s”."), cur_preset.name),
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = string.format(
                                    _("Failed to update preset:\n%s"), tostring(err)),
                            })
                        end
                    end,
                })
            end,
        })
    end

    -- Delete action at bottom if any deletable presets exist (custom + built-ins except default)
    local deletable = MenuOrderManager:listDeletablePresets(view)
    if #deletable > 0 then
        table.insert(items, {
            text = _("Delete preset…"),
            help_text = _("Remove a custom or built-in preset (default cannot be deleted)."),
            callback = function()
                UIManager:close(menu_dialog)
                self:showDeletePresetMenu(plugin, view, function()
                    self:showPresetsMenu(plugin, view, on_close_callback)
                end)
            end,
            separator = true,
        })
    end

    menu_dialog = Menu:new{
        title = string.format("%s - %s", _("Presets"), view_label),
        item_table = items,
        on_close = function()
            if on_close_callback then
                on_close_callback(preset_applied)
            else
                self:checkPromptRestartOnExit()
            end
        end,
    }
    UIManager:show(menu_dialog)
end

function UIScreens:showLoadPresetMenu(plugin, view, on_close_callback)
    if plugin then self.plugin = plugin end
    local presets = MenuOrderManager:getAllPresets(view)
    local items = {}

    for _, preset in ipairs(presets) do
        local cur_preset = preset
        local prefix = cur_preset.is_builtin and "[Built-in] " or "[Custom] "
        table.insert(items, {
            text = prefix .. cur_preset.name,
            help_text = cur_preset.description,
            callback = function()
                local ok, err = MenuOrderManager:loadPreset(view, cur_preset)
                if ok then
                    self:reconcileRegisteredItems(plugin, view, true)
                    self.needs_restart = true
                    self:reloadLiveMenu(plugin, view)
                    UIManager:show(Notification:new{
                        text = string.format(_("Loaded preset “%s”."), cur_preset.name),
                    })
                    if on_close_callback then on_close_callback() end
                else
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("Failed to load preset:\n%s"), tostring(err)),
                    })
                end
            end,
            hold_callback = function()
                if cur_preset.is_builtin then
                    UIManager:show(InfoMessage:new{
                        text = _("Built-in presets cannot be updated."),
                    })
                    return
                end
                UIManager:show(ConfirmBox:new{
                    text = string.format(
                        _("Update preset “%s” with the current layout?"), cur_preset.name),
                    ok_text = _("Update"),
                    ok_callback = function()
                        local ok, err = MenuOrderManager:updatePreset(view, cur_preset)
                        if ok then
                            UIManager:show(Notification:new{
                                text = string.format(
                                    _("Updated preset “%s”."), cur_preset.name),
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = string.format(
                                    _("Failed to update preset:\n%s"), tostring(err)),
                            })
                        end
                    end,
                })
            end,
        })
    end

    local dialog
    dialog = Menu:new{
        title = _("Select preset to load"),
        item_table = items,
        on_close = on_close_callback,
    }
    UIManager:show(dialog)
end

function UIScreens:showSavePresetDialog(plugin, view, on_close_callback)
    if plugin then self.plugin = plugin end
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Save layout as preset"),
        input_hint = _("e.g. My Reading Layout"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                        if on_close_callback then on_close_callback() end
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local name = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if name and name:match("%S") then
                            local ok, res = MenuOrderManager:savePreset(view, name)
                            if ok then
                                UIManager:show(Notification:new{
                                    text = string.format(_("Saved preset “%s”."), name),
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = string.format(_("Error saving preset:\n%s"), tostring(res)),
                                })
                            end
                        end
                        if on_close_callback then on_close_callback() end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function UIScreens:showDeletePresetMenu(plugin, view, on_close_callback)
    if plugin then self.plugin = plugin end
    local deletable = MenuOrderManager:listDeletablePresets(view)

    if #deletable == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No presets to delete (default cannot be deleted)."),
        })
        if on_close_callback then on_close_callback() end
        return
    end

    local items = {}
    local dialog
    for __, preset in ipairs(deletable) do
        local cur_preset = preset
        local is_builtin = cur_preset.is_builtin
        local label = (is_builtin and "[Built-in] " or "[Custom] ") .. cur_preset.name
        local help = is_builtin and _("Delete built-in preset (can be restored by resetting hidden file).") or _("Delete custom preset file.")
        if cur_preset.id == "builtin_default" then
            help = _("Default cannot be deleted.")
        end
        table.insert(items, {
            text = label,
            help_text = help,
            callback = function()
                local confirm_text
                if is_builtin then
                    confirm_text = string.format(_("Delete built-in preset “%s”?"), cur_preset.name)
                else
                    confirm_text = string.format(_("Delete custom preset “%s”?"), cur_preset.name)
                end
                UIManager:show(ConfirmBox:new{
                    text = confirm_text,
                    ok_text = _("Delete"),
                    ok_callback = function()
                        local ok, err = MenuOrderManager:deletePreset(view, cur_preset.id)
                        if not ok then
                            -- Fallback try name
                            ok, err = MenuOrderManager:deletePreset(view, cur_preset.name)
                        end
                        if ok then
                            UIManager:show(Notification:new{
                                text = string.format(_("Deleted preset “%s”."), cur_preset.name),
                            })
                            -- Close this delete menu before going back to parent to avoid stacking
                            if dialog then
                                -- Prevent on_close from re-triggering parent twice
                                local cb = dialog.on_close
                                dialog.on_close = nil
                                UIManager:close(dialog)
                                if cb then cb() end
                                -- Also call the passed on_close_callback to refresh parent
                                if on_close_callback and cb ~= on_close_callback then
                                    on_close_callback()
                                end
                            else
                                if on_close_callback then on_close_callback() end
                            end
                        else
                            UIManager:show(InfoMessage:new{
                                text = tostring(err or _("Failed to delete.")),
                            })
                        end
                    end,
                })
            end,
        })
    end

    dialog = Menu:new{
        title = _("Select preset to delete"),
        item_table = items,
        on_close = on_close_callback,
    }
    UIManager:show(dialog)
end

return UIScreens

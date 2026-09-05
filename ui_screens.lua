--[[--
UI screens and interactive dialogs for KOReader Reordering Menus plugin.

P1B structure (UI lane):
  - ONE editor close lifecycle (attachEditorCloseLifecycle) serves every
    editor and every close route (title-bar X / footer exit / Back key /
    programmatic CloseWidget).
  - ONE structured-save-result presenter (presentSaveOutcome) decides all
    save messaging from the CommitPipeline.STATUS vocabulary; UI code never
    sniffs error strings.
  - Preset application is apply-and-present only (applyPresetAndPresent):
    no reconciliation, second save, or extra reload on the UI side.
  - Private SortWidget compatibility installs lazily per open editor
    (see ui_compat.lua) and is released when the last editor closes.
  - Complexity-heavy controls live in showAdvancedMenu, off the primary
    editor surfaces.
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

local MenuOrderManager = require("menuorder_manager")
local IntentStore = require("intent_store")
local MenuTitles = require("menu_titles")
local KoreaderAdapter = require("koreader_adapter")
local CommitPipeline = require("commit_pipeline")
local Presets = require("presets")
local UICompat = require("ui_compat")
local UIEditorModel = require("ui_editor_model")
local UIEditorRegistry = require("ui_editor_registry")
local UnicodeFold = require("unicode_fold")

-- KOReader's own bidi/direction helpers (frontend/ui/bidi.lua): used to keep
-- directional glyphs correct under RTL/mirrored UI layouts.
local BD = require("ui/bidi")

-- ffi/util template: positional translation helper so translators can reorder
-- arguments (T("%1 … %2", a, b)); preferred over string.format for
-- user-facing translated text.
local T = require("ffi/util").template

-- Plural forms via gettext's ngettext (KOReader convention:
-- T(N_("1 item", "%1 items", n), n)).
local N_ = require("gettext").ngettext

-- P1B #13: the private SortItemWidget tap enhancement is installed ONLY while
-- a ReorderingMenus editor is open (refcounted for drill-down nesting) and
-- restored afterwards. Nothing is patched at plugin/module load time, so
-- stock KOReader sorting UIs never see it.
-- (The old module-load-time UICompat.installSortWidgetSubmenuTap(SortWidget)
-- call was removed; editors install/release via attachEditorCloseLifecycle.)

local UIScreens = {
    current_view = "reader", -- "reader" or "filemanager"
    needs_restart = false,
}

local EMPTY_HINT_ID = UIEditorModel.EMPTY_HINT_SENTINEL

-- Localized, non-directional row prefixes. These are presentation only —
-- never part of any id or persisted state.
local function localizedTabPrefix() return _("[Tab] ") end
local function localizedMenuPrefix() return _("[Menu] ") end
local function localizedHiddenPrefix() return _("[" .. _("Hidden") .. "] ") end
local function localizedNestedPrefix() return _("[" .. _("Nested") .. "] ") end
local function localizedDirectPrefix() return _("[" .. _("Direct") .. "] ") end
local function localizedBuiltinPrefix() return _("[" .. _("Built-in") .. "] ") end
local function localizedCustomPrefix() return _("[" .. _("Custom") .. "] ") end

-- Directional glyph for "enter this submenu" affordances. Mirrored layouts
-- (RTL languages) flip it, following the BD.mirroredUILayout() convention
-- KOReader itself uses for its menu arrows.
local function submenuArrow()
    return BD.mirroredUILayout() and "←" or "→"
end

-- Case-folded comparison key for user-facing text (titles, queries, preset
-- names). Unicode-aware: É/é, Greek, Cyrillic, Turkish cases as supported by
-- utf8proc; invalid UTF-8 is repaired with "?" first. IDs are NEVER passed
-- through this on their identity path — only as an independent search key.
local function foldKey(str)
    return UnicodeFold.key(str)
end

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
    self.needs_restart = true
    if not (plugin and plugin.ui) then return true end
    local ok, err = MenuOrderManager:applyLiveReload(plugin.ui, view)
    if not ok and err and err ~= "restart required" then
        self:showError(T(
            _("The saved menu could not be refreshed live:\n%1"), tostring(err)))
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
--
-- Third-party menu tables may self-reference, share subtrees, or contain
-- cycles. Traversal is therefore ITERATIVE with a visited set keyed by table
-- identity (raw equal): each table is processed at most once, so cycles and
-- shared subtrees cannot recurse forever or duplicate work, while legitimate
-- rows reached through several parents keep their titles.
--
-- CORE→UI NOTE (P1B #1, integration handoff): this is repair knowledge about
-- KOReader tree-building living on the UI object. MenuOrderManager
-- (applyLiveReload) reaches back into it via a soft require. It should move
-- beside the adapter/tree-rebuild code (Agent A's lane); until then the
-- manager owns the wiring and this file owns the algorithm.
function UIScreens:sanitizeLiveMenuTree(tree)
    if type(tree) ~= "table" then return end
    local stack = { tree }
    local visited = { [tree] = true }
    while #stack > 0 do
        local node = table.remove(stack)
        for _, entry in ipairs(node) do
            if type(entry) == "table" then
                if type(entry[1]) == "table" then
                    -- A menu level array (e.g. a top-level tab's content):
                    -- sanitize its rows.
                    if not visited[entry] then
                        visited[entry] = true
                        stack[#stack + 1] = entry
                    end
                else
                    -- A rendered row: make sure it can produce a title.
                    local has_title = type(entry.text) == "string"
                        or type(entry.text_func) == "function"
                    if not has_title and entry.separator ~= true then
                        local ok, title = pcall(MenuTitles.getTitle, MenuTitles, entry.id)
                        entry.text = ok and title or tostring(entry.id)
                    end
                    if type(entry.sub_item_table) == "table"
                            and not visited[entry.sub_item_table] then
                        visited[entry.sub_item_table] = true
                        stack[#stack + 1] = entry.sub_item_table
                    end
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
    local ui = active_plugin and active_plugin.ui
    local registrations, providers, collisions =
        KoreaderAdapter.collectLiveRegistrations(ui)
    self._collisions = collisions or {}
    local menu_items = {}
    for id, rec in pairs(registrations or {}) do
        menu_items[id] = rec.display_item or rec
    end
    return menu_items, providers
end

function UIScreens:reconcileRegisteredItems(plugin, view, persist)
    if plugin then self.plugin = plugin end
    local items, providers = self:_collectRegisteredMenuItems(plugin)
    -- P1B (#2): the collision map rides alongside; manager forwards it to
    -- Registry.buildFromData so nodes get flagged without touching entries.
    MenuOrderManager:setLiveRegistrations(view, items, providers, self._collisions)
    -- The materializer anchors newcomers implicitly; this only refreshes the
    -- ephemeral base registry so projections reflect current contributions.
    local changed = MenuOrderManager:reconcileRegisteredItems(view, items, providers)
    if changed and persist then return MenuOrderManager:saveOrder(view) end
    return changed
end

function UIScreens:promptRestart(msg)
    local message_text = msg or _("Menu order changes have been saved. Would you like to restart KOReader now for all changes to take full effect?")
    UIManager:show(ConfirmBox:new{
        text = message_text,
        ok_text = _("Restart now"),
        ok_callback = function()
            if KoreaderAdapter.requestRestart then
                KoreaderAdapter.requestRestart()
            else
                local Event = require("ui/event")
                UIManager:broadcastEvent(Event:new("Restart"))
            end
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

-- =========================================================================
-- Structured save results
-- =========================================================================

--- THE single decision point for how a save outcome is presented.
--- Consumes the structured Outcome directly from CommitPipeline/MenuOrderManager.
function UIScreens:presentSaveOutcome(outcome)
    local status = outcome.status
    if status == CommitPipeline.STATUS.SAVED
            or status == CommitPipeline.STATUS.SAVED_RESTART_REQUIRED
            or status == CommitPipeline.STATUS.NEEDS_RESTART then
        self.needs_restart = true
        if not outcome.silent then
            self:showNotice(T(
                _("%1 menu order saved. Restart KOReader to see every change."),
                outcome.view_name))
        end
        return true
    elseif status == CommitPipeline.STATUS.NEEDS_REGENERATION then
        self.needs_restart = true
        UIManager:show(InfoMessage:new{
            text = T(
                _("%1 changes saved to intent store, but menu regeneration was incomplete. Restart KOReader to complete generation.\n\nDetails: %2"),
                outcome.view_name, tostring(outcome.error or "regeneration incomplete")),
        })
        return false
    elseif status == CommitPipeline.STATUS.UNCHANGED then
        -- Semantic no-op: nothing durable happened, nothing to report.
        return true
    else
        self:showError(T(_("Error saving configuration:\n%1"),
            tostring(outcome.error or "save failed")))
        return false
    end
end

function UIScreens:saveAndApply(plugin, view, silent)
    local active_plugin = plugin or self.plugin
    local ui = active_plugin and active_plugin.ui
    self:reconcileRegisteredItems(active_plugin, view, false)
    local ok_save, path_or_err, outcome = MenuOrderManager:saveOrder(view)
    if type(outcome) ~= "table" then
        outcome = CommitPipeline.failureOutcome(
            "manager returned no structured commit outcome")
        ok_save = false
        path_or_err = outcome.error
    end
    outcome.silent = silent
    outcome.view_name = view == "reader" and _("Book view") or _("File Manager")

    if (outcome.status == CommitPipeline.STATUS.SAVED or outcome.status == CommitPipeline.STATUS.SAVED_RESTART_REQUIRED) and ui then
        self:reloadLiveMenu(active_plugin, view)
    end
    local presented_ok = self:presentSaveOutcome(outcome)
    return presented_ok, outcome.path or outcome.error, outcome
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

-- Resolve the authoritative live menu tree.
function UIScreens:_resolveTabItemTable(plugin)
    local menu = plugin and plugin.ui and plugin.ui.menu
    if menu then
        if type(menu.tab_item_table) ~= "table"
                and type(menu.setUpdateItemTable) == "function" then
            pcall(menu.setUpdateItemTable, menu)
        end
        if type(menu.tab_item_table) == "table" then
            return menu.tab_item_table
        end
    end
    if UIManager and type(UIManager._window_stack) == "table" then
        for i = #UIManager._window_stack, 1, -1 do
            local entry = UIManager._window_stack[i]
            local w = entry and (entry.widget or entry)
            if w and w.menu and type(w.menu.tab_item_table) == "table" then
                return w.menu.tab_item_table
            end
        end
    end
    return nil
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
        -- Cycle-safe iterative walk (third-party tables may self-reference,
        -- share subtrees, or contain cycles). Visited is keyed by table
        -- identity; shared subtrees are collected once — ids are accumulated
        -- into a set, so nothing legitimate is dropped by visiting a shared
        -- table only on its first parent.
        local stack = { tree }
        local visited = { [tree] = true }
        while #stack > 0 do
            local node = table.remove(stack)
            for _, entry in ipairs(node) do
                if type(entry) == "table" then
                    if entry.id ~= nil then ids[entry.id] = true end
                    if type(entry.sub_item_table) == "table"
                            and not visited[entry.sub_item_table] then
                        visited[entry.sub_item_table] = true
                        stack[#stack + 1] = entry.sub_item_table
                    elseif #entry > 0 and not visited[entry] then
                        visited[entry] = true
                        stack[#stack + 1] = entry
                    end
                end
            end
        end
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

function UIScreens:prepareForRemoval(plugin)
    local restored = KoreaderAdapter.prepareForPluginRemoval()
    local count = #restored.reader + #restored.filemanager
    if plugin and plugin.ui then
        self:reloadLiveMenu(plugin, self:getCurrentView(plugin))
    end
    if not restored.ok then
        self:showError(T(
            N_("Shown 1 item, but %2 operations failed. Do not remove the plugin yet.",
               "Shown %1 items, but %2 operations failed. Do not remove the plugin yet.",
               count),
            count, #restored.failures))
        return false, restored
    end
    local msg = count > 0
        and T(N_("Shown 1 hidden item. It is now safe to remove Reordering Menus.",
                 "Shown %1 hidden items. It is now safe to remove Reordering Menus.",
                 count),
              count)
        or _("Nothing was hidden. It is safe to remove Reordering Menus.")
    UIManager:show(InfoMessage:new{ text = msg })
    return true, restored
end

-- Confirmation wrapper shared by every "Prepare for plugin removal" entry
-- point. Showing keeps each item's current placement; it only clears the
-- hidden flag so other plugins' default locations stay findable.
function UIScreens:confirmPrepareForRemoval(plugin)
    UIManager:show(ConfirmBox:new{
        text = _("Show every hidden menu item and tab in both views?\n\nDo this before disabling or uninstalling Reordering Menus if any item was hidden: items stay where they are placed and become visible again."),
        ok_text = _("Show all"),
        ok_callback = function()
            self:prepareForRemoval(plugin)
        end,
    })
end

function UIScreens:confirmResetSubmenu(plugin, view, menu_id, menu_title, on_success)
    UIManager:show(ConfirmBox:new{
        text = T(_("Reset “%1” submenu to default?"), menu_title),
        ok_text = _("Reset"),
        ok_callback = function()
            local reset_ok, pulled_back = MenuOrderManager:resetSubmenu(view, menu_id)
            if not reset_ok then
                self:showError(T(
_("No default layout is available for %1."), menu_title))
                return
            end

            -- Items pulled back to this menu by the reset leave their old
            -- locations: drop them from any still-open editors there (e.g. a
            -- parent menu editor during drill-down) so a later save of those
            -- stale snapshots cannot duplicate the items. Durable-first
            -- notification boundary (P0 §1): resetSubmenu only STAGES; the
            -- notifications below may run only after saveOrder has durably
            -- committed, because a failed save rolls canonical staging back
            -- and the "moves" would never have happened.
            self:reconcileRegisteredItems(plugin, view, false)
            local ok, err = MenuOrderManager:saveOrder(view)
            if not ok then
                self:showError(T(
                    _("Error saving configuration:\n%1"), tostring(err)))
                return
            end
            for item_id, old_parent in pairs(pulled_back or {}) do
                self:_notifyEditorsOfMove(view, item_id, old_parent, menu_id)
            end
            if plugin and plugin.ui then
                self:reloadLiveMenu(plugin, view)
            end
            if on_success then on_success() end
        end,
    })
end

-- P0-9 atomic Reset All (ONE transaction for both views), shared by every
-- editor menu (was duplicated verbatim in both hamburgers). The commit
-- result is classified through the structured-vocabulary helper: only a
-- NEEDS_REGENERATION outcome is tolerated as success-with-restart, anything
-- else is a hard failure that leaves the caller open.
-- on_committed runs after a successful commit (callers close their editor
-- there); reopen (optional) re-launches a FRESH editor on the next tick
-- instead of repainting stale rows.
function UIScreens:confirmResetAllMenus(plugin, view, reopen, on_committed)
    UIManager:show(ConfirmBox:new{
        text = _("Reset all menus in both views to default?"),
        ok_text = _("Reset all"),
        ok_callback = function()
            local all_ok, all_err, outcome = MenuOrderManager:resetAllOrders()
            if type(outcome) ~= "table" then
                outcome = CommitPipeline.failureOutcome(
                    "manager returned no structured Reset All outcome")
            end
            local status = outcome.status
            if status ~= CommitPipeline.STATUS.SAVED
                    and status ~= CommitPipeline.STATUS.SAVED_RESTART_REQUIRED
                    and status ~= CommitPipeline.STATUS.UNCHANGED
                    and status ~= CommitPipeline.STATUS.NEEDS_REGENERATION then
                self:showError(all_err)
                return
            end
            self:reloadLiveMenu(plugin, view)
            if reopen then UIManager:nextTick(reopen) end
            if on_committed then on_committed() end
        end,
    })
end

-- Feature toggles (P1B #10/#18): one implementation each, surfaced from the
-- Advanced menu instead of being inlined in editor hamburger menus.
function UIScreens:toggleMirroring()
    local enabled = not MenuOrderManager:isMirroringEnabled()
    local ok, err = MenuOrderManager:setMirroringEnabled(enabled)
    if not ok then
        self:showError(err)
        return
    end
    self:showNotice(enabled
        and _("Mirroring on: hiding and moves between menus also apply to the other view.")
        or _("Mirroring off. Hiding and moves stay in this view."))
end

function UIScreens:toggleHiddenInPlace()
    local enabled = not MenuOrderManager:isHiddenInPlace()
    local ok, err = MenuOrderManager:setHiddenInPlace(enabled)
    if not ok then
        self:showError(err)
        return
    end
    self:showNotice(enabled
        and _("Hidden entries stay in place.")
        or _("Hidden entries move to the bottom."))
end

-- =========================================================================
-- ONE editor close lifecycle
--
-- Every user exit (title-bar X, footer exit icon, Back key, swipe) routes
-- through the same Save / Discard / Cancel prompt when the editor is dirty.
-- Programmatic dismissal (UIManager:close() firing the CloseWidget event,
-- never onClose()) is the only silent path, kept as a coherent-discard
-- safety net for flows that bypass onClose.
-- The editor title carries an "Unsaved changes" suffix while dirty.
-- Returns a handle:
--   mark_saved()               clear drag/selection state after a commit
--   close_after_commit()       suppress the dirty check and close silently
--                              (use after THIS dialog's work was just saved
--                              or intentionally abandoned by a flow that
--                              reopens a fresh editor)
--   is_closed()                true once any route has run
--   refresh_indicator()        repaint the dirty suffix from current state
-- spec = { view, has_unsaved_changes, save, confirm_title,
--          on_close_callback (optional), on_closed (optional) }
-- No framework: this is the single helper behind every editor.
-- =========================================================================
local function attachEditorCloseLifecycle(self, sort_widget, spec)
    local suppressed = false
    local closed = false
    local prompt_open = false
    local base_title = sort_widget.title
        or (sort_widget.title_bar and sort_widget.title_bar.title)
        or ""

    local function is_dirty()
        if suppressed or closed then return false end
        if spec.has_unsaved_changes then
            local ok, dirty = pcall(spec.has_unsaved_changes)
            if ok then return dirty == true end
        end
        return false
    end

    local function refreshDirtyIndicator()
        if not sort_widget.title_bar then return end
        local dirty = is_dirty()
        local want = dirty
            and (base_title .. " (" .. _("Unsaved changes") .. ")")
            or base_title
        if sort_widget.title_bar.title ~= want then
            sort_widget.title_bar.title = want
            local ok = pcall(function()
                sort_widget.title_bar:setTitle(want)
            end)
            if not ok then
                pcall(function()
                    sort_widget.title_bar.title = want
                end)
            end
        end
        if sort_widget.title ~= want then
            sort_widget.title = want
        end
    end

    local function coherent_discard_if_dirty()
        -- Hiding applies IMMEDIATELY to canonical staging while drags live
        -- only in the editor model. A silent (programmatic) close of a DIRTY
        -- editor must therefore be a full coherent discard - identical to
        -- choosing "Discard" on the route that prompts - so no route can
        -- silently keep work another route would have asked about. Clean
        -- editors and deliberate close-after-commit flows are untouched.
        if suppressed then return end
        if spec.has_unsaved_changes then
            local ok, dirty = pcall(spec.has_unsaved_changes)
            if ok and dirty then
                reloadWorkingOrderFromDisk(spec.view)
            end
        end
    end

    local function on_route_closed()
        if closed then return end
        closed = true
        coherent_discard_if_dirty()
        if spec.on_closed then spec.on_closed(sort_widget) end
    end

    local orig_on_close = sort_widget.onClose
    local function performClose(this)
        if closed then return end
        on_route_closed()
        local target = this or sort_widget
        local ret
        if orig_on_close then
            ret = orig_on_close(target)
        else
            UIManager:close(target)
        end
        if spec.on_close_callback then
            spec.on_close_callback()
        else
            self:checkPromptRestartOnExit()
        end
        return ret
    end

    local function showDirtyPrompt()
        if prompt_open or closed or suppressed then return end
        prompt_open = true
        local prompt_dialog
        prompt_dialog = ConfirmBox:new{
            text = spec.confirm_title,
            ok_text = _("Save"),
            ok_callback = function()
                prompt_open = false
                if closed or suppressed then return end
                if spec.save() then
                    suppressed = true
                    performClose(sort_widget)
                else
                    refreshDirtyIndicator()
                end
            end,
            other_buttons = {{
                {
                    text = _("Discard changes"),
                    callback = function()
                        prompt_open = false
                        if closed then return end
                        suppressed = true
                        reloadWorkingOrderFromDisk(spec.view)
                        performClose(sort_widget)
                    end,
                },
            }},
            cancel_text = _("Cancel"),
            cancel_callback = function()
                prompt_open = false
                refreshDirtyIndicator()
            end,
        }
        -- If the prompt itself is dismissed without choosing (title-bar X,
        -- Back key on the prompt), treat it as Cancel so a later exit can
        -- prompt again instead of wedging prompt_open forever.
        local orig_prompt_close = prompt_dialog.onCloseWidget
        prompt_dialog.onCloseWidget = function(this)
            prompt_open = false
            pcall(refreshDirtyIndicator)
            if orig_prompt_close then return orig_prompt_close(this) end
        end
        UIManager:show(prompt_dialog)
    end

    local function requestClose(this)
        if closed then return true end
        if suppressed then
            performClose(this or sort_widget)
            return true
        end
        local dirty = false
        if spec.has_unsaved_changes then
            local ok, d = pcall(spec.has_unsaved_changes)
            dirty = ok and d == true
        end
        if not dirty then
            performClose(this or sort_widget)
            return true
        end
        showDirtyPrompt()
        return true
    end

    -- Route: every user exit (title-bar X, footer exit icon, swipe, Back key
    -- when nothing is marked) prompts when dirty.
    sort_widget.onClose = function(this)
        return requestClose(this or sort_widget)
    end

    -- Back key: cancelling a marked row/drag is not an exit; only an
    -- unmarked Back is a close and must prompt like every other exit.
    local orig_cancel_or_close = sort_widget.onCancelOrClose
    sort_widget.onCancelOrClose = function(this)
        this = this or sort_widget
        if this.marked and this.marked > 0 then
            if this.onCancel then return this:onCancel() end
            if orig_cancel_or_close then return orig_cancel_or_close(this) end
            return true
        end
        return requestClose(this)
    end

    -- Route: programmatic dismissal fires CloseWidget, never onClose.
    -- Idempotent with the onClose wrapper (onCloseWidget fires once, after
    -- onClose already ran); on_close_callback / restart prompting stay
    -- owned by onClose alone. A direct UIManager:close() that bypassed
    -- requestClose keeps the legacy coherent-discard safety net.
    local orig_on_close_widget = sort_widget.onCloseWidget
    sort_widget.onCloseWidget = function(this)
        on_route_closed()
        if orig_on_close_widget then return orig_on_close_widget(this) end
    end

    if sort_widget.title_bar and sort_widget.title_bar.right_button then
        sort_widget.title_bar.right_button.callback = function()
            requestClose(sort_widget)
        end
    end

    -- The dirty suffix follows every repaint (drags, sorts, checkbox
    -- toggles all funnel through _populateItems).
    local orig_populate = sort_widget._populateItems
    if orig_populate then
        sort_widget._populateItems = function(this, ...)
            local ret = orig_populate(this, ...)
            pcall(refreshDirtyIndicator)
            return ret
        end
    end
    pcall(refreshDirtyIndicator)

    return {
        mark_saved = function()
            sort_widget.marked = 0
            sort_widget.orig_item_table = nil
            pcall(refreshDirtyIndicator)
        end,
        close_after_commit = function()
            if closed then return end
            suppressed = true
            performClose(sort_widget)
        end,
        is_closed = function() return closed end,
        refresh_indicator = function()
            pcall(refreshDirtyIndicator)
        end,
    }
end

-- =========================================================================
-- Shared editor-menu helpers (Search / Hidden / Sort… / Reset… / breadcrumb)
-- =========================================================================

function UIScreens:_getViewLabel(view)
    return view == "reader" and _("Book view") or _("File Manager")
end

function UIScreens:_getHiddenCount(view)
    local disabled = MenuOrderManager:getDisabledItems(view)
    return type(disabled) == "table" and #disabled or 0
end

function UIScreens:_hiddenMenuLabel(view)
    return T(_("Hidden items (%1)"), self:_getHiddenCount(view))
end

-- Compact breadcrumb for nested editors: "Book view › Tools › More tools".
-- trail_ids are ancestor menu ids (outermost first, excluding the current).
-- Internal ids (tab bar, disabled list) never appear: tabs hang directly
-- under the view label.
local function isBreadcrumbSkippedId(id)
    return id == "KOMenu:menu_buttons" or id == "KOMenu:disabled"
end

function UIScreens:_buildBreadcrumbTitle(view, trail_ids, current_menu_id)
    local parts = { self:_getViewLabel(view) }
    if type(trail_ids) == "table" then
        for _, ancestor_id in ipairs(trail_ids) do
            if not isBreadcrumbSkippedId(ancestor_id) then
                table.insert(parts, self:getDisplayTitle(view, ancestor_id))
            end
        end
    end
    if current_menu_id and not isBreadcrumbSkippedId(current_menu_id) then
        table.insert(parts, self:getDisplayTitle(view, current_menu_id))
    end
    return table.concat(parts, " › ")
end

function UIScreens:_childTrail(trail_ids, current_menu_id)
    local child = {}
    if type(trail_ids) == "table" then
        for _, id in ipairs(trail_ids) do
            if not isBreadcrumbSkippedId(id) then child[#child + 1] = id end
        end
    end
    if current_menu_id and not isBreadcrumbSkippedId(current_menu_id) then
        child[#child + 1] = current_menu_id
    end
    return child
end

-- Submenu navigation affordance: an edge-aligned arrow rendered as a separate
-- widget by the SortItemWidget patch (see ui_compat.lua), so the visible
-- arrow and its tap bounds are the same rectangle. Row text stays plain
-- titles here; tapping the arrow drills down immediately, while tapping
-- elsewhere still selects/marks for dragging.

-- "Sort…" submenu shared by every editor hamburger menu.
function UIScreens:showSortSubmenu(sort_widget)
    local target = sort_widget
    local dialog
    local buttons = {
        {{
            text = _("Sort A to Z"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                target:sortItems("natural")
            end,
        }},
        {{
            text = _("Sort Z to A"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                target:sortItems("natural", true)
            end,
        }},
    }
    dialog = showButtonMenu(buttons, {
        title = _("Sort"),
        title_align = "center",
        shrink_unneeded_width = true,
    })
end

-- =========================================================================
-- Top Tabs Reorder & Visibility Screen (SortWidget) - unified
-- -------------------------------------------------------------------------
-- Data gathering lives in _buildItemEditorModel helpers; the close routes
-- share attachEditorCloseLifecycle; the hamburger menu routes every mutation
-- through manager operations + saveAndApply. Widget callbacks perform NO
-- disk writes, NO native writes and NO provider reconciliation beyond the
-- centralized save path.
-- =========================================================================

-- KOReader's static menu-order files include conditional top-level tabs.
-- The File Manager's `plus_menu`, for example, is only added to the actual
-- menu on non-touch devices; touch devices expose the same action as the
-- separate + button in the file-browser chrome.  Editing the static list
-- directly therefore produces phantom editor rows which cannot appear in the
-- live tab bar.
--
-- Once KOReader has built the menu, tab_item_table is the authoritative live
-- top-level set.  Return nil before that first build so direct/test callers
-- keep the conservative (show everything) behaviour.
function UIScreens:_getRenderedTopLevelTabs(plugin)
    local active_plugin = plugin or self.plugin
    local ui = active_plugin and active_plugin.ui
    local menu = ui and ui.menu
    local rendered = menu and menu.tab_item_table
    if type(rendered) ~= "table" or #rendered == 0 then return nil end

    local ids = {}
    for _, tab in ipairs(rendered) do
        if type(tab) == "table" and type(tab.id) == "string" then
            ids[tab.id] = true
        end
    end
    if next(ids) == nil then return nil end
    return ids
end

function UIScreens:_getEditorTabIds(plugin, view)
    local rendered = self:_getRenderedTopLevelTabs(plugin)
    local tabs, seen = {}, {}
    local function add(tab_id)
        if seen[tab_id] then return end
        -- Hidden tabs must remain in the editor so they can always be
        -- restored, even though they are intentionally absent from the live
        -- rendered set.  All other rows must correspond to a rendered tab.
        if rendered == nil or rendered[tab_id]
                or MenuOrderManager:isItemHidden(view, tab_id) then
            seen[tab_id] = true
            tabs[#tabs + 1] = tab_id
        end
    end
    for _, tab_id in ipairs(MenuOrderManager:getTabs(view)) do add(tab_id) end
    for _, tab_id in ipairs(MenuOrderManager:getAllKnownTabs(view)) do add(tab_id) end
    return tabs
end

function UIScreens:_mergeEditorTabOrder(view, source_items)
    local desired = {}
    local managed = {}
    for _, sort_item in ipairs(source_items or {}) do
        local tab_id = sort_item.tab_id
        if tab_id then
            managed[tab_id] = true
            if not MenuOrderManager:isItemHidden(view, tab_id) then
                desired[#desired + 1] = tab_id
            end
        end
    end

    local merged = {}
    local desired_index = 1
    for _, tab_id in ipairs(MenuOrderManager:getTabs(view)) do
        if managed[tab_id] then
            local replacement = desired[desired_index]
            if replacement then
                merged[#merged + 1] = replacement
                desired_index = desired_index + 1
            end
        else
            merged[#merged + 1] = tab_id
        end
    end
    while desired_index <= #desired do
        merged[#merged + 1] = desired[desired_index]
        desired_index = desired_index + 1
    end
    return merged
end

function UIScreens:_getManagedTabsFromCurrentProjection(view, source_items)
    local managed = {}
    for _, sort_item in ipairs(source_items or {}) do
        if sort_item.tab_id then managed[sort_item.tab_id] = true end
    end
    local current = {}
    for _, tab_id in ipairs(MenuOrderManager:getTabs(view)) do
        if managed[tab_id] and not MenuOrderManager:isItemHidden(view, tab_id) then
            current[#current + 1] = tab_id
        end
    end
    return current
end

function UIScreens:showTabReorderDialog(plugin, view, on_close_callback)
    if plugin then self.plugin = plugin end
    view = view or self:getCurrentView(plugin)
    -- P1B #13: same lazy, refcounted tap enhancement as the item editor;
    -- released by this editor's close lifecycle.
    UICompat.installSortWidgetSubmenuTap(SortWidget)

    -- Model builders ------------------------------------------------------
    local sort_widget
    local function makeTabItem(tid)
        local tab_title = MenuTitles:getTitle(tid)
        local icon = MenuTitles:getIcon(tid)
        -- The id is internal; show the localized title (with an icon marker
        -- when one exists). Drill-down navigation is marked by the
        -- edge-aligned arrow widget (see ui_compat.lua), not by text here,
        -- so the row label stays a plain title. No internal identifier
        -- in user-facing labels.
        local base_text = icon and T(_("%1 [%2]"), tab_title, _("tab")) or tab_title
        local display_text = base_text
        return {
            text = display_text,
            tab_id = tid,
            item_id = tid,
            is_submenu = true,
            onSubmenuTap = function()
                self:showItemSortWidget(plugin, view, tid, function()
                    if sort_widget then sort_widget:_populateItems() end
                end, nil)
            end,
            checked_func = function()
                return not MenuOrderManager:isItemHidden(view, tid)
            end,
            callback = function()
                local is_hidden = MenuOrderManager:isItemHidden(view, tid)
                if not is_hidden then
                    if MenuOrderManager:isTabProtected(tid) then
                        UIManager:show(Notification:new{
                            text = T(_("%1 cannot be hidden."),
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
                    self:reconcileRegisteredItems(plugin, view, false)
                end
                MenuOrderManager:setTabHidden(view, tid, not is_hidden)
            end,
            hold_callback = function(self_item, refresh_func)
                local dialog
                local buttons = {
                    {{
                        text = T(_("Edit submenu contents %1"), submenuArrow()),
                        callback = function()
                            UIManager:close(dialog)
                            self:showItemSortWidget(plugin, view, tid, function()
                                if refresh_func then refresh_func() end
                            end, nil)
                        end,
                    }},
                    {{
                        text = _("Hide this tab"),
                        callback = function()
                            UIManager:close(dialog)
                            if MenuOrderManager:isTabProtected(tid) then
                                UIManager:show(Notification:new{
                                    text = T(_("%1 cannot be hidden."),
                                        MenuTitles:getTitle(tid)),
                                })
                                return
                            end
                            self:reconcileRegisteredItems(plugin, view, false)
                            MenuOrderManager:setTabHidden(view, tid, true)
                            if refresh_func then refresh_func() end
                        end,
                    }},
                }
                dialog = ButtonDialog:new{
                    title = T(_("“%1”"), MenuTitles:getTitle(tid)),
                    title_align = "center",
                    buttons = buttons,
                }
                UIManager:show(dialog)
            end,
        }
    end

    local function buildSortItems()
        local items = {}
        for _, tab_id in ipairs(self:_getEditorTabIds(plugin, view)) do
            table.insert(items, makeTabItem(tab_id))
        end
        return items
    end

    -- Visible-order projection --------------------------------------------
    local sort_items = buildSortItems()
    local last_saved_disabled = util.tableDeepCopy(MenuOrderManager:getDisabledItems(view))
    local function mark_tabs_saved()
        last_saved_disabled = util.tableDeepCopy(MenuOrderManager:getDisabledItems(view))
    end
    local function visibleTabsOf(source_items)
        local new_tabs = {}
        for __, sort_item in ipairs(source_items or {}) do
            local tid = sort_item.tab_id
            if tid and not MenuOrderManager:isItemHidden(view, tid) then
                table.insert(new_tabs, tid)
            end
        end
        return new_tabs
    end
    -- Merge the editor's rendered-tab ordering back into the complete
    -- projection. Conditional tabs filtered from this device's editor retain
    -- their slots and intent, so saving on a touch device cannot remove the
    -- non-touch File Manager plus tab (or an analogous future KOReader tab).
    local function fullTabOrderFrom(source_items)
        return self:_mergeEditorTabOrder(view, source_items)
    end
    local function managedTabsFromCurrentProjection(source_items)
        return self:_getManagedTabsFromCurrentProjection(view, source_items)
    end
    local function tabs_have_unsaved_changes()
        if not sort_widget or type(sort_widget.item_table) ~= "table" then return false end
        if not id_lists_match(
                visibleTabsOf(sort_widget.item_table),
                managedTabsFromCurrentProjection(sort_widget.item_table)) then
            return true
        end
        return not id_lists_match(
            MenuOrderManager:getDisabledItems(view), last_saved_disabled)
    end
    local lifecycle
    local function save_tab_model()
        local source_items = (sort_widget and sort_widget.item_table) or sort_items
        MenuOrderManager:reorderTabs(view, fullTabOrderFrom(source_items))
        if not self:saveAndApply(plugin, view) then return false end
        if sort_widget then
            sort_widget.marked = 0
            sort_widget.orig_item_table = nil
        end
        mark_tabs_saved()
        if lifecycle then pcall(function() lifecycle.refresh_indicator() end) end
        return true
    end
    -- Bug 6: stage the dialog's VISIBLE model (drag order + hide toggles)
    -- without persisting it. Used before a full-preset capture so the preset
    -- represents the arrangement the user is looking at, not the last-saved
    -- one. Does NOT close/save the dialog: after capture the user can keep
    -- editing or discard; only the captured snapshot is affected.
    local function stage_visible_tab_draft()
        if not (sort_widget and type(sort_widget.item_table) == "table") then
            return false
        end
        MenuOrderManager:reorderTabs(view,
            fullTabOrderFrom(sort_widget.item_table))
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

    -- Widget construction ---------------------------------------------------
    local title_view = view == "reader" and _("Book view") or _("File Manager")
    local reset_view_label = view == "reader" and _("Reset Book view") or _("Reset File Manager")
    local reset_view_prompt = view == "reader" and _("Reset Book view to default?") or _("Reset File Manager to default?")
    sort_widget = SortWidget:new{
        title = T(_("%1 (%2)"), _("Reorder menus"), title_view),
        item_table = sort_items,
        callback = function()
            save_tab_model()
        end,
    }

    lifecycle = attachEditorCloseLifecycle(self, sort_widget, {
        view = view,
        has_unsaved_changes = tabs_have_unsaved_changes,
        save = save_tab_model,
        confirm_title = T(_("Save changes to %1?"), title_view),
        on_close_callback = on_close_callback,
        on_closed = function()
            UICompat.releaseSortWidgetSubmenuTap(SortWidget)
        end,
    })

    -- Hamburger menu --------------------------------------------------------
    function sort_widget:onShowWidgetMenu()
        local this = self
        local dialog
        local buttons = {}

        local function openResetSubmenu()
            local reset_dialog
            local reset_buttons = {}
            table.insert(reset_buttons, {{
                text = reset_view_label,
                align = "left",
                callback = function()
                    UIManager:close(reset_dialog)
                    UIManager:show(ConfirmBox:new{
                        text = reset_view_prompt,
                        ok_text = _("Reset"),
                        ok_callback = function()
                            local reset_ok, reset_err = MenuOrderManager:resetOrder(view)
                            if not reset_ok then
                                UIScreens:showError(reset_err)
                                return
                            end
                            UIScreens:reloadLiveMenu(plugin, view)
                            UIManager:nextTick(function()
                                UIScreens:showTabReorderDialog(plugin, view)
                            end)
                            lifecycle.close_after_commit()
                        end,
                    })
                end,
            }})
            if this.marked > 0 then
                local sel = this.item_table[this.marked]
                if sel and sel.tab_id then
                    local sel_title = MenuTitles:getTitle(sel.tab_id)
                    table.insert(reset_buttons, {{
                        text = T(_("Reset selected submenu (%1)"), sel_title),
                        align = "left",
                        callback = function()
                            UIManager:close(reset_dialog)
                            UIScreens:confirmResetSubmenu(plugin, view, sel.tab_id,
                                sel_title, refreshSortItems)
                        end,
                    }})
                end
            end
            table.insert(reset_buttons, {{
                text = _("Reset both views"),
                align = "left",
                callback = function()
                    UIManager:close(reset_dialog)
                    UIScreens:confirmResetAllMenus(plugin, view, function()
                        UIScreens:showTabReorderDialog(plugin, view)
                    end, function()
                        lifecycle.close_after_commit()
                    end)
                end,
            }})
            reset_dialog = showButtonMenu(reset_buttons, {
                title = _("Reset…"),
                title_align = "center",
                shrink_unneeded_width = true,
            })
        end

        if this.marked > 0 then
            local sel = this.item_table[this.marked]
            if sel and sel.tab_id then
                table.insert(buttons, {{
                    text = T(_("Edit submenu “%1” %2"),
                        MenuTitles:getTitle(sel.tab_id), submenuArrow()),
                    align = "left",
                    callback = function()
                        UIManager:close(dialog)
                        UIScreens:showItemSortWidget(plugin, view, sel.tab_id, function()
                            this:_populateItems()
                        end, nil)
                    end,
                }})
            end
        end
        table.insert(buttons, {{
            text = _("Search…"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                UIScreens:showSearchDialog(plugin, view)
            end,
        }})
        table.insert(buttons, {{
            text = UIScreens:_hiddenMenuLabel(view),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                UIScreens:showHiddenItemsManager(plugin, view)
            end,
        }})
        table.insert(buttons, {{
            text = _("Sort…"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                UIScreens:showSortSubmenu(this)
            end,
        }})
        table.insert(buttons, {{
            text = _("Presets…"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                UIScreens:showPresetsMenu(plugin, view, function(preset_applied)
                    if preset_applied then
                        refreshSortItems()
                    end
                end, stage_visible_tab_draft)
            end,
        }})
        table.insert(buttons, {{
            text = _("Reset…"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                openResetSubmenu()
            end,
        }})
        table.insert(buttons, {{
            text = _("Advanced…"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                UIScreens:showAdvancedMenu(plugin, view)
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
-- Create Submenu dialog
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
                                text = T(_("No default layout is available for %1."),
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

-- =========================================================================
-- Item Sort Widget Screen - UNIFIED reordering interface
-- Handles reorder, hide/show (checkbox), separators, move between menus via long-press
-- -------------------------------------------------------------------------
-- P1B #3 decomposition: data gathering lives in _buildItemEditorModel (pure
-- manager reads); the close routes share attachEditorCloseLifecycle; the
-- hamburger menu routes every mutation through manager operations +
-- saveAndApply. Widget callbacks perform NO disk writes, NO native writes
-- and NO provider reconciliation beyond the centralized save path.
-- =========================================================================

-- Gather everything the item editor renders from, without building widgets:
-- configured order, hidden rows for this menu, the live tree slice, the
-- renderable-id set, and the merged display list + preserved-unavailable list.
function UIScreens:_buildItemEditorModel(plugin, view, menu_id)
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
    return {
        configured_items = configured_items,
        hidden_for_menu = hidden_for_menu,
        live_ids = live_ids,
        live_items_by_id = live_items_by_id,
        has_live_menu = has_live_menu,
        renderable_ids = renderable_ids,
        items = items,
        unavailable_items = unavailable_items,
    }
end

function UIScreens:showItemSortWidget(plugin, view, menu_id, on_close_callback, trail_ids)
    if plugin then self.plugin = plugin end
    -- Support the legacy 4-arg call (trail omitted) and the breadcrumb-aware
    -- 5-arg call. If the 4th arg is a table and the 5th is nil, it is the
    -- trail with no close callback.
    if type(on_close_callback) == "table" and trail_ids == nil then
        trail_ids = on_close_callback
        on_close_callback = nil
    end
    -- When no explicit trail was passed (legacy callers, search results),
    -- derive ancestors by walking the parent chain so the breadcrumb still
    -- shows the full path.
    if trail_ids == nil then
        local ancestors = {}
        local walker = MenuOrderManager:getParentMenu(view, menu_id)
        local guard = 0
        while walker and guard < 32 do
            guard = guard + 1
            table.insert(ancestors, 1, walker)
            walker = MenuOrderManager:getParentMenu(view, walker)
        end
        trail_ids = ancestors
    end
    -- Install the private SortItemWidget tap enhancement for THIS editor
    -- only (refcounted across drill-down nesting); released in the close
    -- lifecycle's on_closed.
    UICompat.installSortWidgetSubmenuTap(SortWidget)

    local menu_title = self:getDisplayTitle(view, menu_id)
    local breadcrumb_title = self:_buildBreadcrumbTitle(view, trail_ids, menu_id)
    local child_trail = self:_childTrail(trail_ids, menu_id)
    local model = self:_buildItemEditorModel(plugin, view, menu_id)
    local live_items_by_id = model.live_items_by_id
    local items = model.items
    local unavailable_items = model.unavailable_items
    local hidden_for_menu = model.hidden_for_menu

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
                end, child_trail)
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
                        text = T(
_("%1 cannot be hidden."),
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
                        text = T(
_("Shown “%1”."),
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
                                        text = T(
_("%1 cannot be hidden."),
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
                                    if self:saveAndApply(plugin, view, true) then
                                        UIManager:show(Notification:new{
                                            text = T(
_("Restored “%1”."),
                                                MenuTitles:getTitle(this_id, live_items_by_id)),
                                        })
                                        -- The placement is durably restored;
                                        -- close this editor and reopen it
                                        -- fresh so the close check compares
                                        -- against reality.
                                        lifecycle.close_after_commit()
                                        UIManager:nextTick(function()
                                            self:showItemSortWidget(plugin, view, menu_id,
                                                on_close_callback, trail_ids)
                                        end)
                                    end
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
                            text = T(_("Edit submenu contents %1"), submenuArrow()),
                            callback = function()
                                UIManager:close(dialog)
                                self:showItemSortWidget(plugin, view, this_id, function()
                                    if refresh_func then refresh_func() end
                                end, child_trail)
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
                                    text = T(_("Delete the empty submenu “%1”?"), submenu_title),
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
                                        self:showNotice(T(
_("Submenu “%1” deleted."), submenu_title))
                                        if refresh_func then refresh_func() end
                                    end,
                                })
                            end,
                        }
                    })
                end
                dialog = ButtonDialog:new{
                    title = T(_("“%1”"), self:getDisplayTitle(view, this_id, live_items_by_id)),
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
            -- Plain title: the edge arrow widget marks submenus (ui_compat).
            local display_text = item_title
            table.insert(sort_items, makeSortItem(item_id, is_submenu, display_text))
        end
    end

    local function make_hidden_row(hid)
        local this_id = hid
        local item_title = self:getDisplayTitle(view, this_id, live_items_by_id)
        local is_submenu = MenuOrderManager:isSubmenu(view, this_id)
        local display_text = T(_("%1 (%2)"), item_title, _("hidden"))
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
                -- Tapping checkbox shows the item again
                MenuOrderManager:setItemHidden(view, this_id, false, menu_id)
                if move_row_within_editor then
                    move_row_within_editor(entry, false)
                end
                UIManager:show(Notification:new{
                    text = T(
_("Shown “%1”."),
                        self:getDisplayTitle(view, this_id, live_items_by_id)),
                })
            end,
            hold_callback = function(self_item, refresh_func)
                UIManager:show(ConfirmBox:new{
                    text = T(_("Show “%1” in this menu again? It stays where it is placed."),
                        self:getDisplayTitle(view, this_id, live_items_by_id)),
                    ok_text = _("Show"),
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
    --
    -- Schema v3: the historical hidden-anchor side table is gone; the
    -- display anchor is DERIVED instead. A hidden row's previous visible
    -- sibling is its nearest preceding neighbour from the stock/default
    -- layout that is present among the editor's current rows. This is pure
    -- presentation (where to SHOW the dimmed row), never persisted state.
    local default_list_for_anchors =
        MenuOrderManager:getDefaultOrder(view)[menu_id] or {}
    local function derive_hidden_anchor(hid)
        local hid_index
        for i, id in ipairs(default_list_for_anchors) do
            if id == hid then hid_index = i break end
        end
        if hid_index then
            for i = hid_index - 1, 1, -1 do
                local candidate = default_list_for_anchors[i]
                if candidate ~= MenuOrderManager.SEPARATOR_ID then
                    return candidate
                end
            end
            return nil
        end
        -- For plugin-contributed / foreign items not in the static stock defaults:
        -- Materializer places them after stock defaults, sorted alphabetically by ID.
        local default_set = {}
        for _, id in ipairs(default_list_for_anchors) do default_set[id] = true end

        local best_foreigner_anchor = nil
        for _, r in ipairs(sort_items) do
            local rid = r and r.item_id
            if rid and rid ~= EMPTY_HINT_ID and rid ~= MenuOrderManager.SEPARATOR_ID
                    and not r.is_hidden_row and not default_set[rid] then
                if rid < hid then
                    best_foreigner_anchor = rid
                end
            end
        end
        if best_foreigner_anchor then
            return best_foreigner_anchor
        end
        -- If no preceding foreigner, anchor to the last stock default resident:
        for i = #default_list_for_anchors, 1, -1 do
            local candidate = default_list_for_anchors[i]
            if candidate ~= MenuOrderManager.SEPARATOR_ID then
                return candidate
            end
        end
        return nil
    end
    local function append_hidden_row(hid)
        seen_hidden[hid] = true
        local entry = make_hidden_row(hid)
        if not hidden_in_place then
            table.insert(sort_items, entry)
            return
        end
        -- Preserve-location mode: re-insert right after the derived previous
        -- visible sibling so the dimmed row sits where the entry used to.
        local anchor_id = derive_hidden_anchor(hid)
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
        local base = tostring(UIScreens:getDisplayTitle(view, entry.item_id, live_items_by_id))
        if to_hidden then
            base = base .. " (" .. _("hidden") .. ")"
        end
        -- No inline arrow: the edge arrow widget marks submenus (ui_compat).
        entry.text = base
        entry.checked_func = function()
            return not MenuOrderManager:isItemHidden(view, entry.item_id)
        end
        entry.dim = to_hidden and true or nil
        entry.is_hidden_row = to_hidden and true or nil

        -- Preserve-location mode: the row keeps its exact position; only its
        -- presentation flipped. Bottom mode relocates it into/out of the
        -- trailing hidden section as before.
        if MenuOrderManager:isHiddenInPlace() then
            if not to_hidden then
                -- Restoring a row that was displayed via the bottom-fallback
                -- section: land it at the end of the VISIBLE block (ahead of
                -- any remaining dimmed rows). A row already sitting at its
                -- preserved in-place position (no hidden rows after it and
                -- visible rows before it) is left exactly where it is.
                local row_index = UIEditorModel.firstRowIndex(
                    sort_widget.item_table, function(row) return row == entry end)
                local first_hidden = UIEditorModel.firstRowIndex(
                    sort_widget.item_table,
                    function(row) return row.is_hidden_row end)
                local visible_before = false
                for i = 1, (row_index or 1) - 1 do
                    local r = sort_widget.item_table[i]
                    if r and not r.is_hidden_row then
                        visible_before = true
                        break
                    end
                end
                if row_index and first_hidden and first_hidden < row_index
                        and visible_before then
                    UIEditorModel.removeRow(sort_widget.item_table, entry)
                    UIEditorModel.insertRow(sort_widget.item_table,
                        first_hidden, entry)
                end
            end
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
        local new_row = makeSortItem(moved_item_id, is_submenu, item_title)
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
    -- Out-of-band staging baseline (see editor_has_unsaved_changes): whatever
    -- the shared transaction holds RIGHT NOW belongs to prior context. Only
    -- staging added while this editor is open counts as its unsaved work.
    local initial_txn = MenuOrderManager.peekTransaction
        and MenuOrderManager:peekTransaction() or nil
    local initial_txn_staged = {}
    for _, v in ipairs({ "reader", "filemanager" }) do
        initial_txn_staged[v] = initial_txn
            and util.tableDeepCopy(initial_txn:view(v)) or {}
    end
    mark_editor_saved = function()
        if sort_widget and type(sort_widget.item_table) == "table" then
            last_saved_model = buildPersistentOrder(sort_widget.item_table)
        else
            last_saved_model = buildPersistentOrder(sort_items)
        end
    end
    local function editor_has_unsaved_changes()
        -- Out-of-band staging guard (P0 §9/H2b): the shared transaction is
        -- view-global, so a cross-menu move staged through the manager API
        -- while this editor is open never touches its rows - the model-vs-
        -- baseline check alone cannot see it, and a silent close would let
        -- it ride the next save. Scope: staging that appeared AFTER this
        -- editor opened (snapshotted below). Pre-existing staged residue
        -- (startup reconcile repairs) is deliberately NOT this editor's to
        -- prompt about - silent closes already sweep it via
        -- reloadWorkingOrderFromDisk, and nagging on every routine close of
        -- a freshly opened menu is a UX regression. A stale-epoch txn is
        -- excluded symmetrically: commit() refuses it, so it cannot ride a
        -- later save either.
        if initial_txn_staged and MenuOrderManager.peekTransaction then
            local txn = MenuOrderManager:peekTransaction()
            if txn and (txn.store_epoch == nil
                    or txn.store_epoch == IntentStore.storeEpoch()) then
                -- Reference point depends on WHICH transaction we are looking
                -- at: our birth txn -> the snapshot taken at open; a REPLACED
                -- txn (a sibling editor saved meanwhile) -> its own baseline,
                -- canonical, since fresh staging mirrors canonical at birth.
                for _, v in ipairs({ "reader", "filemanager" }) do
                    local reference = (txn == initial_txn)
                        and initial_txn_staged[v] or IntentStore.view(v)
                    if not util.tableEquals(txn:view(v), reference) then
                        return true
                    end
                end
            end
        end
        if not sort_widget or type(sort_widget.item_table) ~= "table" then return false end
        return not id_lists_match(
            buildPersistentOrder(sort_widget.item_table), last_saved_model)
    end
    -- Defined after the widget/lifecycle exist: clears drag/selection state
    -- through the shared lifecycle handle once a commit has landed.
    local mark_saved_via_lifecycle
    local function save_editor_model()
        local source_items = (sort_widget and sort_widget.item_table) or sort_items
        -- The editor model is translated into minimal intent operations
        -- against the freshly materialized baseline and committed atomically.
        MenuOrderManager:stageList(view, menu_id,
            buildPersistentOrder(source_items))
        local saved, save_err = self:saveAndApply(plugin, view)
        if not saved then
            -- A semantic no-op save ("unchanged") means canonical state
            -- ALREADY equals this editor's model (e.g. a drag hand-reverted
            -- before saving). The durable state matches what the user asked
            -- for: refresh the saved baseline so the editor becomes clean
            -- instead of staying permanently dirty on a save that cannot
            -- fail louder.
            if save_err == CommitPipeline.STATUS.UNCHANGED then
                if mark_editor_saved then mark_editor_saved() end
                if mark_saved_via_lifecycle then mark_saved_via_lifecycle() end
                return true
            end
            -- Real failure: the ConfirmBox has already closed; the editor
            -- stays open and dirty (staged draft survives via the saveOrder
            -- rebase), so pressing Save again retries. saveAndApply has
            -- already shown the error toast.
            return false
        end
        -- Durable commit: the current model is the new saved baseline, and
        -- drag/selection state clears (which also repaints the dirty suffix).
        if mark_editor_saved then mark_editor_saved() end
        if mark_saved_via_lifecycle then mark_saved_via_lifecycle() end
        return true
    end

    sort_widget = SortWidget:new{
        title = T(_("%1 - %2"), _("Reorder"), breadcrumb_title),
        item_table = sort_items,
        callback = function()
            save_editor_model()
        end,
    }
    sort_widget.syncMovedIn = syncMovedIn
    sort_widget.syncMovedOut = syncMovedOut
    UIEditorRegistry:register(view, menu_id, sort_widget)

    local lifecycle = attachEditorCloseLifecycle(self, sort_widget, {
        view = view,
        has_unsaved_changes = editor_has_unsaved_changes,
        save = save_editor_model,
        confirm_title = T(_("Save changes to “%1”?"), breadcrumb_title),
        on_close_callback = on_close_callback,
        on_closed = function(widget)
            UIEditorRegistry:unregister(widget)
            -- P1B #13: release this editor's claim on the private tap patch.
            UICompat.releaseSortWidgetSubmenuTap(SortWidget)
        end,
    })
    mark_saved_via_lifecycle = function() lifecycle.mark_saved() end

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
        local selected_submenu_id
        local selected_submenu_title
        if this.marked > 0 then
            local sel = this.item_table[this.marked]
            if sel and sel.item_id and sel.is_submenu then
                selected_submenu_id = sel.item_id
                selected_submenu_title = outer_self_item:getDisplayTitle(view, sel.item_id, live_items_by_id)
            end
        end
        local function openResetSubmenu()
            local reset_dialog
            local reset_buttons = {}
            table.insert(reset_buttons, {{
                text = T(_("Reset this submenu (%1)"), menu_title),
                align = "left",
                callback = function()
                    UIManager:close(reset_dialog)
                    outer_self_item:confirmResetSubmenu(plugin, view, menu_id, menu_title, function()
                        UIManager:nextTick(function()
                            outer_self_item:showItemSortWidget(plugin, view, menu_id, on_close_callback, trail_ids)
                        end)
                        lifecycle.close_after_commit()
                    end)
                end,
            }})
            if selected_submenu_id then
                table.insert(reset_buttons, {{
                    text = T(_("Reset selected submenu (%1)"), selected_submenu_title),
                    align = "left",
                    callback = function()
                        UIManager:close(reset_dialog)
                        outer_self_item:confirmResetSubmenu(plugin, view, selected_submenu_id, selected_submenu_title, function()
                            -- The reset saved a new layout for the submenu; reopen
                            -- this editor fresh instead of repainting stale rows,
                            -- so the close check compares against reality.
                            UIManager:nextTick(function()
                                outer_self_item:showItemSortWidget(plugin, view, menu_id, on_close_callback, trail_ids)
                            end)
                            lifecycle.close_after_commit()
                        end)
                    end,
                }})
            end
            table.insert(reset_buttons, {{
                text = _("Reset both views"),
                align = "left",
                callback = function()
                    UIManager:close(reset_dialog)
                    outer_self_item:confirmResetAllMenus(plugin, view, function()
                        outer_self_item:showTabReorderDialog(plugin, view)
                    end, function()
                        lifecycle.close_after_commit()
                    end)
                end,
            }})
            reset_dialog = showButtonMenu(reset_buttons, {
                title = _("Reset…"),
                title_align = "center",
                shrink_unneeded_width = true,
            })
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
                            local new_row = makeSortItem(new_id, true, title)
                            submenu_insert_pos = UIEditorModel.insertRow(
                                this.item_table, submenu_insert_pos, new_row)
                            this.marked = submenu_insert_pos
                            refreshPaging(this, submenu_insert_pos)
                            outer_self_item:showNotice(T(
_("Submenu “%1” created."), title))
                            mark_editor_saved()
                        end)
                end,
            }},
        }
        if selected_submenu_id then
            table.insert(buttons, {{
                text = T(_("Edit submenu “%1” %2"), selected_submenu_title, submenuArrow()),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    outer_self_item:showItemSortWidget(plugin, view, selected_submenu_id, function()
                        this:_populateItems()
                    end, child_trail)
                end,
            }})
        end
        table.insert(buttons, {{
            text = _("Search…"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                outer_self_item:showSearchDialog(plugin, view)
            end,
        }})
        table.insert(buttons, {{
            text = outer_self_item:_hiddenMenuLabel(view),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                outer_self_item:showHiddenItemsManager(plugin, view)
            end,
        }})
        table.insert(buttons, {{
            text = _("Sort…"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                outer_self_item:showSortSubmenu(this)
            end,
        }})
        table.insert(buttons, {{
            text = T(_("Presets for %1…"), menu_title),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                local current_menu_items = buildOrderFromSortItems(this.item_table)
                outer_self_item:showSubmenuPresetsMenu(plugin, view, menu_id, menu_title, function(preset_applied)
                    if preset_applied then
                        -- The submenu preset staged into this editor's open
                        -- transaction; reopen this editor fresh so its model
                        -- reflects the staged reality, and skip the dirty
                        -- discard on the way out.
                        UIManager:nextTick(function()
                            outer_self_item:showItemSortWidget(plugin, view, menu_id, on_close_callback, trail_ids)
                        end)
                        lifecycle.close_after_commit()
                    end
                end, current_menu_items)
            end,
        }})
        table.insert(buttons, {{
            text = _("Reset…"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                openResetSubmenu()
            end,
        }})
        table.insert(buttons, {{
            text = _("Advanced…"),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                outer_self_item:showAdvancedMenu(plugin, view)
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

-- Resolve an item's CURRENT position (and current list length) in a menu by
-- its stable id. Long-lived UI (search results, open dialogs) captures ids;
-- menus can change between capture and action, so every mutation re-resolves
-- immediately before touching anything. Returns nil when the id is gone.
-- Works for SEPARATOR_ID too (first occurrence) — used by the separator path.
function UIScreens:_currentIndexOfItem(view, menu_id, item_id)
    local items = MenuOrderManager:getMenuItems(view, menu_id)
    if type(items) ~= "table" then return nil, 0 end
    for index, id in ipairs(items) do
        if id == item_id then return index, #items end
    end
    return nil, #items
end

-- Stale-result behavior: the tapped entry no longer matches live state.
-- Never mutate "whatever is now at the old index"; explain and let the
-- caller refresh back to a fresh view of current state.
function UIScreens:showStaleResultNotice(item_title)
    UIManager:show(InfoMessage:new{
        text = T(_("%1 is no longer available here. The menu changed since it was found — search again for fresh results."),
            item_title),
    })
end

function UIScreens:showItemActionDialog(plugin, view, menu_id, item_id, idx_hint, on_update_callback)
    if plugin then self.plugin = plugin end
    local is_sep = (item_id == MenuOrderManager.SEPARATOR_ID)
    local item_title = is_sep and _("Separator") or self:getDisplayTitle(view, item_id)

    -- Search identity rule: results retain the stable ITEM ID; positions are
    -- resolved from that id at action time. idx_hint is advisory only (it
    -- shaped which affordances made sense when the entry was created) and
    -- never drives a mutation.
    local current_idx, total_items = self:_currentIndexOfItem(view, menu_id, item_id)
    if not current_idx then
        self:showStaleResultNotice(item_title)
        if on_update_callback then on_update_callback() end
        return
    end

    local actions = {}

    if not is_sep then
        -- Re-resolve by stable id immediately before mutating.
        local function currentPosOrFail()
            local cur = self:_currentIndexOfItem(view, menu_id, item_id)
            if not cur then
                self:showStaleResultNotice(item_title)
                if on_update_callback then on_update_callback() end
            end
            return cur
        end
        if current_idx > 1 then
            table.insert(actions, {
                text = _("Move up"),
                callback = function()
                    local cur = currentPosOrFail()
                    if not cur or cur <= 1 then return end
                    MenuOrderManager:moveItem(view, menu_id, cur, cur - 1)
                    if not self:saveAndApply(plugin, view) then return end
                    on_update_callback()
                end,
            })
        end
        if current_idx < total_items then
            table.insert(actions, {
                text = _("Move down"),
                callback = function()
                    local cur, total = currentPosOrFail()
                    if not cur or cur >= total then return end
                    MenuOrderManager:moveItem(view, menu_id, cur, cur + 1)
                    if not self:saveAndApply(plugin, view) then return end
                    on_update_callback()
                end,
            })
        end
        if current_idx > 1 then
            table.insert(actions, {
                text = _("Move to top"),
                callback = function()
                    local cur = currentPosOrFail()
                    if not cur or cur <= 1 then return end
                    MenuOrderManager:moveItem(view, menu_id, cur, 1)
                    if not self:saveAndApply(plugin, view) then return end
                    on_update_callback()
                end,
            })
        end
        if current_idx < total_items then
            table.insert(actions, {
                text = _("Move to bottom"),
                callback = function()
                    local cur, total = currentPosOrFail()
                    if not cur or cur >= total then return end
                    MenuOrderManager:moveItem(view, menu_id, cur, total)
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
                local cur = currentPosOrFail()
                if not cur then return end
                if MenuOrderManager:isItemProtected(item_id) then
                    UIManager:show(Notification:new{
                        text = T(
_("%1 cannot be hidden."),
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
                -- Id-keyed operation: correct regardless of current position.
                local ok_restore, err_restore =
                    MenuOrderManager:restoreItemDefault(view, item_id)
                if ok_restore then
                    if not self:saveAndApply(plugin, view) then return end
                    self:showNotice(T(
                        _("Restored “%1”."), self:getDisplayTitle(view, item_id)))
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
        -- Separators intentionally share one identity (SEPARATOR_ID): there
        -- is no unique id to resolve, so this path stays POSITIONAL — kept
        -- clearly separate from the id-resolved path above. Position is
        -- re-derived at click time; in multi-separator menus the first
        -- occurrence acts.
        local function currentSepOrFail()
            local cur = self:_currentIndexOfItem(view, menu_id, MenuOrderManager.SEPARATOR_ID)
            if not cur then
                self:showStaleResultNotice(item_title)
                if on_update_callback then on_update_callback() end
            end
            return cur
        end
        if current_idx > 1 then
            table.insert(actions, {
                text = _("Move separator up"),
                callback = function()
                    local cur = currentSepOrFail()
                    if not cur or cur <= 1 then return end
                    MenuOrderManager:moveItem(view, menu_id, cur, cur - 1)
                    if not self:saveAndApply(plugin, view) then return end
                    on_update_callback()
                end,
            })
        end
        if current_idx < total_items then
            table.insert(actions, {
                text = _("Move separator down"),
                callback = function()
                    local cur, total = currentSepOrFail()
                    if not cur or cur >= total then return end
                    MenuOrderManager:moveItem(view, menu_id, cur, cur + 1)
                    if not self:saveAndApply(plugin, view) then return end
                    on_update_callback()
                end,
            })
        end
        table.insert(actions, {
            text = _("Delete separator"),
            callback = function()
                local cur = currentSepOrFail()
                if not cur then return end
                MenuOrderManager:removeSeparator(view, menu_id, cur)
                if not self:saveAndApply(plugin, view) then return end
                on_update_callback()
            end,
        })
    end

    local action_dialog
    action_dialog = Menu:new{
        title = T(_("Action for %1"), item_title),
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
                local prefix = is_tab and localizedTabPrefix() or localizedMenuPrefix()

                table.insert(choices, {
                    text = T(_("%1%2"), prefix, title),
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
                        -- Durable-first notification boundary (Bug 2): open
                        -- editor interfaces are synchronized only AFTER the
                        -- save has durably succeeded. On a TOTAL failure,
                        -- staging is restored below and no editor may
                        -- display a committed move; on a PARTIAL failure
                        -- (needs regeneration) the commit DID happen and the
                        -- branch below keeps the move standing. The move
                        -- confirmation is the only feedback needed here;
                        -- skip saveAndApply's separate "menu order saved"
                        -- toast.
                        local moved_saved, save_err, save_outcome =
                            self:saveAndApply(plugin, view, true)
                        if not moved_saved then
                            if save_outcome
                                    and save_outcome.status
                                        == CommitPipeline.STATUS.NEEDS_REGENERATION then
                                -- P0 §5: canonical intent IS durably
                                -- committed here; only a derived view /
                                -- live refresh failed. The move STANDS -
                                -- rolling it back now would desynchronize
                                -- staging from disk (an abandoned-edit
                                -- hazard) and pretend failure of a commit
                                -- that happened. Editors are synchronized
                                -- against committed state; the user is told
                                -- a restart completes the refresh.
                                self:_notifyEditorsOfMove(view, item_id,
                                    from_menu_id, target_mid)
                                if chooser_dialog then
                                    UIManager:close(chooser_dialog)
                                    chooser_dialog = nil
                                end
                                self:showNotice(T(
                                    _("Moved to %1. Restart KOReader to see every change."),
                                    title))
                                if on_moved_callback then
                                    on_moved_callback(item_id, from_menu_id, target_mid)
                                end
                                return
                            end
                            if had_pending then MenuOrderManager:restoreOrder(view) end
                            return
                        end
                        self:_notifyEditorsOfMove(view, item_id, from_menu_id, target_mid)
                        -- The move is done: leave only the confirmation on screen.
                        if chooser_dialog then
                            UIManager:close(chooser_dialog)
                            chooser_dialog = nil
                        end
                        self:showNotice(T(_("Moved to %1."), title))
                        if on_moved_callback then
                            on_moved_callback(item_id, from_menu_id, target_mid)
                        end
                    end,
                })
            end
        end
    end

    chooser_dialog = Menu:new{
        title = T(_("Move “%1” to:"), self:getDisplayTitle(view, item_id)),
        item_table = choices,
    }
    UIManager:show(chooser_dialog)
end

-- =========================================================================
-- Hidden Items Manager Screen
-- Recovery surface, reached directly from each editor hamburger menu.
-- Showing an item clears its hidden flag and keeps its current placement;
-- it does not move the item back to a default location (use "Restore
-- default placement" for that).
-- =========================================================================

function UIScreens:showHiddenItemsManager(plugin, view, on_close_callback)
    if plugin then self.plugin = plugin end
    local disabled = MenuOrderManager:getDisabledItems(view)
    local function refresh()
        self:showHiddenItemsManager(plugin, view, on_close_callback)
    end

    if #disabled == 0 then
        self:showNotice(_("No items are currently hidden in this view."))
        return
    end

    local items = {
        {
            text = _("Show all hidden items"),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Show all hidden items in this view? They stay in their current places and become visible again."),
                    ok_text = _("Show all"),
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
        local label = desc and T(_("%1 (%2)"), title, desc) or title

        table.insert(items, {
            text = label,
            help_text = _("Tap to show this item again. It stays where it is placed."),
            callback = function()
                MenuOrderManager:setItemHidden(view, item_id, false)
                if not self:saveAndApply(plugin, view) then return end
                self:showNotice(T(_("Shown “%1”."), title))
                refresh()
            end,
        })
    end

    local dialog
    dialog = Menu:new{
        title = T(N_("%1 (%2)", "%1 (%2)", #disabled), _("Hidden items"), #disabled),
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
-- Everyday navigation surface, reached directly from each editor menu.
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
    -- Unicode-aware case-insensitive matching over BOTH the query and the
    -- presented titles/ids. Canonical ids are never rewritten here: the
    -- folded forms are independent search keys, identity stays byte-exact.
    local clean_query = foldKey(query)
    clean_query = clean_query:gsub("^%s+", ""):gsub("%s+$", "")
    local all_menus = MenuOrderManager:getAllMenusAndSubmenus(view)
    local disabled = MenuOrderManager:getDisabledItems(view)

    local matches = {}
    local seen = {}
    -- Duplicate labels must still be distinct entries: matching and dedup go
    -- by stable id, never by display title.
    local function queryMatches(item_id, title)
        return foldKey(item_id):find(clean_query, 1, true)
            or foldKey(title):find(clean_query, 1, true)
    end

    for __, menu_entry in ipairs(all_menus) do
        local mid = menu_entry.id
        local items = MenuOrderManager:getMenuItems(view, mid)
        for _, item_id in ipairs(items) do
            if item_id ~= MenuOrderManager.SEPARATOR_ID and not seen[item_id] then
                local title = self:getDisplayTitle(view, item_id)
                if queryMatches(item_id, title) then
                    seen[item_id] = true
                    table.insert(matches, {
                        item_id = item_id,
                        menu_id = mid,
                        is_hidden = false,
                    })
                end
            end
        end
    end

    for __, item_id in ipairs(disabled) do
        if not seen[item_id] then
            local title = self:getDisplayTitle(view, item_id)
            if queryMatches(item_id, title) then
                seen[item_id] = true
                table.insert(matches, {
                    item_id = item_id,
                    menu_id = nil,
                    is_hidden = true,
                })
            end
        end
    end

    if #matches == 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("No menu items matching “%1” were found."), query),
        })
        return
    end

    local result_items = {}
    local found_count = #matches
    for __, match in ipairs(matches) do
        local item_id = match.item_id
        local title = self:getDisplayTitle(view, item_id)
        local location = match.is_hidden and _("Hidden") or self:getDisplayTitle(view, match.menu_id)
        local status_prefix = match.is_hidden and localizedHiddenPrefix() or ""
        local row_text = T(_("%1%2 [%3: %4]"), status_prefix, title, _("in"), location)

        table.insert(result_items, {
            text = row_text,
            callback = function()
                if match.is_hidden then
                    -- Hidden items keep their stable id; showing is
                    -- id-keyed and keeps the current placement.
                    MenuOrderManager:setItemHidden(view, item_id, false)
                    if not self:saveAndApply(plugin, view) then return end
                    self:showNotice(T(_("Shown “%1”."), title))
                    self:showSearchResults(plugin, view, query, on_close_callback)
                else
                    -- Position resolved from the stable id at action time;
                    -- see showItemActionDialog.
                    self:showItemActionDialog(plugin, view, match.menu_id, item_id, nil, function()
                        self:showSearchResults(plugin, view, query, on_close_callback)
                    end)
                end
            end,
        })
    end

    local results_dialog
    results_dialog = Menu:new{
        title = T(N_("Search “%2”: 1 match", "Search “%2”: %1 matches", found_count),
            found_count, query),
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
-- Raw Configuration Viewer (TextViewer) - diagnostics surface (Advanced)
-- =========================================================================

function UIScreens:showRawConfigViewer(_, view)
    local order = MenuOrderManager:loadOrder(view)
    local view_label = (view == "reader") and _("Book view") or _("File Manager")
    local serialized = "-- Resolved KOReader menu override for " .. (view == "reader" and "Book view" or "File Manager") .. "\nreturn " .. dump(order, nil, true)
    local viewer = TextViewer:new{
        title = T(_("%1 (%2)"), _("Resolved KOReader menu override"), view_label),
        text = serialized,
        alignment = "left",
        auto_para_direction = false,
    }
    UIManager:show(viewer)
end

-- =========================================================================
-- Preset Management UI
-- -------------------------------------------------------------------------
-- P1B #7: applying a preset is `result = applyPreset(...)` -> present ->
-- refresh the editor model if needed. The UI performs NO reconciliation,
-- NO second save, NO extra native write, NO extra reload. Per Agent B's
-- landed backend, the full-view loadPreset
-- funnel already commits + materializes, so the historical
-- reconcileRegisteredItems(plugin, view, true) call after it is REMOVED
-- (it duplicated committed work). Submenu presets remain
-- staging-into-the-open-transaction BY CONTRACT: the editor's own Save
-- owns the single commit, so that flow deliberately does not save here.
-- =========================================================================

-- Apply a FULL-VIEW preset and present the outcome identically for every
-- caller. Returns true when the preset was applied.
function UIScreens:applyPresetAndPresent(plugin, view, preset)
    local ok, err = MenuOrderManager:loadPreset(view, preset)
    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to load preset:\n%1"), tostring(err)),
        })
        return false
    end
    self.needs_restart = true
    self:reloadLiveMenu(plugin, view)
    UIManager:show(Notification:new{
        text = T(_("Loaded preset “%1”."), preset.name),
    })
    return true
end

-- Long-press update: overwrite a CUSTOM preset with the current layout
-- (shared by every preset list; built-ins are immutable snapshots, say so
-- instead of offering a broken action).
function UIScreens:confirmUpdatePreset(view, preset)
    if preset.is_builtin then
        UIManager:show(InfoMessage:new{
            text = _("Built-in presets cannot be updated."),
        })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Update preset “%1” with the current layout?"), preset.name),
        ok_text = _("Update"),
        ok_callback = function()
            local ok, err = MenuOrderManager:updatePreset(view, preset)
            if ok then
                self:showNotice(T(_("Updated preset “%1”."), preset.name))
            else
                self:showError(T(_("Failed to update preset:\n%1"), tostring(err)))
            end
        end,
    })
end

local function submenuPresetPrefix(preset)
    return preset.include_submenus and localizedNestedPrefix() or localizedDirectPrefix()
end

function UIScreens:showSaveSubmenuPresetDialog(plugin, view, menu_id, menu_title, include_submenus, on_close_callback, current_menu_items)
    if plugin then self.plugin = plugin end
    local input_dialog
    input_dialog = InputDialog:new{
        title = include_submenus
            and T(_("Save %1 and nested menus"), menu_title)
            or T(_("Save %1 menu order"), menu_title),
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
                                    text = T(_("Saved preset “%1” for %2."), name, menu_title),
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = T(_("Error saving submenu preset:\n%1"), tostring(result)),
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
                    text = T(_("Delete preset “%1” for %2?"), current_preset.name, menu_title),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        local ok, err = MenuOrderManager:deleteSubmenuPreset(view, menu_id, current_preset)
                        if ok then
                            UIManager:show(Notification:new{
                                text = T(_("Deleted preset “%1”."), current_preset.name),
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
        title = T(_("Delete presets for %1"), menu_title),
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
                    text = T(_("Apply preset “%1” to %2?"), current_preset.name, menu_title),
                    ok_text = _("Apply"),
                    ok_callback = function()
                        -- Stages into the OPEN editor transaction (Agent B
                        -- contract); the editor's Save owns the commit, so
                        -- unlike full-view presets there is no save/reload
                        -- here by design.
                        local ok, err = MenuOrderManager:loadSubmenuPreset(view, menu_id, current_preset, current_menu_items)
                        if ok then
                            preset_applied = true
                            UIManager:show(Notification:new{
                                text = T(_("Loaded preset “%1” for %2."), current_preset.name, menu_title),
                            })
                            UIManager:close(menu_dialog)
                        else
                            UIManager:show(InfoMessage:new{
                                text = T(_("Failed to load submenu preset:\n%1"), tostring(err)),
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
            help_text = T(_("Delete a saved preset for %1."), menu_title),
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
        title = T(_("Presets for %1"), menu_title),
        item_table = items,
        on_close = function()
            if on_close_callback then on_close_callback(preset_applied) end
        end,
    }
    UIManager:show(menu_dialog)
end

function UIScreens:showPresetsMenu(plugin, view, on_close_callback, draft_tab_order_stager)
    if plugin then self.plugin = plugin end
    local view_label = (view == "reader") and _("Book view") or _("File Manager")
    local presets = MenuOrderManager:getAllPresets(view)
    local preset_applied = false

    local items = {}
    local menu_dialog

    -- Save action at top (normal menu entry) - close current before opening save dialog to avoid stacking
    -- Bug 6: when the presets menu was opened from inside the tab reorder
    -- dialog, `draft_tab_order_stager` carries that dialog's visible model;
    -- it stages the unsaved drag/hide draft so the captured preset equals
    -- what the user sees. It is nil for callers outside the tab dialog.
    table.insert(items, {
        text = _("Save current as preset…"),
        help_text = _("Save the current menu layout with a custom name."),
        callback = function()
            UIManager:close(menu_dialog)
            self:showSavePresetDialog(plugin, view, function()
                self:showPresetsMenu(plugin, view, on_close_callback)
            end, draft_tab_order_stager)
        end,
        separator = true,
    })

    -- Direct list of all presets in the same normal Menu (no additional interface)
    for __, preset in ipairs(presets) do
        local prefix = preset.is_builtin and localizedBuiltinPrefix() or localizedCustomPrefix()
        -- capture preset for closure
        local cur_preset = preset
        table.insert(items, {
            text = prefix .. cur_preset.name,
            help_text = cur_preset.description,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Apply preset “%1”?"), cur_preset.name),
                    ok_text = _("Apply"),
                    ok_callback = function()
                        if self:applyPresetAndPresent(plugin, view, cur_preset) then
                            preset_applied = true
                            UIManager:close(menu_dialog)
                        end
                    end,
                })
            end,
            hold_callback = function()
                self:confirmUpdatePreset(view, cur_preset)
            end,
        })
    end

    -- Hide/delete action at bottom if any hideable/deletable presets exist,
    -- or if any built-ins are currently hidden (their restore lives there).
    local deletable = MenuOrderManager:listDeletablePresets(view)
    local hidden_builtin_count = 0
    if Presets.getHiddenBuiltinIds then
        hidden_builtin_count = #Presets.getHiddenBuiltinIds(view)
    end
    if #deletable > 0 or hidden_builtin_count > 0 then
        table.insert(items, {
            text = _("Hide / delete presets…"),
            help_text = _("Remove custom presets, hide built-in presets (restorable), or restore hidden built-ins."),
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
        title = T(_("%1 - %2"), _("Presets"), view_label),
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

-- P1B #17: built-in presets are HIDDEN, never destroyed (Agent B backend:
-- deletePreset on a builtin flips a visibility bit). Wording and the extra
-- restore row follow that reality.
function UIScreens:showDeletePresetMenu(plugin, view, on_close_callback)
    if plugin then self.plugin = plugin end
    local deletable = MenuOrderManager:listDeletablePresets(view)
    local hidden_builtin_count = 0
    if Presets.getHiddenBuiltinIds then
        hidden_builtin_count = #Presets.getHiddenBuiltinIds(view)
    end

    if #deletable == 0 and hidden_builtin_count == 0 then
        UIManager:show(InfoMessage:new{ text = _("No presets to delete (default cannot be deleted).") })
        if on_close_callback then on_close_callback() end
        return
    end

    local items = {}
    local dialog
    -- Single navigation choreography for every row: drop this screen's
    -- on_close, close, then let the caller refresh its parent once.
    local function navigate_back()
        if dialog then
            dialog.on_close = nil
            UIManager:close(dialog)
        end
        if on_close_callback then on_close_callback() end
    end

    for __, preset in ipairs(deletable) do
        local cur_preset = preset
        local is_builtin = cur_preset.is_builtin
        local label = (is_builtin and localizedBuiltinPrefix() or localizedCustomPrefix()) .. cur_preset.name
        local help = is_builtin
            and _("Hide built-in preset (you can restore it from this screen later).")
            or _("Delete custom preset file.")
        if cur_preset.id == "builtin_default" then
            help = _("Default cannot be deleted.")
        end
        table.insert(items, {
            text = label,
            help_text = help,
            callback = function()
                local confirm_text
                local ok_text
                if is_builtin then
                    confirm_text = T(_("Hide built-in preset “%1”?"), cur_preset.name)
                    ok_text = _("Hide")
                else
                    confirm_text = T(_("Delete custom preset “%1”?"), cur_preset.name)
                    ok_text = _("Delete")
                end
                UIManager:show(ConfirmBox:new{
                    text = confirm_text,
                    ok_text = ok_text,
                    ok_callback = function()
                        -- Backend API is deletePreset for both kinds (Agent B:
                        -- built-in deletion is implemented as hiding).
                        local ok, err = MenuOrderManager:deletePreset(view, cur_preset.id)
                        if not ok then
                            -- Fallback try name
                            ok, err = MenuOrderManager:deletePreset(view, cur_preset.name)
                        end
                        if ok then
                            self:showNotice(is_builtin
                                and T(_("Hidden built-in preset “%1”."), cur_preset.name)
                                or T(_("Deleted preset “%1”."), cur_preset.name))
                            navigate_back()
                        else
                            self:showError(tostring(err or _("Failed to delete.")))
                        end
                    end,
                })
            end,
        })
    end

    if hidden_builtin_count > 0 and Presets.restoreBuiltinPresets then
        table.insert(items, {
            text = T(N_("Restore hidden built-in preset",
                        "Restore %1 hidden built-in presets", hidden_builtin_count),
                      hidden_builtin_count),
            help_text = _("Built-in presets are never destroyed; hiding only removes them from the list until restored."),
            separator = true,
            callback = function()
                Presets.restoreBuiltinPresets(view)
                self:showNotice(_("Hidden built-in presets restored."))
                navigate_back()
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

function UIScreens:showSavePresetDialog(plugin, view, on_close_callback, capture_draft_tab_order)
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
                            -- Bug 6: the preset must capture what the user is
                            -- LOOKING at. When invoked from the tab reorder
                            -- dialog, the visible draft (unsaved drag + hide
                            -- toggles) is staged FIRST so the snapshot
                            -- includes it; the ordinary save path then
                            -- persists exactly the same arrangement.
                            if capture_draft_tab_order then
                                capture_draft_tab_order()
                            end
                            local ok, res = MenuOrderManager:savePreset(view, name)
                            if ok then
                                UIManager:show(Notification:new{
                                    text = T(_("Saved preset “%1”."), name),
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = T(_("Error saving preset:\n%1"), tostring(res)),
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

-- =========================================================================
-- Advanced menu
--
-- Mirroring, diagnostics, and removal preparation live here, off the
-- primary editor surfaces. Search and hidden-item recovery live directly
-- in each editor hamburger menu instead.
-- =========================================================================

function UIScreens:showAdvancedMenu(plugin, view)
    if plugin then self.plugin = plugin end
    view = view or self:getCurrentView(plugin)
    local items = {}
    local dialog
    local function closeMenu()
        if dialog then UIManager:close(dialog) end
    end

    table.insert(items, {
        text = _("Mirror changes (Book & File Manager)"),
        help_text = _("Mirror hiding/showing and moves between menus to the other view when the item and destination exist there. Reordering, separators, tab order, restores and resets stay per-view."),
        checked_func = function() return MenuOrderManager:isMirroringEnabled() end,
        callback = function()
            closeMenu()
            self:toggleMirroring()
        end,
    })
    table.insert(items, {
        text = _("Keep hidden entries in their position"),
        help_text = _("Editors show hidden entries dimmed where they were; otherwise at the bottom. Takes effect when an editor is (re)opened."),
        checked_func = function() return MenuOrderManager:isHiddenInPlace() end,
        callback = function()
            closeMenu()
            self:toggleHiddenInPlace()
        end,
    })
    table.insert(items, {
        text = _("View resolved menu override"),
        help_text = _("Diagnostics: inspect the resolved menu override file written for KOReader."),
        separator = true,
        callback = function()
            closeMenu()
            self:showRawConfigViewer(plugin, view)
        end,
    })
    table.insert(items, {
        text = _("Prepare for plugin removal…"),
        separator = true,
        help_text = _("Show every hidden item before disabling or uninstalling this plugin."),
        callback = function()
            closeMenu()
            self:confirmPrepareForRemoval(plugin)
        end,
    })

    dialog = Menu:new{
        title = _("Advanced"),
        item_table = items,
    }
    UIManager:show(dialog)
end

return UIScreens

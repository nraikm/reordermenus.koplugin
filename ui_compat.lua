--[[--
Small, isolated compatibility hooks for KOReader UI internals.

Keeping private-upvalue access here makes the normal screen code depend only
on public widget behavior. If KOReader changes SortWidget internals, this
optional enhancement can fail closed without affecting the editors.

WHY THIS PATCH EXISTS (P1B #12)
===============================
ReorderingMenus drills from a tab editor into submenu editors. Stock
SortItemWidget:onTap() has two states only: tap a row -> mark it (selection),
tap the MARKED row -> start a drag. There is no public per-row activation
hook, so "second tap opens this submenu" cannot be expressed without either
hijacking the drag gesture or replacing the widget. This patch adds exactly
one behavior: tapping the already-marked row of a submenu entry invokes the
row's own `onSubmenuTap` instead of arming a drag. Nothing else changes.

UPSTREAM API NEEDED TO REMOVE IT
================================
Any of these would let this file shrink to zero:
  - a public `SortItemWidget:onRowActivated(item)` (or item_table field
    like `on_activate`) invoked on tapping an already-marked row, or
  - a public `SortWidget.allow_row_activation` option, or
  - exposure of the SortItemWidget class as a requireable module so the
    subclass would not need debug.getupvalue to reach it.

LIFECYCLE (P1B #13)
===================
The patch is installed ONLY while a ReorderingMenus editor is open and
refcounted, because nested editors drill down without closing parents.
installSortWidgetSubmenuTap() increments the count (first call saves the
original onTap and swaps in ours); releaseSortWidgetSubmenuTap() decrements
it and restores the original when the last editor closes. Plugin startup
installs nothing, so stock KOReader sorting UIs are untouched unless our
editor is actually on screen.
--]]

local UICompat = {}

-- Saved original, kept so release can restore byte-exact behavior.
local saved_onTap  -- nil until first install
local refcount = 0

local function patchedOnTap(self, _, ges)
    local parent = self.show_parent
    local checkmark_tapped = self.item.checked_func
        and (parent.sort_disabled
            or ges.pos:intersectWith(self.checkmark_widget.dimen))
    if checkmark_tapped then
        if self.item.callback then self.item:callback() end
    elseif parent.sort_disabled then
        if self.item.callback then
            self.item:callback()
        else
            return true
        end
    elseif parent.marked == self.index then
        -- The enhancement: second tap on a marked submenu row drills down
        -- instead of arming a drag.
        if self.item.is_submenu and self.item.onSubmenuTap then
            self.item.onSubmenuTap()
            parent:_populateItems()
            return true
        end
        parent.marked = 0
    else
        parent.marked = self.index
    end
    parent:_populateItems()
    return true
end

--- Install (or just count another user of) the submenu-tap enhancement.
--- Returns true when the SortItemWidget class is patched and serving.
function UICompat.installSortWidgetSubmenuTap(SortWidget)
    local ok, installed = pcall(function()
        if saved_onTap ~= nil then
            -- Already patched at class level; just count this editor.
            refcount = refcount + 1
            return true
        end
        local info = debug.getinfo(SortWidget._populateItems, "u")
        for i = 1, info.nups do
            local name, SortItemWidget = debug.getupvalue(
                SortWidget._populateItems, i)
            if name == "SortItemWidget" and SortItemWidget
                    and SortItemWidget.onTap then
                if SortItemWidget.reordering_menus_submenu_tap then
                    -- Patched by a previous session of this module instance;
                    -- adopt it without double-wrapping.
                    saved_onTap = SortItemWidget.onTap
                    refcount = refcount + 1
                    return true
                end
                saved_onTap = SortItemWidget.onTap
                SortItemWidget.onTap = patchedOnTap
                SortItemWidget.reordering_menus_submenu_tap = true
                refcount = refcount + 1
                return true
            end
        end
        return false
    end)
    return ok and installed == true
end

--- Release one editor's claim. When the last claim is gone the ORIGINAL
--- onTap is restored, and only if it is still ours to restore (a future
--- KOReader upgrade swapping the function mid-session will not be clobbered).
function UICompat.releaseSortWidgetSubmenuTap(SortWidget)
    if refcount == 0 or saved_onTap == nil then return end
    refcount = refcount - 1
    if refcount > 0 then return end
    pcall(function()
        local info = debug.getinfo(SortWidget._populateItems, "u")
        for i = 1, info.nups do
            local name, SortItemWidget = debug.getupvalue(
                SortWidget._populateItems, i)
            if name == "SortItemWidget" and SortItemWidget
                    and SortItemWidget.reordering_menus_submenu_tap
                    and SortItemWidget.onTap == patchedOnTap then
                SortItemWidget.onTap = saved_onTap
                SortItemWidget.reordering_menus_submenu_tap = nil
                break
            end
        end
    end)
    saved_onTap = nil
end

return UICompat

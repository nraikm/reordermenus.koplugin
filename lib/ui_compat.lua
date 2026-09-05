--[[--
Small, isolated compatibility hooks for KOReader UI internals.

Keeping private-upvalue access here makes the normal screen code depend only
on public widget behavior. If KOReader changes SortWidget internals, this
optional enhancement can fail closed without affecting the editors.

WHY THIS PATCH EXISTS
======================
ReorderingMenus drills from a tab editor into submenu editors. Stock
SortItemWidget:onTap() has two states only: tap a row -> mark it (selection),
tap the MARKED row -> start a drag. There is no public per-row activation
hook, so opening a submenu cannot be expressed without either hijacking the
drag gesture or replacing the widget. This patch adds:
  - an edge-aligned navigation arrow on every submenu row (a separate widget
    at the row's trailing edge, following the BD.mirroredUILayout()
    convention KOReader uses for its own menu arrows);
  - first-tap navigation when the tap hits the arrow's actual bounds
    (expanded slightly for touch), leaving selection/dragging to taps
    elsewhere on the row;
  - second-tap fallback: tapping the already-marked row of a submenu entry
    also drills down instead of arming a drag.
Nothing else changes.

UPSTREAM API NEEDED TO REMOVE IT
================================
Any of these would let this file shrink to zero:
  - a public `SortItemWidget:onRowActivated(item)` (or item_table field
    like `on_activate`) invoked on tapping an already-marked row, or
  - a public `SortWidget.allow_row_activation` option, or
  - exposure of the SortItemWidget class as a requireable module so the
    subclass would not need debug.getupvalue to reach it.

LIFECYCLE
=========
The patch is installed ONLY while a ReorderingMenus editor is open and
refcounted, because nested editors drill down without closing parents.
installSortWidgetSubmenuTap() increments the count (first call saves the
originals and swaps in ours); releaseSortWidgetSubmenuTap() decrements
it and restores the originals when the last editor closes. Plugin startup
installs nothing, so stock KOReader sorting UIs are untouched unless our
editor is actually on screen.
--]]

local UICompat = {}

-- Saved originals, kept so release can restore byte-exact behavior.
local saved_init  -- SortItemWidget:init
local saved_onTap  -- SortItemWidget:onTap
local refcount = 0

-- Touch slop around the arrow glyph, in unscaled px each side. The hit box
-- stays anchored to the rendered arrow (it does not stretch to the screen
-- edge or cover the row body).
local ARROW_TOUCH_SLOP = 12

-- Arrow widget with screen-geometry tracking. Stock TextWidget:paintTo does
-- not record where it painted (unlike CheckMark, whose comment calls its
-- dimen out as hitbox state), so taps could never use its bounds. This
-- subclass records its painted origin and measured size, making the visible
-- arrow and the navigation target the same rectangle by construction.
local NavArrowWidget = nil
local function getNavArrowClass()
    if NavArrowWidget then return NavArrowWidget end
    local ok, TextWidget = pcall(require, "ui/widget/textwidget")
    if not ok or not TextWidget then return nil end
    NavArrowWidget = TextWidget:extend{}
    function NavArrowWidget:paintTo(bb, x, y)
        TextWidget.paintTo(self, bb, x, y)
        local size_ok, size = pcall(function() return self:getSize() end)
        self.dimen = self.dimen or {}
        self.dimen.x = x
        self.dimen.y = y
        if size_ok and type(size) == "table" then
            self.dimen.w = size.w
            self.dimen.h = size.h
        end
    end
    return NavArrowWidget
end

-- Patched row init: runs the stock layout first, then overlays an
-- edge-aligned arrow for submenu rows. Fails closed (plain stock row, no
-- arrow) if any step throws, so a future KOReader layout change cannot
-- break the editors.
local function patchedInit(self)
    saved_init(self)
    if not self.item or not self.item.is_submenu then return end
    pcall(function()
        local Geom = require("ui/geometry")
        local Size = require("ui/size")
        local BD = require("ui/bidi")
        local Blitbuffer = require("ffi/blitbuffer")
        local RightContainer = require("ui/widget/container/rightcontainer")
        local OverlapGroup = require("ui/widget/overlapgroup")
        local ArrowClass = getNavArrowClass()
        assert(ArrowClass ~= nil, "arrow widget class unavailable")

        local arrow_text = BD.mirroredUILayout() and "←" or "→"
        local arrow_widget = ArrowClass:new{
            text = arrow_text,
            face = self.face,
            fgcolor = self.item.dim and Blitbuffer.COLOR_DARK_GRAY or nil,
        }
        self.nav_arrow_widget = arrow_widget

        -- Reserve horizontal space so long titles truncate before running
        -- under the overlaid arrow. The title TextWidget lives at
        -- FrameContainer -> LeftContainer -> HorizontalGroup -> VerticalGroup.
        pcall(function()
            local frame = self[1]
            local left = frame and frame[1]
            local hgroup = left and left[1]
            local vgroup = hgroup and hgroup[2]
            local title_widget = vgroup and vgroup[1]
            if title_widget and type(title_widget.max_width) == "number" then
                local arrow_w = arrow_widget:getSize().w
                local reserve = arrow_w + 2 * Size.padding.default
                local new_max = title_widget.max_width - reserve
                if new_max > 50 then
                    title_widget:setMaxWidth(new_max)
                end
            end
        end)

        local frame = self[1]
        local left = frame and frame[1]
        assert(left ~= nil, "row layout root missing")
        local arrow_container = RightContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            arrow_widget,
        }
        self.nav_arrow_container = arrow_container
        local overlay = OverlapGroup:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            left,
            arrow_container,
        }
        for i, child in ipairs(frame) do
            if child == left then
                frame[i] = overlay
                break
            end
        end
    end)
end

-- True only when the tap hits the rendered arrow's actual bounds (with a
-- small touch slop). Falls closed to false whenever geometry is missing,
-- leaving the legacy second-tap path as the fallback.
local function isArrowTap(self, ges)
    if not self.item.is_submenu or not self.item.onSubmenuTap then return false end
    local arrow = self.nav_arrow_widget
    if type(arrow) ~= "table" or type(arrow.dimen) ~= "table" then return false end
    if type(ges) ~= "table" or type(ges.pos) ~= "table" then return false end
    if type(ges.pos.intersectWith) ~= "function" then return false end
    local d = arrow.dimen
    if type(d.x) ~= "number" or type(d.y) ~= "number"
            or type(d.w) ~= "number" or type(d.h) ~= "number" then
        return false
    end
    if d.w <= 0 or d.h <= 0 then return false end
    local ok, hit = pcall(function()
        local Geom = require("ui/geometry")
        local box = Geom:new{
            x = d.x - ARROW_TOUCH_SLOP,
            y = d.y - ARROW_TOUCH_SLOP,
            w = d.w + 2 * ARROW_TOUCH_SLOP,
            h = d.h + 2 * ARROW_TOUCH_SLOP,
        }
        return ges.pos:intersectWith(box)
    end)
    return ok and hit == true
end

local function patchedOnTap(self, _, ges)
    local parent = self.show_parent
    local ok, checkmark_tapped = pcall(function()
        return self.item.checked_func
            and (parent.sort_disabled
                or ges.pos:intersectWith(self.checkmark_widget.dimen))
    end)
    if not ok then checkmark_tapped = false end
    if checkmark_tapped then
        if self.item.callback then self.item:callback() end
    elseif parent.sort_disabled then
        if self.item.callback then
            self.item:callback()
        else
            return true
        end
    elseif isArrowTap(self, ges) then
        -- Dedicated navigation affordance: the edge arrow opens the
        -- submenu on the first tap, leaving selection/dragging to taps
        -- elsewhere on the row.
        self.item.onSubmenuTap()
        parent:_populateItems()
        return true
    elseif parent.marked == self.index then
        -- Legacy fallback: second tap on a marked submenu row also drills
        -- down instead of arming a drag.
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
                    and SortItemWidget.onTap and SortItemWidget.init then
                if SortItemWidget.reordering_menus_submenu_tap then
                    -- Patched by a previous session of this module instance;
                    -- adopt it without double-wrapping.
                    saved_init = saved_init or SortItemWidget.init
                    saved_onTap = SortItemWidget.onTap
                    refcount = refcount + 1
                    return true
                end
                saved_init = SortItemWidget.init
                saved_onTap = SortItemWidget.onTap
                SortItemWidget.init = patchedInit
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

--- Release one editor's claim. When the last claim is gone the ORIGINALS
--- are restored, and only if they are still ours to restore (a future
--- KOReader upgrade swapping the functions mid-session will not be clobbered).
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
                    and SortItemWidget.reordering_menus_submenu_tap then
                if SortItemWidget.onTap == patchedOnTap then
                    SortItemWidget.onTap = saved_onTap
                end
                if saved_init and SortItemWidget.init == patchedInit then
                    SortItemWidget.init = saved_init
                end
                SortItemWidget.reordering_menus_submenu_tap = nil
                break
            end
        end
    end)
    saved_init = nil
    saved_onTap = nil
end

return UICompat

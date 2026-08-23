--[[--
Small, isolated compatibility hooks for KOReader UI internals.

Keeping private-upvalue access here makes the normal screen code depend only
on public widget behavior. If KOReader changes SortWidget internals, this
optional enhancement can fail closed without affecting the editors.
--]]

local UICompat = {}

function UICompat.installSortWidgetSubmenuTap(SortWidget)
    local ok, installed = pcall(function()
        local info = debug.getinfo(SortWidget._populateItems, "u")
        for i = 1, info.nups do
            local name, SortItemWidget = debug.getupvalue(
                SortWidget._populateItems, i)
            if name == "SortItemWidget" and SortItemWidget
                    and SortItemWidget.onTap then
                if SortItemWidget.reordering_menus_submenu_tap then
                    return true
                end
                SortItemWidget.onTap = function(self, _, ges)
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
                SortItemWidget.reordering_menus_submenu_tap = true
                return true
            end
        end
        return false
    end)
    return ok and installed == true
end

return UICompat

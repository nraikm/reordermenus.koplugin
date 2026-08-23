-- Shared names and constructors for the KOReader menu-order data model.
--
-- This module intentionally contains only plain constants and fresh-table
-- constructors. It is safe for pure domain modules to require: it performs no
-- I/O and has no dependency on KOReader runtime objects.

local MenuSchema = {}

MenuSchema.SEPARATOR_ID = "----------------------------"
MenuSchema.MENU_BUTTONS_KEY = "KOMenu:menu_buttons"
MenuSchema.DISABLED_KEY = "KOMenu:disabled"
MenuSchema.CUSTOM_SUBMENUS_KEY = "KOMenu:custom_submenus"

MenuSchema.VIEWS = { "reader", "filemanager" }

-- Ordered so persistence validation, normalization, and merge code all walk
-- the same schema without maintaining parallel field lists.
MenuSchema.VIEW_COLLECTIONS = {
    "hidden",
    "hidden_order",
    "parent_override",
    "position_override",
    "order_override",
    "sequence_eras",
    "custom_menus",
    "separators",
    "raw_override",
}

MenuSchema.VIEW_COLLECTION_SET = {}
for _, name in ipairs(MenuSchema.VIEW_COLLECTIONS) do
    MenuSchema.VIEW_COLLECTION_SET[name] = true
end

MenuSchema.RESERVED_KEYS = {
    [MenuSchema.MENU_BUTTONS_KEY] = true,
    [MenuSchema.DISABLED_KEY] = true,
    [MenuSchema.CUSTOM_SUBMENUS_KEY] = true,
}

function MenuSchema.newViewSection()
    return {
        hidden = {},
        hidden_order = {},
        parent_override = {},
        position_override = {},
        order_override = {},
        sequence_eras = {},
        custom_menus = {},
        separators = {},
        raw_override = {},
        tab_order = nil,
    }
end

return MenuSchema

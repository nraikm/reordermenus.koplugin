--[[--
placement.lua — centralized placement/capability rules (single authority).

Editor operations (canMoveItemToMenu / moveItemToMenu / destination chooser),
preset ingestion (applyUserIntentPreset / importAgainstDefaults /
importExternalChanges / loadSubmenuPreset), and runtime resolution
(Materializer.effectiveParent + Validator repair) previously disagreed:
the editor never offered moving a top-level tab into an ordinary submenu,
but presets applied such parent_overrides verbatim, producing a duplicate
(tab in bar + nested placeholder with nil text and no sub_item_table) that
crashed when the host submenu was opened.

Top-level tabs are NOT ordinary submenu containers. They carry tab-bar
capabilities (position in KOMenu:menu_buttons, icon, tab-bar rendering) that
a nested submenu row cannot render. Only their order (tab_order) and
visibility (hidden) are customizable; their parent is always
KOMenu:menu_buttons. Ordinary submenus, leaves, and user-created custom
submenus may be relocated among menus with cycle prevention.

This module is the SINGLE authority for "may id live under parent?".
Every entry point funnels through canPlace/sanitizeParentOverride:

  canPlace(reg, intent, id, parent)
    -> true  (supported placement)
    -> false, reason  (unsupported; reason in REASONS)

  Reasons:
    self            id == parent
    unknown_parent  parent is not a known container and not the tab bar
    tab_nesting     a top-level tab under an ordinary submenu (unsupported)
    non_tab_in_bar  a non-tab id directly under the tab bar
    malformed       record has no string parent

  sanitizeParentOverride(reg, intent, id, record)
    -> true  (record absent or supported; keep)
    -> false, reason (unsupported; caller must drop/migrate, preserving the
       source bytes on disk — presets keep their file, intent drops the row).

Cycle prevention stays with the caller that owns a projection
(MenuOrderManager:isMenuDescendant / Validator.breakCycles) because it needs
the resolved graph, not just (reg, intent). canPlace deliberately does NOT
claim cycle safety; callers combine both.

Safe migration policy (deterministic, recoverable):
  - Unsupported tab_nesting / non_tab_in_bar / unknown_parent overrides are
    IGNORED at resolve time (Materializer falls back to defaults) and DROPPED
    at ingest time (preset apply / import). The tab stays in the bar with its
    children/callbacks intact; the preset file itself is never rewritten, so
    user data remains recoverable for inspection.
  - Stale/invalid leaf parents fall back to the provider default / hint home,
    never to unplaced-disabled without a truthful status (see visibility).
--]]

local MenuSchema = require("lib.menu_schema")

local Placement = {}

Placement.REASONS = {
    SELF = "self",
    UNKNOWN_PARENT = "unknown_parent",
    TAB_NESTING = "tab_nesting",
    NON_TAB_IN_BAR = "non_tab_in_bar",
    MALFORMED = "malformed",
}

local MENU_BUTTONS_KEY = MenuSchema.MENU_BUTTONS_KEY

--- True when id is a top-level tab in the CURRENT registry.
function Placement.isTab(reg, id)
    if type(id) ~= "string" then return false end
    if type(reg) ~= "table" then return false end
    local tabs = reg.tab_list
    if type(tabs) == "table" then
        for _, t in ipairs(tabs) do
            if t == id then return true end
        end
    end
    -- Fallback for registries that only mark menus: a tab is a menu flagged
    -- is_tab. Keeps unit fixtures without tab_list honest.
    if reg.menus and reg.menus[id] and reg.menus[id].is_tab == true then
        return true
    end
    return false
end

--- True when id can act as a CONTAINER (holds children) in this world.
function Placement.isContainer(reg, intent, id)
    if type(id) ~= "string" then return false end
    if type(reg) == "table" and reg.menus and reg.menus[id] ~= nil then
        return true
    end
    if type(intent) == "table" and type(intent.custom_menus) == "table"
            and intent.custom_menus[id] ~= nil then
        return true
    end
    return false
end

--- True when parent is a valid placement target at all.
--- Unknown worlds (synthetic unit regs without menus/tab_list) cannot judge:
--- any string parent is assumed valid there so sanitization never drops
--- records it cannot prove invalid.
function Placement.isValidParent(reg, intent, parent)
    if parent == MENU_BUTTONS_KEY then return true end
    if Placement.isContainer(reg, intent, parent) then return true end
    if type(reg) ~= "table" then return true end
    local has_menus = type(reg.menus) == "table" and next(reg.menus) ~= nil
    local has_tabs = type(reg.tab_list) == "table" and #reg.tab_list > 0
    if not has_menus and not has_tabs then
        return true
    end
    return false
end

--- Central placement predicate. See module header for policy.
--- Returns true, or false + reason string.
function Placement.canPlace(reg, intent, id, parent)
    if type(id) ~= "string" or type(parent) ~= "string" then
        return false, Placement.REASONS.MALFORMED
    end
    if id == parent then
        return false, Placement.REASONS.SELF
    end
    if parent == MENU_BUTTONS_KEY then
        if Placement.isTab(reg, id) then
            return true
        end
        -- Custom submenus are never tabs; ordinary leaves/submenus never live
        -- directly in the bar. Their bar membership is via tab_order only for
        -- tabs.
        return false, Placement.REASONS.NON_TAB_IN_BAR
    end
    if not Placement.isValidParent(reg, intent, parent) then
        return false, Placement.REASONS.UNKNOWN_PARENT
    end
    if Placement.isTab(reg, id) then
        return false, Placement.REASONS.TAB_NESTING
    end
    return true
end

--- Validate one parent_override record. Absent record (nil) is valid
--- (follow defaults). Returns true, or false + reason.
function Placement.sanitizeParentOverride(reg, intent, id, record)
    if record == nil then return true end
    if type(record) ~= "table" or type(record.parent) ~= "string" then
        return false, Placement.REASONS.MALFORMED
    end
    return Placement.canPlace(reg, intent, id, record.parent)
end

local function util_copy(list)
    local out = {}
    for _, v in ipairs(list or {}) do out[#out + 1] = v end
    return out
end

--- Filter a tab bar list to only live tabs (deterministic order preserved).
--- Used for tab_order sanitization: legacy presets may list submenu ids in
--- the bar; those rows can never render as tabs. Unknown worlds (no tab
--- info) pass through untouched so synthetic unit regs never lose data.
function Placement.filterTabBar(reg, tab_list)
    if type(reg) ~= "table" then return util_copy(tab_list) end
    local has_menus = type(reg.menus) == "table" and next(reg.menus) ~= nil
    local has_tabs = type(reg.tab_list) == "table" and #reg.tab_list > 0
    local has_tab_marks = false
    if type(reg.menus) == "table" then
        for _, info in pairs(reg.menus) do
            if type(info) == "table" and info.is_tab == true then
                has_tab_marks = true break
            end
        end
    end
    if not has_menus and not has_tabs and not has_tab_marks then
        local out = {}
        for _, id in ipairs(tab_list or {}) do out[#out + 1] = id end
        return out
    end
    local out = {}
    local seen = {}
    for _, id in ipairs(tab_list or {}) do
        if type(id) == "string" and not seen[id] and Placement.isTab(reg, id) then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    return out
end

--- First valid ordinary container for parking orphaned customs.
--- Deterministic: alphabetically first menu that is not the id itself.
function Placement.firstValidContainer(reg, intent, exclude_id)
    if type(reg) ~= "table" or type(reg.menus) ~= "table" then return nil end
    local ids = {}
    for menu_id in pairs(reg.menus) do
        if menu_id ~= exclude_id and menu_id ~= MenuSchema.MENU_BUTTONS_KEY
                and menu_id ~= MenuSchema.DISABLED_KEY
                and menu_id ~= MenuSchema.CUSTOM_SUBMENUS_KEY then
            ids[#ids + 1] = menu_id
        end
    end
    table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
    for _, menu_id in ipairs(ids) do
        -- Customs may live under any ordinary container; tabs never park here.
        if not Placement.isTab(reg, menu_id) or true then
            return menu_id
        end
    end
    return nil
end

--- Deterministic safe migration for one view's intent section.
--- Drops parent_overrides that violate canPlace (tab_nesting,
--- non_tab_in_bar, unknown_parent, self, malformed) and strips tab ids from
--- ordinary order_override sequences; filters tab_order to live tabs.
--- User-created customs with no valid home are parked under the first valid
--- container instead of being left unplaced-disabled, so custom submenus and
--- their recoverable contents survive migration.
--- Preset source bytes on disk are never rewritten — only the staged intent
--- is migrated, so user data stays recoverable for inspection.
--- Returns { dropped_parents = {...}, stripped_sequences = {...}, tab_order_filtered = bool }.
function Placement.sanitizeSection(reg, section)
    local report = { dropped_parents = {}, stripped_sequences = {}, tab_order_filtered = false }
    if type(section) ~= "table" or type(reg) ~= "table" then return report end
    -- Parent overrides: sorted for determinism.
    local parent_ids = {}
    for id in pairs(section.parent_override or {}) do parent_ids[#parent_ids + 1] = id end
    table.sort(parent_ids, function(a, b) return tostring(a) < tostring(b) end)
    for _, id in ipairs(parent_ids) do
        local record = section.parent_override[id]
        local ok_place, reason = Placement.sanitizeParentOverride(reg, section, id, record)
        if not ok_place then
            -- Vanished containers stay dormant (upstream-removal dormancy):
            -- only structural violations (tab_nesting / non_tab_in_bar /
            -- self / malformed) are migrated here. Unknown parents are left
            -- for resolve-time dormancy + unhide-time migration.
            if reason == Placement.REASONS.UNKNOWN_PARENT then
                -- keep dormant record untouched
            else
                local is_custom = type(section.custom_menus) == "table"
                    and section.custom_menus[id] ~= nil
                if is_custom then
                    local park = Placement.firstValidContainer(reg, section, id)
                    if type(park) == "string"
                            and Placement.canPlace(reg, section, id, park) then
                        section.parent_override[id] = { provider = nil, parent = park }
                        report.dropped_parents[#report.dropped_parents + 1] = id .. "->" .. park
                    else
                        section.parent_override[id] = nil
                        report.dropped_parents[#report.dropped_parents + 1] = id
                    end
                else
                    section.parent_override[id] = nil
                    report.dropped_parents[#report.dropped_parents + 1] = id
                end
            end
        end
    end
    -- Order sequences: tabs never belong inside ordinary menus. Strip them
    -- deterministically (first occurrence wins elsewhere via the bar).
    if type(section.order_override) == "table" then
        local menu_ids = {}
        for menu_id in pairs(section.order_override) do menu_ids[#menu_ids + 1] = menu_id end
        table.sort(menu_ids, function(a, b) return tostring(a) < tostring(b) end)
        for _, menu_id in ipairs(menu_ids) do
            local rec = section.order_override[menu_id]
            if type(rec) == "table" and type(rec.entries) == "table" then
                local kept = {}
                local stripped_here = false
                for _, entry in ipairs(rec.entries) do
                    local eid = nil
                    if type(entry) == "table" then
                        if entry.separator == true then
                            kept[#kept + 1] = entry
                        elseif type(entry.id) == "string" then
                            eid = entry.id
                        end
                    end
                    if eid then
                        if Placement.isTab(reg, eid) then
                            stripped_here = true
                        else
                            kept[#kept + 1] = entry
                        end
                    elseif entry.separator ~= true then
                        -- Malformed entry without id: drop (loader would
                        -- quarantine the whole file otherwise).
                        stripped_here = true
                    end
                end
                if stripped_here then
                    report.stripped_sequences[#report.stripped_sequences + 1] = menu_id
                end
                if #kept == 0 then
                    section.order_override[menu_id] = nil
                else
                    rec.entries = kept
                end
            end
        end
    end
    -- Tab order: only live tabs.
    if type(section.tab_order) == "table" then
        local filtered = Placement.filterTabBar(reg, section.tab_order)
        -- Compare as sets ignoring order? Order matters, but any filtering is
        -- a migration. Deterministic: filtered preserves input order.
        local same = #filtered == #section.tab_order
        if same then
            for i = 1, #filtered do
                if filtered[i] ~= section.tab_order[i] then same = false break end
            end
        end
        if not same then
            report.tab_order_filtered = true
            if #filtered == 0 then
                section.tab_order = nil
            else
                section.tab_order = filtered
            end
        end
    end
    return report
end

return Placement

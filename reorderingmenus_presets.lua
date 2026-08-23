--[[--
presets.lua — snapshots and merging of INTENT, not runtime menu arrays.

A preset captures what the user did (sparse intent records), never the fully
resolved menu. Applying one therefore keeps working across KOReader/plugin
updates: whatever the snapshot does not mention continues to follow the
current defaults, and entries that appeared after the snapshot are kept.

Formats:
  v2 view preset     : format = "reorderingmenus_intent_preset", carries a
                       sparse intent section for one view
  v2 submenu preset  : format = "reorderingmenus_submenu_preset", version 2,
                       carries per-menu sequences plus created-submenu titles
  legacy formats     : dense order tables written by older versions; they are
                       converted against the CURRENT defaults on load

Built-in layouts are code-defined intent fragments (tab order + hidden tabs)
resolved against the running installation at apply time.
--]]

local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
local AtomicWriter = require("reorderingmenus_atomic_writer")
local Materializer = require("reorderingmenus_materializer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local MenuSchema = require("reorderingmenus_menu_schema")
local util = require("util")
local _ = require("gettext")

local Presets = {}

local SEPARATOR_ID = MenuSchema.SEPARATOR_ID

-- -------------------------------------------------------------------------
-- Paths / names
-- -------------------------------------------------------------------------

function Presets.getPresetsDir(view)
    local base_dir = string.format("%s/menu_order_presets",
        KoreaderAdapter.getSettingsDir())
    if not lfs.attributes(base_dir) then util.makePath(base_dir) end
    local view_dir = string.format("%s/%s", base_dir, view)
    if not lfs.attributes(view_dir) then util.makePath(view_dir) end
    return view_dir
end

local function cleanPathComponent(value)
    local clean_value = tostring(value or ""):gsub("[^%w_%-]", "_")
    return clean_value ~= "" and clean_value or "submenu"
end

function Presets.getSubmenuPresetsDir(view, menu_id)
    local root_dir = string.format("%s/submenus", Presets.getPresetsDir(view))
    if not lfs.attributes(root_dir) then util.makePath(root_dir) end
    local menu_dir = string.format("%s/%s", root_dir, cleanPathComponent(menu_id))
    if not lfs.attributes(menu_dir) then util.makePath(menu_dir) end
    return menu_dir
end

local function cleanPresetName(preset_name)
    if not preset_name or preset_name:match("^%s*$") then
        return nil, _("Preset name cannot be empty.")
    end
    -- Strip path separators and drive-ish prefixes FIRST so no traversal
    -- residue ("..", "a/b" -> "ab") can smuggle a directory escape through
    -- the later allow-list filter.
    local clean_name = tostring(preset_name)
        :gsub("[/\\]", "")
        :gsub("^%.+", "")
    clean_name = clean_name
        :gsub("[^%w_%- %.]", "")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
    -- Length cap: filesystems reject names > 255 bytes; leave room for
    -- the .lua suffix and future subdirectory prefixes.
    if #clean_name > 200 then
        return nil, _("Preset name is too long.")
    end
    if clean_name == "" then
        return nil, _("Invalid preset name.")
    end
    return clean_name
end

-- Case-insensitive collision check. On case-insensitive filesystems (macOS,
-- Windows) saving "Tools.lua" silently overwrites "tools.lua"; refusing the
-- near-collision keeps presets from destroying each other.
local function findCaseInsensitiveCollision(view, file_path, own_name)
    local dir = Presets.getPresetsDir(view)
    if not lfs.attributes(dir) then return nil end
    local lower_own = own_name:lower()
    for entry in lfs.dir(dir) do
        if entry:sub(-4) == ".lua" then
            local stem = entry:sub(1, -5)
            if stem:lower() == lower_own then
                local full = dir .. "/" .. entry
                -- Same resolved file is fine (overwrite of itself); any other
                -- case-variant is a collision.
                if full ~= file_path then return full end
            end
        end
    end
    return nil
end

-- -------------------------------------------------------------------------
-- Built-in presets: intent fragments resolved against current defaults
-- -------------------------------------------------------------------------

local BUILTIN_FRAGMENTS = {
    reader = {
        {
            id = "builtin_reading_focused",
            name = _("Reading Focused"),
            description = _("Puts Typeset and Navigation first; hides Search, Main, and Filemanager."),
            tab_order = { "typeset", "navi", "setting", "tools" },
            hidden_tabs = { "filemanager", "main", "search" },
        },
        {
            id = "builtin_minimalist",
            name = _("Minimalist Reader"),
            description = _("Keeps only Navigation and Typeset tabs for a distraction-free experience."),
            tab_order = { "navi", "typeset" },
            hidden_tabs = { "setting", "tools", "search", "filemanager", "main" },
        },
        {
            id = "builtin_power_user",
            name = _("Full Power User"),
            description = _("All tabs and submenus exposed with Search in the first position."),
            tab_order = { "search", "navi", "typeset", "setting", "tools", "filemanager", "main" },
            hidden_tabs = {},
        },
    },
    filemanager = {
        {
            id = "builtin_clean_fm",
            name = _("Clean File Manager"),
            description = _("Essential browsing and device tools without clutter."),
            tab_order = { "filemanager_settings", "setting", "tools" },
            hidden_tabs = { "search", "filemanager", "main" },
        },
        {
            id = "builtin_power_user",
            name = _("Full Power User"),
            description = _("All tabs and submenus visible."),
            tab_order = nil,
            hidden_tabs = {},
        },
    },
}

local function buildBuiltinPresets()
    local presets = {
        {
            id = "builtin_default",
            name = _("Default (Stock KOReader)"),
            description = _("Standard factory menu layout. Selecting this empties the config file to restore stock."),
            is_builtin = true,
            is_default = true,
        },
    }
    for _, view in ipairs({ "reader", "filemanager" }) do
        for _, fragment in ipairs(BUILTIN_FRAGMENTS[view] or {}) do
            local preset = util.tableDeepCopy(fragment)
            preset.is_builtin = true
            table.insert(presets, preset)
        end
    end
    return presets
end

-- -------------------------------------------------------------------------
-- User view presets
-- -------------------------------------------------------------------------

function Presets.saveViewPreset(view, preset_name, intent_section)
    local clean_name, name_err = cleanPresetName(preset_name)
    if not clean_name then return false, name_err end
    local file_path = string.format("%s/%s.lua", Presets.getPresetsDir(view), clean_name)
    local collision = findCaseInsensitiveCollision(view, file_path, clean_name)
    if collision then
        return false, string.format(
            _("A preset named \"%s\" already exists (name differs only in letter case)."),
            collision:match("([^/]+)%.lua$"))
    end
    local data = {
        format = "reorderingmenus_intent_preset",
        version = 2,
        name = clean_name,
        view = view,
        intent = util.tableDeepCopy(intent_section),
    }
    local ok, err = AtomicWriter.writeTable(file_path, data)
    if not ok then return false, err end
    return true, file_path
end

function Presets.listUserPresets(view)
    local dir = Presets.getPresetsDir(view)
    local list = {}
    if lfs.attributes(dir) then
        for file in lfs.dir(dir) do
            if file:sub(-4) == ".lua" and file:sub(1, 1) ~= "." then
                local name = file:sub(1, -5)
                if name ~= ".hidden_builtins" then
                    table.insert(list, {
                        id = "user_" .. name,
                        name = name,
                        description = _("Custom user preset"),
                        path = string.format("%s/%s", dir, file),
                        is_builtin = false,
                    })
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return list
end

local function readPresetFile(path)
    if type(path) ~= "string" then return nil end
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local ok, res = pcall(dofile, path)
    if ok and type(res) == "table" then return res end
    return nil
end

local function removePresetFile(path)
    if type(path) ~= "string" or lfs.attributes(path, "mode") ~= "file" then
        return false, _("Preset file not found.")
    end
    local ok, err = os.remove(path)
    if not ok then return false, err or _("Failed to delete preset file.") end
    return true
end

local function pathIsWithin(dir, path)
    return type(path) == "string" and path:sub(1, #dir + 1) == dir .. "/"
end

-- Resolve a preset reference (table/string/builtin id) into
-- { kind = "default"|"builtin"|"user_v2"|"legacy", ... }.
function Presets.resolve(view, preset)
    local builtin_match
    if type(preset) == "string" then
        for _, b in ipairs(buildBuiltinPresets()) do
            if b.id == preset or b.name == preset then builtin_match = b break end
        end
        if builtin_match then
            return { kind = builtin_match.is_default and "default" or "builtin",
                     fragment = builtin_match }
        end
        local clean_name, name_err = cleanPresetName(
            preset:gsub("^user_", ""))
        if not clean_name then return nil, name_err end
        return { kind = "user_file", path = string.format(
            "%s/%s.lua", Presets.getPresetsDir(view), clean_name) }, preset
    elseif type(preset) == "table" then
        local pid = preset.id
        if type(pid) == "string" then
            for _, b in ipairs(buildBuiltinPresets()) do
                if b.id == pid then builtin_match = b break end
            end
        end
        if builtin_match then
            return { kind = builtin_match.is_default and "default" or "builtin",
                     fragment = builtin_match }
        end
        if preset.intent then
            return { kind = "user_v2", data = preset }
        end
        if preset.path then
            if not pathIsWithin(Presets.getPresetsDir(view), preset.path) then
                return nil, _("Preset path is outside this view's preset directory.")
            end
            return { kind = "user_file", path = preset.path }
        end
        -- In-memory dense table (tests, legacy callers).
        return { kind = "legacy_dense", dense = preset }
    end
    return nil, _("Preset not found.")
end

function Presets.readUserPreset(path)
    return readPresetFile(path)
end

-- Apply a user preset onto a transaction. The snapshot governs everything it
-- mentions; records for ids it has never heard about are carried over so
-- entries added since the save keep their placement and visibility.
function Presets.applyUserIntentPreset(view, txn, preset_intent, reg)
    -- Snapshot the current section first: the transaction hands out the live
    -- table, which the snapshot is about to replace.
    local current = util.tableDeepCopy(txn:view(view))
    local result = txn:view(view)

    local function footprintContains(id)
        if preset_intent.hidden and preset_intent.hidden[id] then return true end
        if preset_intent.parent_override and preset_intent.parent_override[id] then return true end
        if preset_intent.position_override and preset_intent.position_override[id] then return true end
        for _, seq in pairs(preset_intent.order_override or {}) do
            for _, listed in ipairs(seq) do
                if listed == id then return true end
            end
        end
        if preset_intent.custom_menus and preset_intent.custom_menus[id] then return true end
        return false
    end

    -- Carry-over policy: records for ids the preset never mentioned are kept
    -- ONLY when the id has no stock default home (plugin items / ghosts the
    -- snapshot could not know about). An unmentioned STOCK-resident id must
    -- follow the CURRENT defaults after apply - keeping its record would make
    -- every post-capture customization of a stock row un-undoable by presets.
    local function carriedOver(id)
        if footprintContains(id) then return false end
        if reg == nil then return true end   -- legacy callers: keep old behavior
        local node = reg.nodes and reg.nodes[id] or nil
        return node == nil or node.default_parent == nil
    end

    local carried_hidden, carried_parent, carried_position = {}, {}, {}
    for id, record in pairs(current.hidden or {}) do
        if carriedOver(id) then carried_hidden[id] = util.tableDeepCopy(record) end
    end
    for id, record in pairs(current.parent_override or {}) do
        if carriedOver(id) then
            carried_parent[id] = util.tableDeepCopy(record)
        end
    end
    for id, record in pairs(current.position_override or {}) do
        if carriedOver(id) then
            carried_position[id] = util.tableDeepCopy(record)
        end
    end

    -- Snapshot governs the mentioned surface entirely.
    result.hidden = util.tableDeepCopy(preset_intent.hidden or {})
    result.hidden_order = util.tableDeepCopy(preset_intent.hidden_order or {})
    result.parent_override = util.tableDeepCopy(preset_intent.parent_override or {})
    result.position_override = util.tableDeepCopy(preset_intent.position_override or {})
    result.order_override = util.tableDeepCopy(preset_intent.order_override or {})
    -- Era stamps travel with their sequences; presets written before era
    -- stamping simply have none (unstamped = applies unconditionally).
    result.sequence_eras = util.tableDeepCopy(preset_intent.sequence_eras or {})
    result.separators = util.tableDeepCopy(preset_intent.separators or {})
    result.raw_override = {} -- raw passthroughs never survive a semantic apply
    result.tab_order = preset_intent.tab_order
        and util.tableDeepCopy(preset_intent.tab_order) or nil
    result.custom_menus = util.tableDeepCopy(preset_intent.custom_menus or {})

    -- Created later than the snapshot: keep them alive.
    for id, record in pairs(carried_hidden) do
        result.hidden[id] = record
        if not util.arrayContains(result.hidden_order, id) then
            table.insert(result.hidden_order, id)
        end
    end
    for id, record in pairs(carried_parent) do
        result.parent_override[id] = record
    end
    for id, record in pairs(carried_position) do
        result.position_override[id] = record
    end
    for id, custom in pairs(current.custom_menus or {}) do
        if not result.custom_menus[id] then
            result.custom_menus[id] = util.tableDeepCopy(custom)
        end
    end
end

-- -------------------------------------------------------------------------
-- Submenu presets
-- -------------------------------------------------------------------------

local function collectSubtree(reg, intent, menu_id, include_nested)
    local menus = {}
    local visited = {}
    local graph = Materializer.resolve(reg, intent)

    local function children_of(mid)
        local kids = {}
        local seq = graph.lists[mid] or {}
        for _, id in ipairs(seq) do
            if graph.lists[id] and not visited[id] then
                kids[id] = true
            end
        end
        return kids
    end

    local function visit(mid)
        if visited[mid] then return end
        visited[mid] = true
        local sequence = {}
        for _, id in ipairs(graph.lists[mid] or {}) do
            if id ~= SEPARATOR_ID then table.insert(sequence, id) end
        end
        menus[mid] = {
            sequence = sequence,
        }
        if include_nested then
            for kid in pairs(children_of(mid)) do
                visit(kid)
            end
        end
    end

    visit(menu_id)
    return menus
end

function Presets.saveSubmenuPreset(view, menu_id, menu_title, preset_name,
                                   include_nested, reg, intent, staged_items)
    local clean_name, name_err = cleanPresetName(preset_name)
    if not clean_name then return false, name_err end

    local subtree = collectSubtree(reg, intent, menu_id, include_nested == true)
    if staged_items then
        local seq = {}
        local sep_anchors = {}
        local prev = false
        for _, id in ipairs(staged_items) do
            if id ~= SEPARATOR_ID then
                table.insert(seq, id)
                prev = id
            else
                table.insert(sep_anchors, prev)
            end
        end
        subtree[menu_id] = { sequence = seq, sep_anchors = sep_anchors }
    end
    -- Divider records travel with their menus so a capture reproduces the
    -- exact visual grouping on apply.
    for menu_id in pairs(subtree) do
        local seps = {}
        for key, sep in pairs(intent.separators or {}) do
            if type(sep) == "table" and sep.parent == menu_id then
                seps[key] = { parent = sep.parent, after = sep.after }
            end
        end
        subtree[menu_id].separators = next(seps) and seps or nil
    end
    local any = false
    for _, frag in pairs(subtree) do
        if frag.sequence then any = true break end
    end
    if not any then
        subtree[menu_id] = subtree[menu_id] or { sequence = nil }
    end

    local customs = {}
    for cid, custom in pairs(intent.custom_menus or {}) do
        if subtree[cid] then
            customs[cid] = { title = custom.title, parent = custom.parent }
        end
    end

    local data = {
        format = "reorderingmenus_submenu_preset",
        version = 2,
        name = clean_name,
        menu_id = menu_id,
        menu_title = menu_title or menu_id,
        include_submenus = include_nested == true,
        menus = subtree,
        custom_menus = customs,
    }
    local file_path = string.format("%s/%s.lua",
        Presets.getSubmenuPresetsDir(view, menu_id), clean_name)
    local ok, err = AtomicWriter.writeTable(file_path, data)
    if not ok then return false, err end
    return true, file_path
end

function Presets.listSubmenuPresets(view, menu_id)
    local dir = Presets.getSubmenuPresetsDir(view, menu_id)
    local presets = {}
    for file in lfs.dir(dir) do
        if file:sub(-4) == ".lua" and file:sub(1, 1) ~= "." then
            local path = string.format("%s/%s", dir, file)
            local ok, data = pcall(dofile, path)
            if ok and type(data) == "table"
                    and data.format == "reorderingmenus_submenu_preset"
                    and data.menu_id == menu_id and type(data.menus) == "table" then
                local menu_count = 0
                for _ in pairs(data.menus) do menu_count = menu_count + 1 end
                table.insert(presets, {
                    id = "submenu_" .. file:sub(1, -5),
                    name = data.name or file:sub(1, -5),
                    description = data.include_submenus
                        and string.format(_("Order for this menu and %d nested menu(s)"), math.max(0, menu_count - 1))
                        or _("Order for this menu only"),
                    include_submenus = data.include_submenus == true,
                    menu_count = menu_count,
                    path = path,
                })
            end
        end
    end
    table.sort(presets, function(a, b) return a.name:lower() < b.name:lower() end)
    return presets
end

-- Load a submenu preset onto the transaction: captured sequences govern;
-- residents that appeared afterwards keep their relative order at the tail.
function Presets.loadSubmenuPreset(view, menu_id, preset_ref, reg, txn, staged_items)
    local data
    if type(preset_ref) == "table" and preset_ref.menus then
        data = util.tableDeepCopy(preset_ref)
    elseif type(preset_ref) == "table" and preset_ref.path then
        data = readPresetFile(preset_ref.path)
    elseif type(preset_ref) == "string" then
        local clean_name, name_err = cleanPresetName(
            preset_ref:gsub("^submenu_", ""))
        if not clean_name then return false, name_err end
        data = readPresetFile(string.format("%s/%s.lua",
            Presets.getSubmenuPresetsDir(view, menu_id), clean_name))
    end
    if type(data) ~= "table" or data.format ~= "reorderingmenus_submenu_preset"
            or data.menu_id ~= menu_id or type(data.menus) ~= "table"
            or not data.menus[menu_id] then
        return false, _("Submenu preset not found or does not match this menu.")
    end

    -- Current residents per affected level come from the live graph.
    local graph = Materializer.resolve(reg, txn:view(view))
    local function currentMembers(target)
        local members, seen = {}, {}
        local function add(id)
            if id ~= SEPARATOR_ID and not seen[id] then
                seen[id] = true
                table.insert(members, id)
            end
        end
        for _, id in ipairs(graph.lists[target] or {}) do add(id) end
        -- Hidden members belong here too when their origin says so.
        for hid, record in pairs(txn:view(view).hidden or {}) do
            if record.origin == target then add(hid) end
        end
        return members
    end

    local captured_menus = util.tableDeepCopy(data.menus)
    -- Legacy dense payloads store plain lists instead of fragments.
    for captured_id, value in pairs(captured_menus) do
        if type(value) == "table" and value.sequence == nil and #value > 0 then
            captured_menus[captured_id] = { sequence = value }
        end
    end

    if staged_items then
        local seq = {}
        for _, id in ipairs(staged_items) do
            if id ~= SEPARATOR_ID then table.insert(seq, id) end
        end
        captured_menus[menu_id] = { sequence = seq }
    end

    for captured_id, frag in pairs(captured_menus) do
        if type(frag) == "table" and type(frag.sequence) == "table"
                and graph.lists[captured_id] then
            local merged, used = {}, {}
            for _, id in ipairs(frag.sequence) do
                if not used[id] then
                    used[id] = true
                    table.insert(merged, id)
                end
            end
            for _, id in ipairs(currentMembers(captured_id)) do
                if not used[id] then
                    used[id] = true
                    table.insert(merged, id)
                end
            end
            -- Era-stamp the applied sequence like any bulk write.
            local seq_eras = {}
            for _, id in ipairs(merged) do
                local node = reg.nodes[id]
                seq_eras[id] = node and node.provider or nil
            end
            txn:setOrderOverride(view, captured_id, merged, seq_eras)
            -- Divider anchoring travels with the capture.
            local section = txn:view(view)
            for key in pairs(section.separators or {}) do
                local sep = section.separators[key]
                if sep and sep.parent == captured_id then
                    section.separators[key] = nil
                end
            end
            for key, sep in pairs(frag.separators or {}) do
                txn:setSeparator(view, "cap_" .. tostring(key), {
                    parent = sep.parent,
                    after = sep.after,
                })
            end
            -- Anchors staged from the current arrangement map positionally.
            local idx, prev = 0, false
            for _, anchor in ipairs(frag.sep_anchors or {}) do
                idx = idx + 1
                txn:setSeparator(view,
                    string.format("captured_%s_%d", captured_id, idx), {
                        parent = captured_id,
                        after = anchor == false and false or anchor,
                    })
            end
        end
    end

    -- Created submenus referenced by the capture travel with their titles.
    local customs = data.custom_menus or {}
    for cid, custom in pairs(customs) do
        if type(custom) == "table" and not txn:getCustomMenus(view)[cid]
                and graph.lists[cid] == nil then
            txn:setCustomMenu(view, cid, {
                title = custom.title,
                parent = custom.parent,
            })
        end
    end
    return true
end

function Presets.deleteSubmenuPreset(view, menu_id, preset)
    local path
    if type(preset) == "table" then
        path = preset.path
    elseif type(preset) == "string" then
        local clean_name, name_err = cleanPresetName(preset:gsub("^submenu_", ""))
        if not clean_name then return false, name_err end
        path = string.format("%s/%s.lua",
            Presets.getSubmenuPresetsDir(view, menu_id), clean_name)
    end
    local dir = Presets.getSubmenuPresetsDir(view, menu_id)
    if path and pathIsWithin(dir, path)
            and lfs.attributes(path, "mode") == "file" then
        local ok, data = pcall(dofile, path)
        if ok and type(data) == "table" and data.menu_id == menu_id then
            return removePresetFile(path)
        end
    end
    return false, _("Submenu preset file not found.")
end

-- -------------------------------------------------------------------------
-- Builtin visibility (hide from list), shared with the old architecture
-- -------------------------------------------------------------------------

function Presets.getHiddenBuiltinPath(view)
    return string.format("%s/.hidden_builtins.lua", Presets.getPresetsDir(view))
end

function Presets.getHiddenBuiltinIds(view)
    local path = Presets.getHiddenBuiltinPath(view)
    if lfs.attributes(path) then
        local ok, res = pcall(dofile, path)
        if ok and type(res) == "table" then return res end
    end
    return {}
end

function Presets.isBuiltinHidden(view, preset_id)
    if preset_id == "builtin_default" then return false end
    for _, hid in ipairs(Presets.getHiddenBuiltinIds(view)) do
        if hid == preset_id then return true end
    end
    return false
end

function Presets.hideBuiltinPreset(view, preset_id)
    if preset_id == "builtin_default" then
        return false, _("Cannot delete the default preset.")
    end
    local hidden = Presets.getHiddenBuiltinIds(view)
    for _, hid in ipairs(hidden) do
        if hid == preset_id then return true end
    end
    table.insert(hidden, preset_id)
    local ok, err = AtomicWriter.writeTable(
        Presets.getHiddenBuiltinPath(view), hidden)
    if not ok then return false, err end
    return true
end

function Presets.unhideBuiltinPreset(view, preset_id)
    local hidden = Presets.getHiddenBuiltinIds(view)
    local new_hidden, found = {}, false
    for _, hid in ipairs(hidden) do
        if hid ~= preset_id then
            table.insert(new_hidden, hid)
        else
            found = true
        end
    end
    if not found then return false end
    local path = Presets.getHiddenBuiltinPath(view)
    if #new_hidden == 0 then
        local ok, err = os.remove(path)
        if not ok and lfs.attributes(path, "mode") == "file" then
            return false, err
        end
    else
        local ok, err = AtomicWriter.writeTable(path, new_hidden)
        if not ok then return false, err end
    end
    return true
end

function Presets.getBuiltinPresets(view)
    local hidden = {}
    for _, id in ipairs(Presets.getHiddenBuiltinIds(view)) do
        hidden[id] = true
    end
    local visible = {}
    for _, preset in ipairs(buildBuiltinPresets()) do
        local for_view = preset.id == "builtin_default"
            or (BUILTIN_FRAGMENTS[view] and (function()
                for _, f in ipairs(BUILTIN_FRAGMENTS[view]) do
                    if f.id == preset.id then return true end
                end
                return false
            end)())
        if for_view and not hidden[preset.id] then
            table.insert(visible, preset)
        end
    end
    return visible
end

function Presets.getAllPresets(view)
    local combined = {}
    for _, p in ipairs(Presets.getBuiltinPresets(view)) do
        table.insert(combined, p)
    end
    for _, p in ipairs(Presets.listUserPresets(view)) do
        table.insert(combined, p)
    end
    return combined
end

function Presets.listDeletablePresets(view)
    local deletable = {}
    for _, p in ipairs(Presets.getAllPresets(view)) do
        if p.id ~= "builtin_default" then table.insert(deletable, p) end
    end
    return deletable
end

function Presets.updateUserPresetFile(view, preset, intent_section)
    local name
    if type(preset) == "table" then
        name = preset.name
            or (type(preset.path) == "string" and preset.path:match("([^/]+)%.lua$"))
    elseif type(preset) == "string" then
        name = preset
    end
    if not name or name == "" then return false, _("Preset not found.") end
    local clean_name, name_err = cleanPresetName(name:gsub("^user_", ""))
    if not clean_name then return false, name_err end
    name = clean_name
    local file_path = string.format("%s/%s.lua", Presets.getPresetsDir(view), name)
    if lfs.attributes(file_path, "mode") ~= "file" then
        return false, _("Preset file not found.")
    end
    local existing = readPresetFile(file_path)
    if existing and existing.format == "reorderingmenus_intent_preset" then
        existing.intent = util.tableDeepCopy(intent_section)
        local ok, err = AtomicWriter.writeTable(file_path, existing)
        if not ok then return false, err end
        logger.info("ReorderingMenus: updated preset", name, "in", view)
        return true, file_path
    end
    -- Legacy file: upgrade it to the intent format on update.
    return Presets.saveViewPreset(view, name, intent_section)
end

function Presets.deletePresetFile(view, preset_name)
    local dir = Presets.getPresetsDir(view)
    local clean_name, name_err = cleanPresetName(
        type(preset_name) == "string" and preset_name:gsub("^user_", "") or nil)
    if not clean_name then return false, name_err end
    local candidates = { clean_name }
    for _, candidate in ipairs(candidates) do
        local file_path = string.format("%s/%s.lua", dir, candidate)
        if lfs.attributes(file_path) then
            return removePresetFile(file_path)
        end
    end
    return false, _("Preset file not found.")
end

return Presets

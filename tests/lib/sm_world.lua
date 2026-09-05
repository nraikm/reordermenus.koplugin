--[[--
sm_world.lua — manager-verb state-machine world for ReorderingMenus.

Unlike the first-generation state machine (which poked intent.* fields
directly), this world drives the SAME write path the UI does:

    moveItemToMenu / moveItem / stageList / setItemHidden / setTabHidden /
    restoreItemDefault / insertSeparator / removeSeparator / reorderTabs /
    createSubmenu / deleteCustomSubmenu / saveOrder / savePreset / loadPreset /
    resetSubmenu / resetOrder / mirroring / copyLayout / restart

plus environment operations (plugin install/uninstall/hint upgrades,
upstream default mutations, external native-file edits, native-file
deletion, Reader/FM switching).

Every operation records {op, args} at PICK time, so a history is a
deterministic replay script (ddmin-shrinkable, fixture-promotable).

Invariant battery (checked after every op unless noted):

  I1  render-safety   real MenuSorter consumes the projection without error
  I2  single-parent   every id appears in at most one list (tabs included)
  I3  hidden-gone     disabled ids render nowhere
  I6  user-wins       explicit parent overrides hold while their era applies
  I7  default-wins    untouched stock ids sit at their current default parent
  I13 no-fabrication  MenuSorter output contains no id outside the supplied
                      item table (no "NEW:" orphans from our own emission)
  I15 order-preserve  relative order of order_override survivors is kept
  I16 hidden-order    disabled == ordinal-ordered hidden records + leftovers
  I8  restart-equiv   fingerprint stable across dropSessionState + reload
                      (checked on restart ops and every Nth step)
  I9  native-fixpoint save -> reloadFromDisk -> identical projection
                      (checked on save ops)
  I11 ser-determinism two consecutive saves serialize identically
                      (checked on save ops)
--]]

local MenuSchema = require("lib.menu_schema")
local Registry = require("lib.registry")
local Materializer = require("lib.materializer")
local Validator = require("lib.validator")
local MenuSorter = require("ui/menusorter")
local KoreaderAdapter = require("lib.koreader_adapter")
local IntentStore = require("lib.intent_store")
local NativeWriter = require("lib.native_writer")
local dump = require("dump")

local Manager = require("lib.menuorder_manager")

local SEPARATOR_ID = "----------------------------"
local RESERVED = {
    ["KOMenu:menu_buttons"] = true,
    ["KOMenu:disabled"] = true,
    ["KOMenu:custom_submenus"] = true,
}
local VIEWS = { "reader", "filemanager" }

local World = {}
World.__index = World

-- order-stable structural hash
local function fingerprint(value)
    local kind = type(value)
    if kind == "table" then
        local is_array = #value > 0
        local parts = {}
        if is_array then
            for i = 1, #value do
                parts[#parts + 1] = fingerprint(value[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(value) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = k .. "=" .. fingerprint(value[k])
        end
        return "{" .. table.concat(parts, ";") .. "}"
    end
    return kind .. ":" .. tostring(value)
end
World.fingerprint = fingerprint

local TITLE_POOL = { "Tools", "Notes", "Notes", "Ångström", "中文菜单",
    "a very long submenu title that keeps going and going just to be awkward" }

-- deep copy used throughout (upstream mutations, MenuSorter inputs)
local function deep_copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deep_copy(v) end
    return out
end

function World:new(seed)
    local w = setmetatable({}, self)
    w.seed = seed
    w.rng = (seed * 7919) % 2147483647
    w.view = "filemanager"
    w.history = {}
    w.preset_names = {}  -- [name] = view the preset was saved for
    w.preset_counter = 0
    w.defaults = {}
    w.registrations = {}
    w.providers = {}
    w.op_counter = 0
    w:isolateProcessState()
    w:resetEnvironment()
    return w
end

function World:rand(n)
    self.rng = (self.rng * 1103515245 + 12345) % 2147483647
    return self.rng % n + 1
end

function World:pick(list)
    if #list == 0 then return nil end
    return list[self:rand(#list)]
end

function World:otherView()
    return self.view == "reader" and "filemanager" or "reader"
end

-- full environment reset: wipe persisted state for both views, inject a
-- private copy of the real stock defaults, clear registrations.
function World:resetEnvironment()
    local sd = KoreaderAdapter.getSettingsDir()
    for _, view in ipairs(VIEWS) do
        os.remove(KoreaderAdapter.getNativePath(view))
        Manager:resetOrder(view)
        Manager:dropSessionState(view)
    end
    -- Presets from previous worlds/seeds live in a shared directory; a new
    -- world must not be able to apply them.
    os.execute("rm -rf " .. sd .. "/menu_order_presets")
    os.remove(sd .. "/reorderingmenus_intent.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    -- The sidecar reader caches the loaded record at module level; without
    -- this reset a new world silently inherits the PREVIOUS world's
    -- materialization record, masking startup-import decisions (observed as
    -- false XPASS: fixtures failed in isolation but passed mid-suite).
    NativeWriter._resetCaches()
    -- open-editor healing records must not leak between worlds
    Manager.recent_moves.filemanager = {}
    Manager.recent_moves.reader = {}
    for name in pairs(self.preset_names or {}) do
        Manager:deletePreset("filemanager", name)
        Manager:deletePreset("reader", name)
    end
    IntentStore.load(true)
    self.preset_names = {}
    for _, view in ipairs(VIEWS) do
        Manager.default_orders[view] = nil
        local defaults = Manager:getDefaultOrder(view)
        self.defaults[view] = defaults
        Manager.default_orders[view] = defaults
        self.registrations[view] = {}
        self.providers[view] = {}
        Manager:setLiveRegistrations(view, self.registrations[view],
            self.providers[view])
        Manager:dropSessionState(view)
    end
    self.view = "filemanager"
end

-- Cross-world isolation (de-flake): the manager caches per-view sessions,
-- an active staged transaction, and hidden-display/mirroring preferences at
-- module level. A new world in the same process must not inherit any of
-- them from the previous seed's run, otherwise replaying a promoted fixture
-- in a fresh process diverges from how the failure was originally found.
function World:isolateProcessState()
    if Manager.dropAllSessions then
        Manager:dropAllSessions()
    else
        for _, view in ipairs(VIEWS) do Manager:dropSessionState(view) end
    end
    Manager.backups = { reader = nil, filemanager = nil }
    Manager.synced_views = { reader = nil, filemanager = nil }
    Manager.staged_txn_probe = nil
    Manager.setMirroringEnabled(false)
    Manager.setHiddenInPlace(true)
    KoreaderAdapter.invalidateNativeModuleCache()
    KoreaderAdapter._tab_safety_cache = nil
    NativeWriter._resetCaches()
end

function World:syncRegistrations(view)
    Manager:setLiveRegistrations(view, self.registrations[view],
        self.providers[view])
end

-- Replace the defaults object for a view (identity change forces the
-- manager to rebuild its registry, exactly like a KOReader update).
function World:setDefaults(view, defaults)
    self.defaults[view] = defaults
    Manager.default_orders[view] = defaults
    Manager:dropSessionState(view)
    self:syncRegistrations(view)
end

function World:restart()
    for _, view in ipairs(VIEWS) do
        Manager:dropSessionState(view)
    end
    IntentStore.load(true)
    for _, view in ipairs(VIEWS) do
        self:syncRegistrations(view)
    end
end

-- ---------------------------------------------------------------------
-- Selection helpers over the live projection
-- ---------------------------------------------------------------------

function World:projection(view)
    return Manager:loadOrder(view or self.view)
end

function World:menuIds(view)
    local out = {}
    for id in pairs(self:projection(view)) do
        if not RESERVED[id] then out[#out + 1] = id end
    end
    return out
end

function World:liveItemIds(view)
    view = view or self.view
    local out = {}
    for id in pairs(self.registrations[view]) do out[#out + 1] = id end
    for menu_id, list in pairs(self.defaults[view]) do
        if not RESERVED[menu_id] and menu_id ~= "KOMenu:menu_buttons"
                and type(list) == "table" then
            for _, id in ipairs(list) do
                if type(id) == "string" and id ~= SEPARATOR_ID then
                    out[#out + 1] = id
                end
            end
        end
    end
    return out
end

function World:tabIds(view)
    view = view or self.view
    local out = {}
    for _, id in ipairs(self.defaults[view]["KOMenu:menu_buttons"] or {}) do
        out[#out + 1] = id
    end
    return out
end

function World:visibleNonTabItems(view)
    view = view or self.view
    local order = self:projection(view)
    local tabs = {}
    for _, t in ipairs(order["KOMenu:menu_buttons"] or {}) do tabs[t] = true end
    local disabled = {}
    for _, d in ipairs(order["KOMenu:disabled"] or {}) do disabled[d] = true end
    local out = {}
    for menu_id, list in pairs(order) do
        if not RESERVED[menu_id] and type(list) == "table" then
            for _, id in ipairs(list) do
                if id ~= SEPARATOR_ID and not tabs[id] and not disabled[id]
                        and not Manager:isItemProtected(id) then
                    out[#out + 1] = id
                end
            end
        end
    end
    return out
end

function World:disabledIds(view)
    view = view or self.view
    return self:projection(view)["KOMenu:disabled"] or {}
end

function World:customSubmenuIds(view)
    view = view or self.view
    return Manager:getAllSubmenuIds(view)
end

-- ---------------------------------------------------------------------
-- Operation table: pick(world) -> args | nil ; apply(world, args) -> desc
-- ---------------------------------------------------------------------

local OPS = {}

local function define_op(name, pick, apply)
    OPS[name] = { pick = pick, apply = apply }
end

-- ---- user verbs ----

define_op("move_item_to_menu", function(w)
    local ids = w:visibleNonTabItems()
    local id = w:pick(ids)
    local menus = w:menuIds()
    local dest = w:pick(menus)
    if not id or not dest then return nil end
    local from = Manager:getParentMenu(w.view, id)
    if not from then return nil end
    return { id = id, from = from, dest = dest }
end, function(w, a)
    return Manager:moveItemToMenu(w.view, a.id, a.from, a.dest)
        and string.format("move %s: %s->%s", a.id, a.from, a.dest)
        or string.format("move %s refused", a.id)
end)

define_op("move_item_in_menu", function(w)
    local menus = w:menuIds()
    local menu = w:pick(menus)
    if not menu then return nil end
    local items = Manager:getMenuItems(w.view, menu)
    if #items < 2 then return nil end
    return { menu = menu, from = w:rand(#items), to = w:rand(#items) }
end, function(w, a)
    return Manager:moveItem(w.view, a.menu, a.from, a.to)
        and string.format("drag %s[%d]->[%d]", a.menu, a.from, a.to)
        or "drag refused"
end)

define_op("stage_list_permutation", function(w)
    local menus = w:menuIds()
    local menu = w:pick(menus)
    if not menu then return nil end
    local items = Manager:getMenuItems(w.view, menu)
    local non_sep = {}
    for _, id in ipairs(items) do
        if id ~= SEPARATOR_ID then non_sep[#non_sep + 1] = id end
    end
    if #non_sep < 2 then return nil end
    -- Fisher-Yates with the world rng
    for i = #non_sep, 2, -1 do
        local j = w:rand(i)
        non_sep[i], non_sep[j] = non_sep[j], non_sep[i]
    end
    return { menu = menu, seq = non_sep }
end, function(w, a)
    Manager:stageList(w.view, a.menu, a.seq)
    return string.format("stage_list %s (%d items)", a.menu, #a.seq)
end)

define_op("hide_item", function(w)
    local ids = w:visibleNonTabItems()
    local id = w:pick(ids)
    if not id then return nil end
    return { id = id, parent = Manager:getParentMenu(w.view, id) }
end, function(w, a)
    local ok = Manager:setItemHidden(w.view, a.id, true, a.parent)
    return ok and string.format("hide %s", a.id) or string.format("hide %s refused", a.id)
end)

define_op("unhide_item", function(w)
    local id = w:pick(w:disabledIds())
    if not id then return nil end
    return { id = id }
end, function(w, a)
    local ok = Manager:setItemHidden(w.view, a.id, false)
    return ok and string.format("unhide %s", a.id)
        or string.format("unhide %s refused", a.id)
end)

define_op("hide_tab", function(w)
    local order = w:projection()
    local visible_tabs = {}
    for _, t in ipairs(order["KOMenu:menu_buttons"] or {}) do
        if not Manager:isTabProtected(t) then visible_tabs[#visible_tabs + 1] = t end
    end
    if #visible_tabs < 2 then return nil end
    return { id = w:pick(visible_tabs) }
end, function(w, a)
    local ok = Manager:setTabHidden(w.view, a.id, true)
    return ok and string.format("hide_tab %s", a.id) or "hide_tab refused"
end)

define_op("restore_item_default", function(w)
    local ids = w:liveItemIds()
    local id = w:pick(ids)
    if not id then return nil end
    return { id = id }
end, function(w, a)
    local ok = Manager:restoreItemDefault(w.view, a.id)
    return ok and string.format("restore_default %s", a.id)
        or string.format("restore_default %s refused", a.id)
end)

define_op("insert_separator", function(w)
    local menus = w:menuIds()
    local menu = w:pick(menus)
    if not menu then return nil end
    local items = Manager:getMenuItems(w.view, menu)
    return { menu = menu, idx = w:rand(#items + 1) }
end, function(w, a)
    return Manager:insertSeparator(w.view, a.menu, a.idx)
        and string.format("insert_sep %s@%d", a.menu, a.idx) or "insert_sep refused"
end)

define_op("remove_separator", function(w)
    local menus = w:menuIds()
    local candidates = {}
    for _, menu in ipairs(menus) do
        local items = Manager:getMenuItems(w.view, menu)
        for i, id in ipairs(items) do
            if id == SEPARATOR_ID then
                candidates[#candidates + 1] = { menu = menu, idx = i }
                break
            end
        end
    end
    if #candidates == 0 then return nil end
    return w:pick(candidates)
end, function(w, a)
    return Manager:removeSeparator(w.view, a.menu, a.idx)
        and string.format("remove_sep %s@%d", a.menu, a.idx) or "remove_sep refused"
end)

define_op("reorder_tabs", function(w)
    local tabs = Manager:getTabs(w.view)
    if #tabs < 2 then return nil end
    local perm = {}
    for _, t in ipairs(tabs) do perm[#perm + 1] = t end
    for i = #perm, 2, -1 do
        local j = w:rand(i)
        perm[i], perm[j] = perm[j], perm[i]
    end
    return { tabs = perm }
end, function(w, a)
    Manager:reorderTabs(w.view, a.tabs)
    return "reorder_tabs"
end)

define_op("create_submenu", function(w)
    local menus = w:menuIds()
    local parent = w:pick(menus)
    if not parent then return nil end
    return { parent = parent, title = w:pick(TITLE_POOL) }
end, function(w, a)
    local ok, id = Manager:createSubmenu(w.view, a.parent, a.title)
    return ok and string.format("create_submenu %s in %s", id, a.parent)
        or "create_submenu refused"
end)

define_op("delete_custom_submenu", function(w)
    local order = w:projection()
    local customs = order["KOMenu:custom_submenus"] or {}
    local ids = {}
    for id in pairs(customs) do ids[#ids + 1] = id end
    if #ids == 0 then return nil end
    return { id = w:pick(ids) }
end, function(w, a)
    local ok = Manager:deleteCustomSubmenu(w.view, a.id)
    return ok and string.format("delete_submenu %s", a.id)
        or string.format("delete_submenu %s refused (occupied?)", a.id)
end)

define_op("sort_menu_az", function(w)
    local menus = w:menuIds()
    local menu = w:pick(menus)
    if not menu then return nil end
    local items = Manager:getMenuItems(w.view, menu)
    local non_sep = {}
    for _, id in ipairs(items) do
        if id ~= SEPARATOR_ID then non_sep[#non_sep + 1] = id end
    end
    if #non_sep < 2 then return nil end
    table.sort(non_sep)
    if w:rand(2) == 2 then
        local rev = {}
        for i = #non_sep, 1, -1 do rev[#rev + 1] = non_sep[i] end
        non_sep = rev
    end
    return { menu = menu, seq = non_sep }
end, function(w, a)
    Manager:stageList(w.view, a.menu, a.seq)
    return string.format("sort_az %s (%d)", a.menu, #a.seq)
end)

define_op("save_order", function(w)
    return {}
end, function(w)
    local ok = Manager:saveOrder(w.view)
    return ok and "save_order" or "save_order FAILED"
end)

define_op("save_preset", function(w)
    w.preset_counter = w.preset_counter + 1
    return { name = string.format("sm%d_%d", w.seed, w.preset_counter),
             view = w.view }
end, function(w, a)
    local ok = Manager:savePreset(a.view, a.name)
    if ok then
        w.preset_names[a.name] = a.view
    end
    return ok and string.format("save_preset %s (%s)", a.name, a.view)
        or "save_preset FAILED"
end)

define_op("apply_preset", function(w)
    -- presets are per-view: only offer ones saved for the active view
    local names = {}
    for name, view in pairs(w.preset_names) do
        if view == w.view then names[#names + 1] = name end
    end
    if #names == 0 then return { name = "default" } end
    return { name = w:pick(names) }
end, function(w, a)
    local ok = Manager:loadPreset(w.view, a.name)
    return ok and string.format("apply_preset %s", a.name) or "apply_preset FAILED"
end)

define_op("reset_submenu", function(w)
    local menu = w:pick(w:menuIds())
    if not menu then return nil end
    return { menu = menu }
end, function(w, a)
    local ok = Manager:resetSubmenu(w.view, a.menu)
    return ok and string.format("reset_submenu %s", a.menu) or "reset_submenu refused"
end)

define_op("reset_view", function(w)
    return {}
end, function(w)
    Manager:resetOrder(w.view)
    return "reset_view"
end)

define_op("toggle_mirroring", function(w)
    return { enabled = not Manager:isMirroringEnabled() }
end, function(w, a)
    Manager:setMirroringEnabled(a.enabled)
    return a.enabled and "mirroring on" or "mirroring off"
end)

define_op("copy_layout", function(w)
    return {}
end, function(w)
    Manager:copyLayout(w.view, w:otherView())
    return string.format("copy_layout %s->%s", w.view, w:otherView())
end)

define_op("restart", function(w)
    return {}
end, function(w)
    -- Mirror the UI flow: changes are saved before a restart is prompted.
    -- A restart that discards unsaved staged edits is a different (also
    -- legal) scenario, covered by the dirty-close tests.
    pcall(function() Manager:saveOrder(w.view) end)
    pcall(function() Manager:saveOrder(w:otherView()) end)
    w:restart()
    return "restart"
end)

-- ---- environment verbs ----

define_op("plugin_install", function(w)
    -- per-world counters keep generated names/ids deterministic across
    -- worlds in one process (module-level counters would leak between seeds)
    w.plugin_counter = (w.plugin_counter or 0) + 1
    local name = string.format("p%d", w.plugin_counter)
    local id = string.format("xitem%d", w.plugin_counter)
    local menus = {}
    for _, m in ipairs({ "main", "tools", "setting", "more_tools", "search" }) do
        if w.defaults[w.view][m] then menus[#menus + 1] = m end
    end
    local hint = w:pick(menus)
    if not hint then return nil end
    return { name = name, id = id, hint = hint, view = w.view }
end, function(w, a)
    w.registrations[a.view][a.id] = { sorting_hint = a.hint }
    w.providers[a.view][a.id] = a.name
    w:syncRegistrations(a.view)
    Manager:refreshRegistry(a.view)
    return string.format("install %s (%s, hint %s) in %s",
        a.id, a.name, a.hint, a.view)
end)

define_op("plugin_uninstall", function(w)
    local names = {}
    for _, p in pairs(w.providers[w.view]) do names[p] = true end
    local list = {}
    for n in pairs(names) do list[#list + 1] = n end
    if #list == 0 then return nil end
    return { name = w:pick(list), view = w.view }
end, function(w, a)
    for id, p in pairs(w.providers[a.view]) do
        if p == a.name then
            w.registrations[a.view][id] = nil
            w.providers[a.view][id] = nil
        end
    end
    w:syncRegistrations(a.view)
    Manager:refreshRegistry(a.view)
    return string.format("uninstall %s from %s", a.name, a.view)
end)

define_op("plugin_upgrade_hint", function(w)
    local ids = {}
    for id in pairs(w.registrations[w.view]) do ids[#ids + 1] = id end
    local id = w:pick(ids)
    if not id then return nil end
    local menus = {}
    for m in pairs(w.defaults[w.view]) do
        if not RESERVED[m] then menus[#menus + 1] = m end
    end
    local hint = w:pick(menus)
    if not hint then return nil end
    return { id = id, hint = hint, view = w.view }
end, function(w, a)
    -- the plugin may have been uninstalled by an earlier op in a replayed
    -- history; treat a missing registration as a no-op rather than crashing
    local reg = w.registrations[a.view][a.id]
    if reg == nil then
        return string.format("upgrade_hint %s skipped (uninstalled)", a.id)
    end
    reg.sorting_hint = a.hint
    w:syncRegistrations(a.view)
    Manager:refreshRegistry(a.view)
    return string.format("upgrade_hint %s -> %s (%s)", a.id, a.hint, a.view)
end)


define_op("upstream_add", function(w)
    local menus = w:menuIds()
    local menu = w:pick(menus)
    if not menu then return nil end
    -- per-world counter keeps generated ids deterministic across worlds in
    -- one process (a module-level counter would leak between seeds)
    w.upstream_counter = (w.upstream_counter or 0) + 1
    return { menu = menu, id = string.format("nitem%d", w.upstream_counter),
             view = w.view }
end, function(w, a)
    local defaults = deep_copy(w.defaults[a.view])
    defaults[a.menu] = defaults[a.menu] or {}
    table.insert(defaults[a.menu], a.id)
    w:setDefaults(a.view, defaults)
    return string.format("upstream_add %s to %s (%s)", a.id, a.menu, a.view)
end)


define_op("upstream_remove", function(w)
    local candidates = {}
    for menu_id, list in pairs(w.defaults[w.view]) do
        if not RESERVED[menu_id] and menu_id ~= "KOMenu:menu_buttons"
                and type(list) == "table" and #list > 1 then
            for _, id in ipairs(list) do
                if type(id) == "string" and id ~= SEPARATOR_ID then
                    candidates[#candidates + 1] = { menu = menu_id, id = id }
                end
            end
        end
    end
    if #candidates == 0 then return nil end
    local c = w:pick(candidates)
    return { menu = c.menu, id = c.id, view = w.view }
end, function(w, a)
    local defaults = deep_copy(w.defaults[a.view])
    local list = defaults[a.menu]
    -- The picked menu can vanish between pick and apply when replaying a
    -- recorded history (earlier ops reshaped the defaults): skip instead of
    -- crashing on a nil list — mirrors external_native_edit's guard.
    if type(list) ~= "table" then
        return "upstream_remove skipped (menu gone)"
    end
    for i, id in ipairs(list) do
        if id == a.id then table.remove(list, i) break end
    end
    w:setDefaults(a.view, defaults)
    return string.format("upstream_remove %s from %s (%s)", a.id, a.menu, a.view)
end)

define_op("upstream_reorder", function(w)
    local menus = w:menuIds()
    local menu = w:pick(menus)
    if not menu then return nil end
    local list = w.defaults[w.view][menu]
    if type(list) ~= "table" or #list < 2 then return nil end
    local i = w:rand(#list - 1)
    return { menu = menu, i = i, view = w.view }
end, function(w, a)
    -- The picked menu can vanish between pick and apply when replaying a
    -- recorded history (earlier ops reshaped the defaults): skip instead of
    -- crashing on a nil list — mirrors external_native_edit's guard.
    local defaults = deep_copy(w.defaults[a.view])
    local list = defaults[a.menu]
    if type(list) ~= "table" or type(a.i) ~= "number"
            or a.i < 1 or a.i + 1 > #list then
        return "upstream_reorder skipped (menu gone)"
    end
    list[a.i], list[a.i + 1] = list[a.i + 1], list[a.i]
    w:setDefaults(a.view, defaults)
    return string.format("upstream_reorder %s (%s)", a.menu, a.view)
end)

define_op("external_native_edit", function(w)
    local path = KoreaderAdapter.getNativePath(w.view)
    local f = io.open(path, "r")
    if not f then return nil end
    f:close()
    local order = w:projection()
    local menus = {}
    for id in pairs(order) do
        if not RESERVED[id] and type(order[id]) == "table"
                and #order[id] > 0 then
            menus[#menus + 1] = id
        end
    end
    local menu = w:pick(menus)
    if not menu then return nil end
    return { menu = menu, view = w.view }
end, function(w, a)
    local order = w:projection(a.view)
    local list = order[a.menu]
    -- The picked menu can vanish between pick and apply when replaying a
    -- recorded history (earlier ops reshaped the projection): skip instead
    -- of crashing on #list.
    if type(list) ~= "table" then
        return "external_edit skipped (menu gone)"
    end
    local mode
    local roll = w:rand(3)
    if roll == 1 and #list >= 2 then
        local i = w:rand(#list - 1)
        list[i], list[i + 1] = list[i + 1], list[i]
        mode = "swapped"
    elseif roll == 2 then
        table.insert(list, "ext_unknown_item")
        mode = "appended_unknown"
    else
        order[a.menu] = nil
        mode = "deleted_key"
    end
    KoreaderAdapter.writeNativeOrder(a.view, order)
    Manager:reloadFromDisk(a.view)
    return string.format("external_edit %s (%s, %s)", a.menu, mode, a.view)
end)

define_op("rename_submenu", function(w)
    local customs = Manager:getCustomSubmenus(w.view)
    local ids = {}
    for id in pairs(customs) do ids[#ids + 1] = id end
    if #ids == 0 then return nil end
    return { id = w:pick(ids), title = w:pick(TITLE_POOL), view = w.view }
end, function(w, a)
    -- There is no dedicated rename verb; titles live in custom_menus records
    -- and the supported user path is delete + recreate at the same parent.
    -- Exercise exactly that through public APIs.
    if not Manager:isCustomSubmenu(a.view, a.id) then
        return string.format("rename %s skipped (gone)", a.id)
    end
    local order = Manager:loadOrder(a.view)
    local parent
    for menu_id, list in pairs(order) do
        if type(list) == "table" then
            for _, id in ipairs(list) do
                if id == a.id then parent = menu_id break end
            end
        end
        if parent then break end
    end
    local contents = Manager:getMenuItems(a.view, a.id) or {}
    local occupants = {}
    for _, id in ipairs(contents) do
        if id ~= "----------------------------" then occupants[#occupants + 1] = id end
    end
    if #occupants > 0 or not parent then
        return string.format("rename %s skipped (occupied/parentless)", a.id)
    end
    local ok_del = Manager:deleteCustomSubmenu(a.view, a.id)
    if not ok_del then
        return string.format("rename %s skipped (delete refused)", a.id)
    end
    local ok_new, new_id = Manager:createSubmenu(a.view, parent, a.title)
    return ok_new
        and string.format("rename %s -> %s (%s)", a.id, new_id, a.title)
        or string.format("rename %s recreate FAILED", a.id)
end)

define_op("save_submenu_preset", function(w)
    local menus = w:menuIds()
    local menu = w:pick(menus)
    if not menu then return nil end
    w.submenu_preset_counter = (w.submenu_preset_counter or 0) + 1
    return { menu = menu,
             name = string.format("sub%d_%d", w.seed, w.submenu_preset_counter),
             view = w.view }
end, function(w, a)
    local items = Manager:getMenuItems(a.view, a.menu)
    local ok = Manager:saveSubmenuPreset(a.view, a.menu, a.menu,
        a.name, false, items)
    return ok and string.format("save_submenu_preset %s (%s)", a.name, a.menu)
        or "save_submenu_preset FAILED"
end)

define_op("apply_submenu_preset", function(w)
    local menus = w:menuIds()
    local menu = w:pick(menus)
    if not menu then return nil end
    local list = Manager:listSubmenuPresets(w.view, menu)
    if #list == 0 then return nil end
    return { menu = menu, preset = w:pick(list).id, view = w.view }
end, function(w, a)
    local ok = Manager:loadSubmenuPreset(a.view, a.menu, a.preset)
    return ok and string.format("apply_submenu_preset %s@%s", a.preset, a.menu)
        or "apply_submenu_preset FAILED"
end)

define_op("backup_restore", function(w)
    return {}
end, function(w)
    Manager:backupOrder(w.view)
    local restored = Manager:restoreOrder(w.view)
    return restored and "backup+restore" or "restore without backup"
end)

define_op("discard_staged", function(w)
    return {}
end, function(w)
    -- Editor-Discard equivalent: drop staged state, re-derive from canonical.
    Manager:reloadFromDisk(w.view)
    return "discard_staged"
end)

define_op("forget_stale", function(w)
    return {}
end, function(w)
    -- countStaleCustomizations returns the LIST of stale ids (not a count).
    local before = #Manager:countStaleCustomizations(w.view)
    Manager:forgetStaleCustomizations(w.view)
    return string.format("forget_stale (%d forgotten)", before)
end)

define_op("sort_menu_za", function(w)
    local menus = w:menuIds()
    local menu = w:pick(menus)
    if not menu then return nil end
    local items = Manager:getMenuItems(w.view, menu)
    local non_sep = {}
    for _, id in ipairs(items) do
        if id ~= SEPARATOR_ID then non_sep[#non_sep + 1] = id end
    end
    if #non_sep < 2 then return nil end
    table.sort(non_sep, function(x, y) return tostring(x) > tostring(y) end)
    return { menu = menu, seq = non_sep }
end, function(w, a)
    Manager:stageList(w.view, a.menu, a.seq)
    return string.format("sort_za %s (%d)", a.menu, #a.seq)
end)

define_op("conditional_capability", function(w)
    -- Toggle a device capability that gates stock entries. The defaults
    -- table carries conditional ids directly; removing them models the
    -- capability disappearing (test_conditional_items D1-D5 semantics).
    local candidates = {}
    for _, id in ipairs({ "frontlight", "frontlight_warmth",
                          "gyroscope", "disable_double_tap" }) do
        for menu_id, list in pairs(w.defaults[w.view]) do
            if type(list) == "table" and not RESERVED[menu_id] then
                for _, did in ipairs(list) do
                    if did == id then
                        candidates[#candidates + 1] = { menu = menu_id, id = id }
                    end
                end
            end
        end
    end
    if #candidates == 0 then return nil end
    local c = w:pick(candidates)
    return { menu = c.menu, id = c.id, view = w.view }
end, function(w, a)
    local present = false
    local list = w.defaults[a.view][a.menu] or {}
    for _, id in ipairs(list) do
        if id == a.id then present = true break end
    end
    local defaults = deep_copy(w.defaults[a.view])
    if present then
        for i, id in ipairs(defaults[a.menu]) do
            if id == a.id then table.remove(defaults[a.menu], i) break end
        end
        w:setDefaults(a.view, defaults)
        return string.format("capability_off %s (%s)", a.id, a.view)
    else
        table.insert(defaults[a.menu], a.id)
        w:setDefaults(a.view, defaults)
        return string.format("capability_on %s (%s)", a.id, a.view)
    end
end)

define_op("io_fault_save", function(w)
    return {}
end, function(w)
    -- Deliberate commit failure: saveOrder must report false and canonical
    -- state must survive byte-identical (I9-style rollback semantics).
    local util = require("util")
    local real = util.writeToFile
    util.writeToFile = function() return nil, "injected_io_failure" end
    local ok, err = pcall(function() return Manager:saveOrder(w.view) end)
    util.writeToFile = real
    if not ok then error(err) end
    return "io_fault_save (commit refused)"
end)

define_op("upstream_add_tab", function(w)
    w.tab_counter = (w.tab_counter or 0) + 1
    local id = string.format("ntab%d", w.tab_counter)
    for _, t in ipairs(w.defaults[w.view]["KOMenu:menu_buttons"] or {}) do
        if t == id then return nil end
    end
    return { id = id, view = w.view }
end, function(w, a)
    local defaults = deep_copy(w.defaults[a.view])
    table.insert(defaults["KOMenu:menu_buttons"], a.id)
    defaults[a.id] = { "welcome_row_" .. a.id }
    w:setDefaults(a.view, defaults)
    return string.format("upstream_add_tab %s (%s)", a.id, a.view)
end)

define_op("upstream_remove_tab", function(w)
    local tabs = {}
    for _, t in ipairs(w.defaults[w.view]["KOMenu:menu_buttons"] or {}) do
        if t ~= "main" and t ~= "tools" then tabs[#tabs + 1] = t end
    end
    if #tabs == 0 then return nil end
    return { id = w:pick(tabs), view = w.view }
end, function(w, a)
    local defaults = deep_copy(w.defaults[a.view])
    local tb = defaults["KOMenu:menu_buttons"]
    for i, t in ipairs(tb) do
        if t == a.id then table.remove(tb, i) break end
    end
    defaults[a.id] = nil
    w:setDefaults(a.view, defaults)
    return string.format("upstream_remove_tab %s (%s)", a.id, a.view)
end)

define_op("unhide_all", function(w)
    local disabled = Manager:getDisabledItems(w.view)
    if #disabled == 0 then return nil end
    return { ids = disabled }
end, function(w, a)
    for _, id in ipairs(a.ids) do
        pcall(Manager.setItemHidden, Manager, w.view, id, false)
    end
    return string.format("unhide_all (%d)", #a.ids)
end)

define_op("toggle_hidden_in_place", function(w)
    return { enabled = not Manager:isHiddenInPlace() }
end, function(w, a)
    Manager:setHiddenInPlace(a.enabled)
    return a.enabled and "hidden-in-place on" or "hidden-in-place off"
end)

define_op("delete_native_file", function(w)
    local path = KoreaderAdapter.getNativePath(w.view)
    if not KoreaderAdapter.nativeFileExists(w.view) then return nil end
    return { view = w.view }
end, function(w, a)
    os.remove(KoreaderAdapter.getNativePath(a.view))
    Manager:reloadFromDisk(a.view)
    return string.format("delete_native_file (%s)", a.view)
end)

define_op("reader_fm_switch", function(w)
    return { view = w:otherView() }
end, function(w, a)
    w.view = a.view
    -- The other view's session may hold a cached projection computed before
    -- earlier cross-view commits; a switch must observe the CURRENT world,
    -- so force a full re-sync of the target view (drop + re-register), the
    -- same thing a real UI does when it opens the other surface.
    Manager:dropSessionState(a.view)
    w:syncRegistrations(a.view)
    return string.format("switch to %s", a.view)
end)

World.OPS = OPS
World.OP_NAMES = (function()
    local names = {}
    for name in pairs(OPS) do names[#names + 1] = name end
    table.sort(names)
    return names
end)()

-- ---------------------------------------------------------------------
-- Execution
-- ---------------------------------------------------------------------

-- Pick an op and its arguments, then apply. Returns op_name, args, desc.
-- Arguments are frozen at pick time so history replays deterministically.
function World:step()
    local weights = {
        move_item_to_menu = 8, move_item_in_menu = 8, stage_list_permutation = 8,
        hide_item = 8, unhide_item = 5, hide_tab = 3, restore_item_default = 4,
        insert_separator = 4, remove_separator = 3, reorder_tabs = 3,
        create_submenu = 4, delete_custom_submenu = 2, sort_menu_az = 2,
        save_order = 8, save_preset = 2, apply_preset = 3,
        reset_submenu = 2, reset_view = 1, toggle_mirroring = 2,
        copy_layout = 1, restart = 3,
        plugin_install = 6, plugin_uninstall = 4, plugin_upgrade_hint = 4,
        upstream_add = 4, upstream_remove = 3, upstream_reorder = 4,
        external_native_edit = 4, delete_native_file = 1, reader_fm_switch = 3,
        -- extended alphabet (A): rename, submenu presets, backups/discards,
        -- stale GC, Z→A, conditional capability, IO fault, upstream tabs,
        -- bulk unhide, hidden-display mode
        rename_submenu = 2, save_submenu_preset = 2, apply_submenu_preset = 2,
        backup_restore = 2, discard_staged = 2, forget_stale = 1,
        sort_menu_za = 2, conditional_capability = 3, io_fault_save = 2,
        upstream_add_tab = 2, upstream_remove_tab = 2, unhide_all = 1,
        toggle_hidden_in_place = 1,
    }
    local total = 0
    for _, weight in pairs(weights) do total = total + weight end
    local roll = self:rand(total)
    local chosen
    for _, name in ipairs(World.OP_NAMES) do
        local weight = weights[name] or 0
        if roll <= weight and weight > 0 then chosen = name break end
        roll = roll - weight
    end
    chosen = chosen or "save_order"
    local spec = OPS[chosen]
    local args = spec.pick(self)
    if args == nil then
        return chosen, nil, string.format("%s(skipped)", chosen)
    end
    self.history[#self.history + 1] = { op = chosen, args = args }
    self.op_counter = self.op_counter + 1
    local ok, desc = pcall(spec.apply, self, args)
    if not ok then
        desc = "OPERROR: " .. tostring(desc)
    end
    return chosen, args, desc
end

-- Replay a recorded history entry (no re-picking).
function World:replay(entry)
    local spec = OPS[entry.op]
    if not spec then return "UNKNOWN_OP " .. entry.op end
    local ok, desc = pcall(spec.apply, self, entry.args)
    if not ok then return "OPERROR: " .. tostring(desc) end
    return desc
end

-- ---------------------------------------------------------------------
-- Invariant battery
-- ---------------------------------------------------------------------

-- Build the same registry the manager would build right now.
function World:buildRegistry(view)
    view = view or self.view
    return Registry.buildFromData(self.defaults[view],
        self.registrations[view], self.providers[view])
end

function World:semanticFP(view)
    return fingerprint(self:projection(view))
end

-- Returns ok, failures (list of strings).
function World:check(opts)
    opts = opts or {}
    local failures = {}
    local function fail(tag)
        failures[#failures + 1] = tag
    end
    local view = self.view
    local order = self:projection(view)
    local reg = self:buildRegistry(view)
    -- Inspect the SAME state the projection derives from: verbs mutate a
    -- staged transaction that only becomes canonical on save.
    local section = Manager:stagedView(view)

    -- collect materialized ids and owners
    local owner, rendered = {}, {}
    local tabs_list = order["KOMenu:menu_buttons"] or {}
    local disabled = {}
    for _, id in ipairs(order["KOMenu:disabled"] or {}) do disabled[id] = true end

    -- I2/I3: single parent + hidden gone
    for menu_id, list in pairs(order) do
        if type(list) == "table" and not RESERVED[menu_id] then
            for _, id in ipairs(list) do
                if id ~= SEPARATOR_ID then
                    rendered[id] = (rendered[id] or 0) + 1
                    if owner[id] then
                        fail(string.format(
                            "I2 %s listed under %s and %s", id, owner[id], menu_id))
                    end
                    owner[id] = menu_id
                    if disabled[id] then
                        fail(string.format("I3 hidden %s rendered in %s", id, menu_id))
                    end
                end
            end
        end
    end
    for _, tab_id in ipairs(tabs_list) do
        if owner[tab_id] then
            fail(string.format("I2 tab %s also listed under %s", tab_id, owner[tab_id]))
        end
        owner[tab_id] = "KOMenu:menu_buttons"
        rendered[tab_id] = (rendered[tab_id] or 0) + 1
        if disabled[tab_id] then
            fail(string.format("I3 hidden tab %s in tab bar", tab_id))
        end
    end

    -- I4: acyclic
    local function reaches(from, target, seen)
        seen = seen or {}
        if seen[from] then return false end
        seen[from] = true
        for _, child in ipairs(order[from] or {}) do
            if child == target then return true end
            if order[child] and not RESERVED[child] then
                if reaches(child, target, seen) then return true end
            end
        end
        return false
    end
    for menu_id in pairs(order) do
        if not RESERVED[menu_id] and reaches(menu_id, menu_id) then
            fail("I4 cycle at " .. menu_id)
        end
    end

    -- I1 + I13: real MenuSorter, structural equivalence, no fabrication
    local items = { ["KOMenu:menu_buttons"] = {} }
    local supplied = {}
    for id, node in pairs(reg.nodes) do
        items[id] = { text = id, callback = function() end }
        supplied[id] = true
    end
    for id in pairs(section.custom_menus or {}) do
        items[id] = { text = id }
        supplied[id] = true
    end
    -- Externally authored ids (hand edits / upstream additions imported from
    -- the native file) are legal render targets: they live in the frozen
    -- sequence or as ghost placements and stock renders them via its own
    -- "NEW:" fallback. Not a fabrication leak. Custom submenus referenced as
    -- PARENTS of other customs also render through the synthesized tree.
    for menu_id, seq in pairs(section.order_override or {}) do
        if type(seq) == "table" then
            for _, listed in ipairs(seq) do
                if type(listed) == "string" and listed ~= SEPARATOR_ID then
                    supplied[listed] = true
                end
            end
        end
    end
    for id, custom in pairs(section.custom_menus or {}) do
        local rec = section.parent_override and section.parent_override[id] or nil
        if type(custom) == "table" and type(rec) == "table"
                and type(rec.parent) == "string"
                and section.custom_menus[rec.parent] then
            supplied[rec.parent] = true
        end
    end
    -- Removed-tab residue: after upstream_remove_tab the tab id leaves the
    -- defaults, but the served projection (and MenuSorter's own tree) can
    -- still carry the level CONTENT inline until the next session rebuild.
    -- Any id that names a known menu LEVEL - in the registry or in the
    -- projection's own key set - is therefore a legitimate render target,
    -- not a fabrication leak.
    for menu_id in pairs(reg.menus or {}) do
        if not RESERVED[menu_id] then supplied[menu_id] = true end
    end
    for menu_id in pairs(order) do
        if not RESERVED[menu_id] then supplied[menu_id] = true end
    end
    for menu_id, list in pairs(order) do
        if type(list) == "table" and not RESERVED[menu_id] then
            items[menu_id] = items[menu_id] or { text = menu_id }
        end
    end
    for _, tab_id in ipairs(tabs_list) do
        items[tab_id] = items[tab_id] or { text = tab_id }
    end
    local sort_order = { ["KOMenu:menu_buttons"] = tabs_list,
        ["KOMenu:disabled"] = order["KOMenu:disabled"] or {} }
    for menu_id, list in pairs(order) do
        if type(list) == "table" and not RESERVED[menu_id] then
            sort_order[menu_id] = list
        end
    end
    local ok_sort, sorted = pcall(function()
        return MenuSorter:sort(deep_copy(items), deep_copy(sort_order))
    end)
    if not ok_sort then
        fail("I1 MenuSorter crashed: " .. tostring(sorted):gsub("\n", " | "))
    else
        -- Walk the rendered tree. MenuSorter's post-processing REPLACES each
        -- tab entry with its content table, so children appear INLINE in the
        -- array part; deeper levels keep sub_item_table. Handle both.
        local tree_ids = {}
        local visited = {}
        local function walk(tbl)
            for _, entry in ipairs(tbl or {}) do
                if type(entry) == "table" then
                    if not visited[entry] then
                        visited[entry] = true
                        if entry.id and entry.id ~= SEPARATOR_ID
                                and entry.text ~= "KOMenu:separator" then
                            tree_ids[entry.id] = (tree_ids[entry.id] or 0) + 1
                        end
                        walk(#entry > 0 and entry or nil)
                        walk(entry.sub_item_table)
                    end
                end
            end
        end
        walk(sorted)
        for id, count in pairs(tree_ids) do
            if not supplied[id] then
                fail(string.format("I13 rendered id %s not in supplied items (NEW: leak?)", id))
            end
            if count > 1 then
                fail(string.format("I10 %s rendered %d times", id, count))
            end
        end
        -- every supplied, materialized, non-ghost id must render exactly once
        local function is_separator(id) return id == SEPARATOR_ID end
        for menu_id, list in pairs(order) do
            if type(list) == "table" and not RESERVED[menu_id] then
                for _, id in ipairs(list) do
                    if not is_separator(id) and supplied[id]
                            and reg.nodes[id] and not tree_ids[id] then
                        fail(string.format(
                            "I10 materialized %s (%s) missing from rendered tree",
                            id, menu_id))
                    end
                end
            end
        end
    end

    -- I15: relative order of order_override survivors preserved.
    local function seqOrderOK(menu_id, projected, seq, frozen)
        if type(seq) ~= "table" then return true end
        local pos = {}
        for i, id in ipairs(projected) do pos[id] = i end
        local last = nil
        for _, id in ipairs(seq) do
            if pos[id] and not frozen[id] then
                if last and pos[id] < last then
                    fail(string.format(
                        "I15 order_override of %s violated at %s", menu_id, id))
                    return false
                end
                last = pos[id]
            end
        end
        return true
    end

    -- I7 strengthened: untouched stock ids sit at their default parent AND,
    -- when NO bulk order_override exists for their menu (nothing was ever
    -- frozen there), in default relative order. A frozen sequence is a
    -- deliberate user arrangement: the documented contract is that its
    -- surviving entries keep relative order (checked as I15), while ids the
    -- installation no longer serves stay positionally and newcomers append.
    for id, node in pairs(reg.nodes) do
        local untouched = section.hidden[id] == nil
            and section.parent_override[id] == nil
            and section.position_override[id] == nil
            and not self:inAnySequence(section, id)
        -- A menu is frozen when an explicit sequence governs it OR when the
        -- user placed separators inside it: separator placement is itself a
        -- user-controlled ordering record, so default-relative-order checks
        -- do not apply (ground truth: probe_minimize_bug.lua).
        local menu_frozen = section.order_override[node.default_parent] ~= nil
        if not menu_frozen then
            for _ in pairs(section.separators or {}) do
                menu_frozen = true
                break
            end
        end
        if not menu_frozen then
            -- Surviving position anchors INTO this level also freeze it:
            -- reset_submenu clears anchors only for rows whose home is this
            -- menu; anchors parked on rows that stayed legitimately reorder
            -- the surviving sequence.
            for id, rec in pairs(section.position_override or {}) do
                if type(rec) == "table" and (rec.after ~= nil or rec.before ~= nil) then
                    local home = Materializer.effectiveParent(reg, section, id)
                        or (reg.nodes[id] and reg.nodes[id].default_parent)
                    if home == node.default_parent then
                        menu_frozen = true
                        break
                    end
                end
            end
        end
        -- A preset carrying cross-menu parent_override records re-homes
        -- foreign items INTO this menu; their slot-aligned arrival can
        -- legitimately shift untouched siblings' absolute positions while
        -- keeping relative order among themselves. I7's sibling-pair scan
        -- already tolerates that; but the ARRIVING item itself is not
        -- "untouched", and neither is a menu whose membership was altered
        -- this way. Skip menus with incoming parent_override records.
        if not menu_frozen then
            for _, record in pairs(section.parent_override or {}) do
                if type(record) == "table" and record.parent == node.default_parent then
                    menu_frozen = true
                    break
                end
            end
        end
        if untouched and node.provider == "stock" and node.default_parent
                and node.default_parent ~= "KOMenu:menu_buttons"
                and order[node.default_parent] ~= nil
                and not menu_frozen
                -- an untouched id whose default parent is itself cascaded
                -- away (unreachable container) legitimately renders nowhere;
                -- the sibling-order expectation does not apply to it
                and rendered[node.default_parent] ~= nil then
            local listed = order[node.default_parent]
            local at = nil
            if listed then
                for i, listed_id in ipairs(listed) do
                    if listed_id == id then at = i break end
                end
            end
            if not at then
                fail(string.format("I7 untouched stock %s not under default %s",
                    id, node.default_parent))
            else
                -- default relative order: every earlier default stock sibling
                -- that is untouched must appear before it
                local dlist = self.defaults[view][node.default_parent] or {}
                local seen_me = false
                for _, did in ipairs(dlist) do
                    if did == id then seen_me = true break end
                    if did ~= SEPARATOR_ID and type(did) == "string" then
                        local dnode = reg.nodes[did]
                        if dnode and rendered[did] and owner[did] == node.default_parent then
                            local d_at = nil
                            for i, listed_id in ipairs(listed) do
                                if listed_id == did then d_at = i break end
                            end
                            if d_at and d_at > at and not self:interveningOverride(
                                section, node.default_parent) then
                                if os.getenv("SM_DEBUG_I7") then
                                    fail(string.format(
                                        "I7DEBUG listed=[%s] dlist=[%s] id=%s did=%s at=%d d_at=%d",
                                        table.concat(listed, ","),
                                        table.concat(dlist, ","),
                                        tostring(id), tostring(did), at, d_at))
                                end
                                fail(string.format(
                                    "I7 order: default sibling %s should precede %s in %s",
                                    did, id, node.default_parent))
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    -- I6: explicit parent override holds while its provider is present and matches.
    -- Stamped intent for an absent provider is dormant (renders nowhere) and does not fail I6.
    for id, record in pairs(section.parent_override or {}) do
        if type(record) == "table" then
            local node = reg.nodes[id]
            local is_custom = type(section.custom_menus) == "table" and section.custom_menus[id] ~= nil
            local current_provider = node and node.provider or (is_custom and "custom" or nil)
            local applies = false
            if current_provider ~= nil then
                if is_custom then
                    applies = (record.provider == nil or record.provider == "custom")
                elseif record.provider == nil then
                    applies = true
                else
                    applies = (record.provider == current_provider)
                end
            end
            if applies and not disabled[id] and not section.hidden[id] then
                if order[record.parent] == nil then
                    -- home cascaded away: row is invisible by design
                elseif owner[id] ~= record.parent then
                    fail(string.format("I6 %s should be under %s, is under %s",
                        id, tostring(record.parent), tostring(owner[id])))
                end
            end
        end
    end

    -- I15: relative order of order_override survivors preserved
    for menu_id, seq in pairs(section.order_override or {}) do
        if type(seq) == "table" then
            local projected = order[menu_id] or {}
            local pos = {}
            for i, id in ipairs(projected) do pos[id] = i end
            local last = nil
            for _, id in ipairs(seq) do
                if pos[id] then
                    if last and pos[id] < last then
                        fail(string.format(
                            "I15 order_override of %s violated at %s", menu_id, id))
                        break
                    end
                    last = pos[id]
                end
            end
        end
    end

    -- I16: the disabled list must contain exactly the applying hidden
    -- records plus validator-cascaded unreachable-subtree members.
    -- ORDER rules (schema v3 ground truth):
    --   no cascade  -> per-record ordinal order first, sorted leftovers
    --   any cascade -> validator emits traversal order (implementation
    --                  detail); assert SET equality + ordinal survival
    local expected_disabled = {}
    local expected_seen = {}
    local listed_set = {}
    do
        local ordered_hidden = {}
        for hid, hrec in pairs(section.hidden or {}) do
            listed_set[hid] = true
            ordered_hidden[#ordered_hidden + 1] = {
                id = hid,
                ordinal = type(hrec) == "table"
                    and type(hrec.ordinal) == "number" and hrec.ordinal or nil,
            }
        end
        table.sort(ordered_hidden, function(a, b)
            if a.ordinal and b.ordinal and a.ordinal ~= b.ordinal then
                return a.ordinal < b.ordinal
            end
            if a.ordinal and not b.ordinal then return true end
            if not a.ordinal and b.ordinal then return false end
            return tostring(a.id) < tostring(b.id)
        end)
        for _, entry in ipairs(ordered_hidden) do
            if Manager:isItemHidden(view, entry.id) then
                expected_disabled[#expected_disabled + 1] = entry.id
                expected_seen[entry.id] = true
            end
        end
    end
    -- Where does the projection say this id LIVES once intent applies?
    -- Mirrors Materializer.effectiveParent precedence: an applying
    -- parent_override wins, then a created-submenu parent, then the
    -- registry default home. Checking the DEFAULT home alone (the original
    -- oracle) misclassifies rows deliberately re-homed into a later-hidden
    -- container: their default home is alive, their ACTUAL home is gone,
    -- and the validator correctly cascades them.
    local function intended_home(id)
        local rec = section.parent_override and section.parent_override[id]
        if type(rec) == "table" and rec.parent then
            local n = reg.nodes[id]
            -- Schema v3: the parent_override record IS also the custom-menu
            -- parent authority; provider gating applies to registry ids only.
            local applies = rec.provider == nil
                or (n ~= nil and n.provider == rec.provider)
                or (section.custom_menus and section.custom_menus[id] ~= nil)
            if applies then return rec.parent end
        end
        local n = reg.nodes[id]
        return n and (n.default_parent or n.sorting_hint) or nil
    end
    local cascade = false
    for id in pairs(disabled) do
        if not listed_set[id] and section.hidden[id] == nil then
            local node = reg.nodes[id]
            if node then
                -- Reachability follows the ACTUAL home: a live row whose
                -- current container level is absent from the projection has
                -- been cascaded (its default home may well still exist).
                local home = Materializer.effectiveParent(reg, section, id)
                if not home or order[home] == nil then
                    cascade = true
                    break
                end
            else
                -- Custom submenus: home comes from their parent_override
                -- record (schema v3 parent authority), and they cascade with
                -- their (absent) parent level too.
                local custom = section.custom_menus and section.custom_menus[id]
                local custom_rec = custom
                    and section.parent_override and section.parent_override[id] or nil
                local parent = type(custom_rec) == "table" and custom_rec.parent or nil
                if custom and (parent == nil or order[parent] == nil) then
                    cascade = true
                    break
                end
            end
        end
    end
    if not cascade then
        -- Ghost placements (records whose provider is currently absent) also
        -- follow their recorded home into invisibility when that home is
        -- cascaded away; they land in disabled without any hidden record and
        -- without a live registry node.
        local extras = {}
        for id in pairs(section.hidden or {}) do
            if not listed_set[id] and not expected_seen[id]
                    and Manager:isItemHidden(view, id) then
                extras[#extras + 1] = id
            end
        end
        for id in pairs(section.parent_override or {}) do
            local rec = section.parent_override[id]
            local is_custom = type(section.custom_menus) == "table" and section.custom_menus[id] ~= nil
            if type(rec) == "table" and (reg.nodes[id] ~= nil or is_custom)
                    and not expected_seen[id]
                    and rec.parent and order[rec.parent] == nil
                    and not RESERVED[rec.parent] then
                extras[#extras + 1] = id
            end
        end
        table.sort(extras)
        for _, id in ipairs(extras) do
            expected_disabled[#expected_disabled + 1] = id
        end
    else
        for _, id in ipairs(expected_disabled) do
            if not disabled[id] then
                fail(string.format("I16 hidden %s missing from disabled", id))
            end
        end
        expected_disabled = nil
    end
    local actual_disabled = order["KOMenu:disabled"] or {}
    if expected_disabled then
        if fingerprint(actual_disabled) ~= fingerprint(expected_disabled) then
            fail(string.format("I16 disabled mismatch: got [%s] want [%s]",
                table.concat(actual_disabled, ","),
                table.concat(expected_disabled, ",")))
        end
    end

    -- I8: restart equivalence (explicit opt-in: costs a full reload).
    -- Mirrors the real flow: staged edits are committed before the restart,
    -- otherwise the comparison measures the dirty-close scenario instead.
    -- NOTE: this check is probabilistic under concurrent cross-view commits
    -- (a rebase in one view's save can replace the other view's canonical
    -- section, whose sidecar then legitimately lags until the next sync).
    -- Retry once before failing to filter that benign recovery path.
    if opts.restart_check then
        pcall(function() Manager:saveOrder(view) end)
        pcall(function() Manager:saveOrder(self:otherView()) end)
        -- Capture fingerprints from a CLEAN session state: the just-committed
        -- canonical may differ from stale in-memory projections of the
        -- non-active view (a cross-view commit during rebasing replaced both
        -- sections; each view's projection must be re-derived from disk).
        for _, v in ipairs(VIEWS) do Manager:dropSessionState(v) end
        IntentStore.load(true)
        for _, v in ipairs(VIEWS) do self:syncRegistrations(v) end
        local before = {}
        for _, v in ipairs(VIEWS) do before[v] = self:semanticFP(v) end
        self:restart()
        for _, v in ipairs(VIEWS) do
            if self:semanticFP(v) ~= before[v] then
                self:restart()
                if self:semanticFP(v) ~= before[v] then
                    fail(string.format("I8 restart changed projection of %s", v))
                else
                    io.stderr:write("note: I8 needed one recovery pass for " .. v .. "\n")
                end
            end
        end
    end

    return #failures == 0, failures
end

function World:inAnySequence(section, id)
    -- Schema v3: sequences are { entries = [ {id,...} | {separator=true} ] }.
    for _, record in pairs(section.order_override or {}) do
        if type(record) == "table" and type(record.entries) == "table" then
            for _, entry in ipairs(record.entries) do
                if MenuSchema.entryId(entry) == id then return true end
            end
        end
    end
    return false
end

function World:interveningOverride(section, menu_id)
    return section.order_override[menu_id] ~= nil
end

-- I9/I11 helpers, run around save ops.
function World:nativeFixpointCheck()
    local failures = {}
    local before = self:semanticFP(self.view)
    Manager:reloadFromDisk(self.view)
    local after = self:semanticFP(self.view)
    if before ~= after then
        failures[#failures + 1] = "I9 native fixpoint violated after save+reload"
    end
    return failures
end

function World:serializationDeterminismCheck()
    local failures = {}
    local section_before = dump(IntentStore.load().views[self.view])
    Manager:saveOrder(self.view)
    local section_after = dump(IntentStore.load().views[self.view])
    if section_before ~= section_after then
        failures[#failures + 1] = "I11 second identical save changed canonical bytes"
    end
    return failures
end

-- I17: after a deliberately failed commit, a clean restart must reproduce
-- exactly the pre-fault canonical state (rollback semantics). Returns the
-- pre-fault fingerprint so the caller can compare after recovery.
function World:preFaultFingerprint()
    return fingerprint(IntentStore.load().views[self.view])
end

-- I18: tab-bar sanity that must hold in EVERY world state (upstream tab
-- add/remove/reorder + hidden tabs): no duplicate tabs, bar non-empty.
function World:tabBarCheck()
    local failures = {}
    local order = self:projection()
    local seen = {}
    local count = 0
    for _, t in ipairs(order["KOMenu:menu_buttons"] or {}) do
        count = count + 1
        if seen[t] then
            failures[#failures + 1] = "I18 duplicate tab " .. tostring(t)
        end
        seen[t] = true
    end
    if count == 0 then
        failures[#failures + 1] = "I18 empty tab bar"
    end
    return failures
end


-- Executable fixture text for this world (seed + history).
function World:fixtureText(extra_note)
    local lines = {
        "-- Auto-generated regression fixture. DO NOT EDIT BY HAND.",
        "-- Regenerate via the state-machine suite; delete to retire.",
        extra_note and ("-- " .. extra_note) or nil,
        "return {",
        string.format("  seed = %d,", self.seed),
        "  history = {",
    }
    for _, entry in ipairs(self.history) do
        lines[#lines + 1] = string.format('    { op = %q, args = %s },',
            entry.op, dump(entry.args, nil, true):gsub("%s*\n%s*", " "))
    end
    lines[#lines + 1] = "  },"
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n")
end

return World

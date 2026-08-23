--[[--
koreader_adapter.lua — every KOReader-specific surface in one place.

Isolated here so the rest of the architecture stays testable and free of
KOReader internals:

  - stock default menu orders (frontend/ui/elements/*_menu_order.lua)
  - native user override files (*_menu_order.lua in the settings directory)
  - collection of live plugin/widget menu registrations, including the
    provider identity each registration is attributed to
  - the MenuSorter compatibility guards (orphaned sorting hints, custom
    submenu synthesis)
  - live menu rebuild after configuration changes
--]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local MenuSchema = require("reorderingmenus_menu_schema")
local util = require("util")

local AtomicWriter = require("reorderingmenus_atomic_writer")

local KoreaderAdapter = {}
local SEPARATOR_ID = MenuSchema.SEPARATOR_ID
local MENU_BUTTONS_KEY = MenuSchema.MENU_BUTTONS_KEY
local DISABLED_KEY = MenuSchema.DISABLED_KEY
local CUSTOM_SUBMENUS_KEY = MenuSchema.CUSTOM_SUBMENUS_KEY

function KoreaderAdapter.getSettingsDir()
    return DataStorage:getSettingsDir()
end

-- -------------------------------------------------------------------------
-- Stock defaults
-- -------------------------------------------------------------------------

local default_orders = {}
local defaults_revision = {}
-- Pristine snapshots: MenuSorter.mergeAndSort overlays user keys onto the
-- shared elements module table, permanently polluting package.loaded.
-- Baselines must therefore come from an untouched copy captured at first
-- load, or sparse emission would gradually treat its own output as stock.
local pristine_defaults = {}

function KoreaderAdapter.getDefaultsRevision(view)
    if not defaults_revision[view] then
        KoreaderAdapter.getDefaultOrder(view)
    end
    return defaults_revision[view]
end

function KoreaderAdapter.getDefaultOrder(view, force_reload)
    if default_orders[view] and not force_reload then
        return util.tableDeepCopy(default_orders[view])
    end
    local loaded
    local ok, res = pcall(dofile, string.format("frontend/ui/elements/%s_menu_order.lua", view))
    if ok and type(res) == "table" then
        loaded = res
    else
        local req_ok, req_res = pcall(require, string.format("ui/elements/%s_menu_order", view))
        if req_ok and type(req_res) == "table" then loaded = req_res end
    end
    if not loaded then
        logger.warn("ReorderingMenus: cannot load default menu order for", view)
        loaded = {
            [MenuSchema.MENU_BUTTONS_KEY] = {},
            [MenuSchema.DISABLED_KEY] = {},
        }
    end
    if not pristine_defaults[view] then
        -- Capture the untouched baseline once; later reads of the shared
        -- module may already carry mergeAndSort overlay pollution.
        pristine_defaults[view] = util.tableDeepCopy(loaded)
    end
    default_orders[view] = util.tableDeepCopy(pristine_defaults[view])
    defaults_revision[view] = (defaults_revision[view] or 0) + 1
    return util.tableDeepCopy(default_orders[view])
end

-- -------------------------------------------------------------------------
-- Native user override files
-- -------------------------------------------------------------------------

function KoreaderAdapter.getNativePath(view)
    return string.format("%s/%s_menu_order.lua", KoreaderAdapter.getSettingsDir(), view)
end

function KoreaderAdapter.readNativeOrder(view)
    local path = KoreaderAdapter.getNativePath(view)
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local ok, res = pcall(dofile, path)
    if ok and type(res) == "table" then return util.tableDeepCopy(res) end
    logger.warn("ReorderingMenus: failed to load native user order:", path, res)
    return nil
end

-- Distinguishes "no file at all" (a deliberate deletion / full revert) from
-- "file exists but is unreadable or malformed" (a crashed or interrupted
-- write, external corruption). Recovery policies differ: a missing file
-- reverts to stock; a corrupt one must be regenerated from canonical intent,
-- never treated as a revert.
function KoreaderAdapter.nativeFileExists(view)
    return AtomicWriter.fileExists(KoreaderAdapter.getNativePath(view))
end

-- Shape check for a parsed native order file before an atomic write commits.
local function validNativeShape(tbl)
    for key, value in pairs(tbl) do
        if type(key) ~= "string" or type(value) ~= "table" then return false end
        for _, entry in ipairs(value) do
            if type(entry) ~= "string" then return false end
        end
    end
    return true
end

function KoreaderAdapter.writeNativeOrder(view, order_table)
    local path = KoreaderAdapter.getNativePath(view)
    local ok, err = AtomicWriter.writeTable(path, order_table, validNativeShape)
    if not ok then
        logger.err("ReorderingMenus: failed writing native order:", path, err)
        return false, err
    end
    return true, path
end

function KoreaderAdapter.removeNativeOrder(view)
    local path = KoreaderAdapter.getNativePath(view)
    if not lfs.attributes(path) then return true end
    local ok, err = os.remove(path)
    if not ok then
        logger.err("ReorderingMenus: failed removing native order:", path, err)
        return false, err
    end
    return true
end

function KoreaderAdapter.isCustomized(view)
    return lfs.attributes(KoreaderAdapter.getNativePath(view), "mode") == "file"
end

-- True when the id belongs to the PERSISTENT stock layout. Deliberately
-- bypasses any injected/test defaults: membership here is what lets the
-- intent store stay sparse for ordinary stock rows.
function KoreaderAdapter.isStockResident(view, id)
    local defaults = KoreaderAdapter.getDefaultOrder(view)
    if id == "reordering_menus" then return false end
    for menu_id, list in pairs(defaults) do
        if menu_id ~= MenuSchema.MENU_BUTTONS_KEY
                and menu_id ~= MenuSchema.DISABLED_KEY
                and type(list) == "table" then
            for _, listed in ipairs(list) do
                if listed == id then return true end
            end
        end
    end
    return false
end

function KoreaderAdapter.invalidateNativeModuleCache()
    package.loaded["ui/elements/reader_menu_order"] = nil
    package.loaded["ui/elements/filemanager_menu_order"] = nil
end

-- -------------------------------------------------------------------------
-- Live registrations
-- -------------------------------------------------------------------------

-- Ask every registered widget what it would contribute to the main menu and
-- attribute each contributed id to its provider. Ids already present in the
-- stock defaults always count as "stock" (core widgets also register through
-- the same mechanism); everything else belongs to the registering widget,
-- identified by its container name -> "plugin:<name>".
--
-- Collision policy: when several widgets contribute the SAME id, attribution
-- must never depend on pairs() iteration order. The lexicographically
-- smallest widget name wins deterministically, the collision is reported on
-- the registration record (registry marks such nodes; reconciliation refuses
-- to pin them), and a warning is logged. Provider-stamped customization of
-- one contributor can therefore never migrate to the other.
function KoreaderAdapter.collectLiveRegistrations(ui)
    local registrations = {}
    local providers = {}
    local contributors = {}
    local menu = ui and ui.menu
    local widgets = menu and menu.registered_widgets or {}
    for _, widget in pairs(widgets) do
        local name = type(widget) == "table" and widget.name or nil
        if widget and type(widget.addToMainMenu) == "function" then
            local ok = pcall(function()
                local captured = {}
                widget:addToMainMenu(captured)
                for id, item in pairs(captured) do
                    if KoreaderAdapter.isInReservedNamespace(id) then
                        logger.warn("ReorderingMenus: quarantined contribution",
                            tostring(id), "from", tostring(name),
                            "- ids under", NAMESPACE_PREFIX, "are reserved")
                    elseif name then
                        local widget_name = tostring(name)
                        -- Deterministic attribution: the lexicographically
                        -- smallest contributor owns every attribute of the
                        -- shared id (provider AND sorting_hint), so the
                        -- derived world never depends on pairs() order.
                        local known = contributors[id]
                        if not known then
                            contributors[id] = {
                                min = widget_name,
                                hint = type(item) == "table"
                                    and item.sorting_hint or nil,
                                colliding = { [widget_name] = true },
                            }
                            providers[id] = widget_name
                        else
                            known.colliding[widget_name] = true
                            if widget_name < known.min then
                                known.min = widget_name
                                known.hint = type(item) == "table"
                                    and item.sorting_hint or nil
                                providers[id] = widget_name
                            end
                        end
                    end
                    if not registrations[id] then
                        registrations[id] = {
                            id = id,
                            sorting_hint = type(item) == "table"
                                and item.sorting_hint or nil,
                        }
                    end
                end
            end)
            if not ok then
                logger.warn("ReorderingMenus: failed collecting registrations from", tostring(name))
            end
        end
    end
    -- Re-apply the winning hints after collection (registration rows were
    -- seeded by first sight; the deterministic minimum must win).
    for id, known in pairs(contributors) do
        if registrations[id] then
            registrations[id].sorting_hint = known.hint
        end
    end
    -- Colliding ids: contributors whose value carries a LIST of widget names
    -- with more than one entry. (The value is { min, hint }; a single
    -- contributor must never be mistaken for a collision.)
    for id, names in pairs(contributors) do
        local count = 0
        for _ in pairs(names.colliding or {}) do count = count + 1 end
        if count > 1 then
            registrations[id].colliding_providers = {}
            for widget_name in pairs(names.colliding) do
                table.insert(registrations[id].colliding_providers, widget_name)
            end
            table.sort(registrations[id].colliding_providers)
            logger.warn("ReorderingMenus: menu id", id, "contributed by multiple widgets:",
                table.concat(registrations[id].colliding_providers, ", "),
                "- attributing to", providers[id])
        end
    end
    return registrations, providers
end

-- Resolve the provider identity for one item id given live attribution data.
function KoreaderAdapter.resolveProvider(id, defaults, providers)
    local default_menus = type(defaults) == "table" and defaults or {}
    for _menu_id, list in pairs(default_menus) do
        if type(list) == "table" then
            for _, listed_id in ipairs(list) do
                if listed_id == id then return "stock" end
            end
        end
    end
    local widget_name = providers and providers[id] or nil
    if widget_name then return "plugin:" .. tostring(widget_name) end
    return nil
end

-- -------------------------------------------------------------------------
-- MenuSorter compatibility guards
-- -------------------------------------------------------------------------

KoreaderAdapter.SEPARATOR_ID = SEPARATOR_ID

-- The plugin's RESERVED ID NAMESPACE. No live widget contribution, external
-- hand edit, or preset may claim an id under this prefix: it is reserved for
-- structures this plugin itself synthesizes (namespaced user submenus). A
-- foreign id under the prefix would collide with plugin bookkeeping and
-- could smuggle unvalidated content through the custom-submenu synthesis
-- path, so it is quarantined at every ingestion point.
local NAMESPACE_PREFIX = "reorderingmenus:"
KoreaderAdapter.NAMESPACE_PREFIX = NAMESPACE_PREFIX

local function getMenuSorter()
    local ok, sorter = pcall(require, "ui/menusorter")
    if ok and type(sorter) == "table" and type(sorter.sort) == "function" then
        return sorter
    end
    return nil
end

local function withRemovedOrderKey(order, key, callback)
    local value = order[key]
    order[key] = nil
    local result = { pcall(callback) }
    order[key] = value
    if not result[1] then error(result[2], 0) end
    return unpack(result, 2)
end

function KoreaderAdapter.isInReservedNamespace(id)
    return type(id) == "string" and id:sub(1, #NAMESPACE_PREFIX) == NAMESPACE_PREFIX
end

-- Classification of one orphan item's sorting_hint target against the world
-- stock MenuSorter is about to render. Returns one of:
--
--   "reachable_container" : hint names a menu that WILL be placed as a live
--                           container in this build - present in the order
--                           graph AND supplied by item_table (or about to be
--                           synthesized for a referenced custom submenu).
--                           Stock attaches the orphan under it. Safe.
--   "reachable_leaf"      : hint names a PLACED non-container id. Stock
--                           silently swallows the orphan INTO the leaf's
--                           array part (invisible corruption: the row never
--                           renders where the provider intended). Treated as
--                           unsafe -> strip.
--   "separator"           : hint == the separator id; stock crashes
--                           (findById yields nil -> index nil).
--   "disabled"            : hint names an id in KOMenu:disabled that is not
--                           also a live container. Stock crashes; the item
--                           follows its hidden target into invisibility.
--   "stale_container"     : order[hint] survives from a previous shape but
--                           NO provider supplies the item this build (shape
--                           change / uninstalled provider / hand edit).
--                           Trusting the order row here is fatal: if the
--                           item is truly absent, stock crashes mid-orphan-
--                           loop (and the airbag cannot recover - its retry
--                           input was already consumed); if the item arrives
--                           as a leaf, the stale row silently reshapes it
--                           into an empty submenu. Neutralized like missing.
--   "missing"             : hint names nothing in the rendered world (or is
--                           not even a string). Stock crashes.
--
-- Only "reachable_container" is left untouched; every other class is
-- neutralized by the guard below BEFORE stock code can crash or misplace.
--
-- item_table is optional (tests may omit it); when absent, order-row trust
-- degrades to the historical behavior for that one query.
function KoreaderAdapter.classifyHintTarget(hint, order, self_id, item_table)
    if type(hint) ~= "string" or hint == "" then
        return "missing", "non-string or empty hint"
    end
    if hint == SEPARATOR_ID then return "separator" end

    -- Referenced custom submenus will be synthesized into item_table by
    -- installCustomSubmenuGuard before stock runs; they count as live.
    local custom_registry = order[CUSTOM_SUBMENUS_KEY]
    local function willBeLiveContainer(id)
        if type(item_table) == "table" and item_table[id] ~= nil then
            return true
        end
        return type(custom_registry) == "table"
            and custom_registry[id] ~= nil
            and type(order[id]) == "table"
    end

    local disabled = {}
    for _, id in ipairs(order[DISABLED_KEY] or {}) do
        disabled[id] = true
    end

    -- Walk the bar through the order graph collecting every menu id that
    -- will exist as a container, and every id placed inside one.
    local reachable_containers = {}
    local stale_rows = {}
    local listed = {}
    local function mark(list)
        for _, id in ipairs(list or {}) do
            if type(id) == "string" then
                listed[id] = true
                if disabled[id] then disabled[id] = nil end -- placed wins over disabled listing
                if order[id] ~= nil and not reachable_containers[id]
                        and not stale_rows[id] then
                    if willBeLiveContainer(id) then
                        reachable_containers[id] = true
                        mark(order[id])
                    else
                        -- Order row without a live item: previous shape's
                        -- residue. Do NOT recurse through it and do NOT
                        -- count it as a valid hint target.
                        stale_rows[id] = true
                    end
                end
            end
        end
    end
    mark(order[MENU_BUTTONS_KEY])

    -- An item that is itself listed somewhere will be consumed by the
    -- placement loop before orphan handling ever runs: its hint is inert.
    -- (Deleting such an item would strip a deliberately MOVED row out of
    -- its new home - see test_user_plugin_tab_hiding Bug 1c.)
    if self_id ~= nil and listed[self_id] then
        return "placed", self_id
    end
    if reachable_containers[hint] then return "reachable_container" end
    -- Stale rows must win over the generic "listed" verdict: a stale id is
    -- by definition listed SOMEWHERE (its old parent row survived), but the
    -- item behind it will never render this build - the precise diagnosis
    -- matters for logs, and both cases are neutralized anyway.
    if stale_rows[hint] then return "stale_container", hint end
    if listed[hint] then return "reachable_leaf" end
    if disabled[hint] then return "disabled" end
    return "missing", hint
end

-- MenuSorter crashes when an orphaned item's sorting_hint points at a menu
-- that does not exist in the rendered tree (typically because this plugin
-- hides the hinted tab). Items whose hint target is hidden stay hidden;
-- items pointing at an unknown menu fall back to stock orphan handling.
function KoreaderAdapter.installSortingHintGuard()
    local MenuSorter = getMenuSorter()
    if not MenuSorter then return false end
    if MenuSorter.reordering_menus_hint_guard then return true end

    -- Provider metadata vault (weak-keyed by entry table): when a build has
    -- to neutralize an unusable sorting_hint, the ORIGINAL value is kept so
    -- a later build can restore and re-evaluate it. Providers that reuse one
    -- entry table across builds must not lose their intent for the whole
    -- process just because the target was unreachable at some point - once
    -- the target becomes valid again, the item follows its hint again.
    local stripped_hints = setmetatable({}, { __mode = "k" })

    local orig_sort = MenuSorter.sort
    MenuSorter.sort = function(self, item_table, order)
        if type(item_table) == "table" and type(order) == "table" then
            pcall(function()
                for id, item in pairs(item_table) do
                    local hint = type(item) == "table"
                        and (item.sorting_hint or stripped_hints[item])
                    if hint ~= nil and id ~= MENU_BUTTONS_KEY
                            and not order[id] then
                        -- Only orphans (unplaced items) reach the guarded
                        -- branch of stock sort; placed rows never consult
                        -- their hint again. item_table is passed so the
                        -- classifier can tell a LIVE container from a stale
                        -- order row left behind by a provider shape change.
                        -- A restored-from-vault hint is judged fresh: if the
                        -- target healed, provider intent flows again; if not,
                        -- the value goes back into the vault.
                        item.sorting_hint = hint
                        local klass = KoreaderAdapter.classifyHintTarget(
                            hint, order, id, item_table)
                        if klass ~= "reachable_container"
                                and klass ~= "placed" then
                            logger.warn("ReorderingMenus: neutralized",
                                tostring(klass), "sorting_hint on", tostring(id))
                            item.sorting_hint = nil
                            if item.sorting_hint == nil and hint ~= nil then
                                stripped_hints[item] = hint
                            end
                            if klass == "disabled" then
                                -- Follow its hidden target into invisibility:
                                -- stock drops ids listed in KOMenu:disabled.
                                item_table[id] = nil
                            end
                        else
                            stripped_hints[item] = nil
                        end
                    end
                end
            end)
        end
        return orig_sort(self, item_table, order)
    end
    MenuSorter.reordering_menus_hint_guard = true
    return true
end

-- Last-resort airbag around MenuSorter:sort. Every guard above neutralizes a
-- KNOWN hazard class; this catches anything they missed (a new upstream
-- shape, an exotic hand edit). A failed sort would otherwise take down the
-- whole menu build and, on some paths, KOReader itself; instead the menu is
-- rebuilt once from a sanitized shallow copy of the inputs (hints stripped,
-- non-table entries dropped) and only if that also fails does the airbag
-- re-raise. The original item_table is never mutated by sanitization.
-- Retry-input construction for the airbag. stock sort() CONSUMES placed
-- references from item_table as it walks the order (item_table[id] = nil);
-- a crash mid-walk leaves the table half-consumed, and it also leaks
-- orderedPairs' __orderedIndex scratch array onto it. A retry built from the
-- crashed table would therefore silently drop every item placed before the
-- fault and ingest debris as fake rows (both observed empirically). The
-- airbag snapshots item_table BEFORE the first pass and rebuilds the retry
-- input from that snapshot: original references restored, run debris
-- dropped, entries synthesized during the run (custom-submenu synthesis)
-- kept.
local function sanitizeForRetry(snapshot, item_table, order)
    local clean_items = {}
    for id, item in pairs(snapshot) do
        if type(id) == "string" and type(item) == "table"
                and id ~= "__orderedIndex" then
            clean_items[id] = item
        end
    end
    -- Keep entries added during the crashed run (custom-submenu synthesis),
    -- but nothing else: unknown additions are sort debris.
    local custom_registry = type(order) == "table"
        and order[CUSTOM_SUBMENUS_KEY] or nil
    if type(item_table) == "table" then
        for id, item in pairs(item_table) do
            local synthesized = type(custom_registry) == "table"
                and custom_registry[id] ~= nil
            if type(id) == "string" and type(item) == "table"
                    and clean_items[id] == nil and synthesized then
                clean_items[id] = item
            end
        end
    end
    -- Unknown territory killed the first pass even with classified hints:
    -- strip every remaining hint so the retry cannot re-enter the orphan
    -- hint branch at all (items fall back to the stock NEW: first-menu path).
    for _, item in pairs(clean_items) do
        if type(item) == "table" then item.sorting_hint = nil end
    end
    local clean_order = {}
    for id, list in pairs(order) do
        if type(list) == "table" and id ~= CUSTOM_SUBMENUS_KEY then
            local seq = {}
            for _, entry in ipairs(list) do
                if type(entry) == "string" then table.insert(seq, entry) end
            end
            clean_order[id] = seq
        end
    end
    return clean_items, clean_order
end
-- Test-only escape hatch: probes need the exact retry-input shape the airbag
-- would see, without installing the guard into a shared process.
KoreaderAdapter._probeSanitizeForRetry = sanitizeForRetry

function KoreaderAdapter.installMenuSorterAirbag()
    local MenuSorter = getMenuSorter()
    if not MenuSorter then return false end
    if MenuSorter.reordering_menus_airbag then return true end
    local orig_sort = MenuSorter.sort
    MenuSorter.sort = function(self, item_table, order)
        -- Snapshot BEFORE stock touches anything: a crashed first pass
        -- leaves item_table half-consumed (placed refs nilled) and polluted
        -- with orderedPairs' __orderedIndex scratch array. The retry must
        -- start from the pristine world, not the wreckage.
        local snapshot
        if type(item_table) == "table" then
            snapshot = {}
            for id, item in pairs(item_table) do
                snapshot[id] = item
            end
        end
        local ok, result = pcall(orig_sort, self, item_table, order)
        if ok then return result end
        logger.err("ReorderingMenus: MenuSorter crashed; retrying with",
            "sanitized inputs:", tostring(result))
        local clean_items, clean_order = sanitizeForRetry(snapshot or {},
            item_table or {}, order or {})
        if not clean_order[MENU_BUTTONS_KEY]
                or #clean_order[MENU_BUTTONS_KEY] == 0 then
            -- Stock indexes menu_buttons[1] during orphan fallback: an empty
            -- bar is fatal no matter what we sanitize. Re-raise.
            error(result, 0)
        end
        local ok2, result2 = pcall(orig_sort, self, clean_items, clean_order)
        if ok2 then
            logger.warn("ReorderingMenus: sanitized retry succeeded;",
                "some items may be missing until their providers are fixed")
            return result2
        end
        error(result2, 0)
    end
    MenuSorter.reordering_menus_airbag = true
    return true
end

function KoreaderAdapter.installCustomSubmenuGuard()
    -- User-created submenus have no provider widget, so MenuSorter would drop
    -- their ids from rebuilt menus. Synthesize minimal entries for referenced
    -- customs before sorting; hide the metadata registry from the generic loop.
    local MenuSorter = getMenuSorter()
    if not MenuSorter then return false end
    if MenuSorter.reordering_menus_custom_submenu_guard then return true end
    local orig_sort = MenuSorter.sort
    MenuSorter.sort = function(self, item_table, order)
        local registry = type(order) == "table" and order[CUSTOM_SUBMENUS_KEY] or nil
        if type(registry) == "table" then
            pcall(function()
                local disabled_ids = {}
                for _, id in ipairs(order[DISABLED_KEY] or {}) do
                    disabled_ids[id] = true
                end
                local referenced = {}
                for order_id, list in pairs(order) do
                    if order_id ~= CUSTOM_SUBMENUS_KEY and type(list) == "table" then
                        for _, child_id in ipairs(list) do
                            referenced[child_id] = true
                        end
                    end
                end
                for submenu_id, title in pairs(registry) do
                    if type(title) == "string" and title ~= ""
                            and referenced[submenu_id] and not disabled_ids[submenu_id]
                            and item_table[submenu_id] == nil
                            and type(order[submenu_id]) == "table" then
                        item_table[submenu_id] = { text = tostring(title) }
                    end
                end
            end)
            return withRemovedOrderKey(order, CUSTOM_SUBMENUS_KEY, function()
                return orig_sort(self, item_table, order)
            end)
        end
        return orig_sort(self, item_table, order)
    end
    MenuSorter.reordering_menus_custom_submenu_guard = true
    return true
end

function KoreaderAdapter.installMenuSorterGuards()
    KoreaderAdapter.installSortingHintGuard()
    KoreaderAdapter.installCustomSubmenuGuard()
    KoreaderAdapter.installMenuSorterAirbag()
end

-- -------------------------------------------------------------------------
-- Upstream Error G fix detection
-- -------------------------------------------------------------------------

-- True when the installed KOReader's menusorter.lua already survives an
-- unreachable sorting_hint target (i.e. carries an upstream fix equivalent
-- to patches/menusorter-sorting-hint-nil-guard.patch). Probed by EXECUTING a
-- private sandbox copy of the installed source against the exact crash
-- shape, never by version-string sniffing.
function KoreaderAdapter.upstreamHintGuardPresent(menusorter_path)
    local path = menusorter_path or "frontend/ui/menusorter.lua"
    local chunk, load_err = loadfile(path)
    if not chunk then
        logger.warn("ReorderingMenus: cannot probe menusorter at", path,
            tostring(load_err))
        return nil
    end
    local env = setmetatable({ require = require }, { __index = _G })
    setfenv(chunk, env)
    local ok_mod, stock = pcall(chunk)
    if not (ok_mod and type(stock) == "table"
            and type(stock.sort) == "function") then
        return nil
    end
    local order = {
        [MENU_BUTTONS_KEY] = { "main" },
        [DISABLED_KEY] = { "hidden_tab" },
        main = { "m1" },
    }
    local items = {
        [MENU_BUTTONS_KEY] = {},
        main = { text = "Main" },
        m1 = { text = "One" },
        late_plugin = { text = "Late", sorting_hint = "hidden_tab" },
    }
    local ok_sort = pcall(stock.sort, stock, items, order)
    if ok_sort then return true end
    -- Distinguish plain-vanilla stock (crashes) from something unrunnable.
    return false
end

KoreaderAdapter.CUSTOM_SUBMENUS_KEY = CUSTOM_SUBMENUS_KEY

-- -------------------------------------------------------------------------
-- Area 12: release-blocker mitigation ("Prepare for plugin removal")
-- -------------------------------------------------------------------------

-- The stock crash this plugin can leave behind (Error G): hiding a tab X
-- persists into KOMenu:disabled; with Reordering Menus gone, any plugin
-- whose orphaned item carries sorting_hint = X crashes the menu build at
-- every launch. Until the upstream nil-guard ships everywhere, unrestricted
-- tab hiding is only safe when THIS install demonstrably contains the fix.
--
-- Policy (decided once per process, cached):
--   safe     -> upstreamHintGuardPresent() == true  : unrestricted hiding.
--   unsafe   -> false                               : hiding still allowed
--              (the plugin's own runtime guards make it survivable while
--              installed), but every tab-hide action MUST offer / perform
--              prepareForPluginRemoval() so the world left behind is clean.
--   unknown  -> nil (unreadable sorter etc.)        : treated as unsafe.
function KoreaderAdapter.tabHidingSafety()
    if KoreaderAdapter._tab_safety_cache ~= nil then
        return KoreaderAdapter._tab_safety_cache
    end
    local fixed = KoreaderAdapter.upstreamHintGuardPresent()
    KoreaderAdapter._tab_safety_cache = fixed == true and "safe" or "unsafe"
    return KoreaderAdapter._tab_safety_cache
end

-- Restore every hidden structural row so that removing Reordering Menus
-- cannot leave an orphaned-hint world behind. Returns the list of restored
-- ids per view. Called by the "Prepare for removal" UI action and by any
-- hide action when the user declines to keep a dangerous hidden tab.
-- MenuOrderManager is required lazily to avoid a load cycle at module time.
function KoreaderAdapter.prepareForPluginRemoval(Manager)
    local M = Manager or require("reorderingmenus_menuorder_manager")
    local restored = { failures = {} }
    for _, view in ipairs({ "reader", "filemanager" }) do
        restored[view] = {}
        local disabled = {}
        local order = M.loadOrder and M:loadOrder(view) or nil
        if order then
            for _, id in ipairs(order[DISABLED_KEY] or {}) do
                disabled[id] = true
            end
            -- A structural row is one that other plugins' hints commonly
            -- target: every tab plus every submenu container listed in the
            -- persisted order. Leaf items rarely carry incoming hints, but
            -- restoring them too is harmless (they reappear where they
            -- were hidden from) - so ALL hidden rows are restored. That is
            -- the conservative reading of "safe world after uninstall".
            for id in pairs(disabled) do
                local ok_call, ok_change, change_err = pcall(
                    M.setItemHidden, M, view, id, false)
                if ok_call and ok_change ~= false then
                    table.insert(restored[view], id)
                else
                    table.insert(restored.failures, {
                        view = view,
                        id = id,
                        error = ok_call and change_err or ok_change,
                    })
                end
            end
            if #restored[view] > 0 then
                local ok_call, ok_save, save_err = pcall(M.saveOrder, M, view)
                if not ok_call or not ok_save then
                    table.insert(restored.failures, {
                        view = view,
                        error = ok_call and save_err or ok_save,
                    })
                end
            end
        end
    end
    restored.ok = #restored.failures == 0
    return restored
end

-- -------------------------------------------------------------------------
-- Live rebuild
-- -------------------------------------------------------------------------

function KoreaderAdapter.applyLiveReload(ui, sanitize_tree_fn)
    -- Note: the elements module cache is intentionally NOT invalidated here.
    -- Within a running session the installed KOReader version is fixed, and
    -- dropping the cache would make rebuilt menus silently fall back to
    -- whatever pristine snapshot lives on disk instead of the merged state
    -- MenuSorter already holds.
    if not ui then return false, "UI is unavailable" end

    local ok_call, ok_reload, reload_err = pcall(function()
        if ui.menu then
            if ui.menu.menu_container then
                pcall(function()
                    if ui.menu.onCloseReaderMenu then
                        ui.menu:onCloseReaderMenu()
                    elseif ui.menu.onCloseFileManagerMenu then
                        ui.menu:onCloseFileManagerMenu()
                    elseif ui.menu.onTapCloseMenu then
                        ui.menu:onTapCloseMenu()
                    end
                end)
            end

            local is_reader = ui.document ~= nil
            local old_menu = ui.menu
            local old_widgets = (old_menu and old_menu.registered_widgets) or {}

            local new_menu
            if is_reader then
                local ReaderMenu = require("apps/reader/modules/readermenu")
                new_menu = ReaderMenu:new{ ui = ui, view = ui.view }
            else
                local FileManagerMenu = require("apps/filemanager/filemanagermenu")
                new_menu = FileManagerMenu:new{ ui = ui }
            end

            new_menu.registered_widgets = {}
            for __, w in pairs(old_widgets) do
                table.insert(new_menu.registered_widgets, w)
            end

            -- Build before swapping: a failed build must not replace a working
            -- menu with one that can never open.
            local ok_build, err_build = pcall(new_menu.setUpdateItemTable, new_menu)
            if not ok_build then
                logger.err("ReorderingMenus: live menu rebuild failed, keeping previous menu:", err_build)
                return false, err_build
            end

            if ui.registerModule then
                ui:registerModule("menu", new_menu)
            else
                ui.menu = new_menu
            end

            if sanitize_tree_fn then
                local ok_tree, err_tree = pcall(sanitize_tree_fn, new_menu.tab_item_table)
                if not ok_tree then
                    logger.warn("ReorderingMenus: live menu title sanitize failed:", err_tree)
                    return false, err_tree
                end
            end
        end
        return true
    end)
    if not ok_call then
        logger.err("ReorderingMenus: live menu rebuild failed:", ok_reload)
        return false, ok_reload
    end
    return ok_reload, reload_err
end

return KoreaderAdapter

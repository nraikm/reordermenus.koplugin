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
local MenuSchema = require("lib.menu_schema")
local util = require("util")
local DataLoader = require("lib.data_loader")

local AtomicWriter = require("lib.atomic_writer")

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
-- Provider identities for menu placements contributed by external plugins.
-- These are deliberately kept beside (rather than inside) KOReader's plain
-- menu-order table: Registry needs to distinguish a plugin-owned default slot
-- from a stock-owned one so dormant customizations cannot migrate between
-- providers.
local external_default_providers = {}

local function pluginProviderStamp(provider)
    local value = tostring(provider)
    if value == "stock" or value:find("^plugin:") then return value end
    return "plugin:" .. value
end

local function loadStockOrder(view)
    local loaded
    local ok, res = pcall(dofile,
        string.format("frontend/ui/elements/%s_menu_order.lua", view))
    if ok and type(res) == "table" then
        loaded = util.tableDeepCopy(res)
    else
        local req_ok, req_res = pcall(require,
            string.format("ui/elements/%s_menu_order", view))
        if req_ok and type(req_res) == "table" then
            loaded = util.tableDeepCopy(req_res)
        end
    end
    if not loaded then
        logger.warn("ReorderingMenus: cannot load default menu order for", view)
        loaded = {
            [MenuSchema.MENU_BUTTONS_KEY] = {},
            [MenuSchema.DISABLED_KEY] = {},
        }
    end
    return loaded
end

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
    -- Cold path: SHIPPED stock only, no live_mod merge. Live plugin tabs,
    -- menu trees, and stock-level insertions are adopted exclusively by the
    -- warm path (refreshLivePluginOrder -> captureNativeSnapshot, filtered by
    -- live registrations). Merging live_mod here unfiltered previously let
    -- MenuSorter's overlay of OUR OWN previous emissions (plus any hand edit
    -- present at first load) pollute the "stock" baseline, so sparse emission
    -- gradually mistook its own output for upstream defaults. Stock comparisons
    -- (restore-to-default, reorderTabs baseline, pristine) want shipped bytes.
    local loaded = loadStockOrder(view)

    if not pristine_defaults[view] or force_reload then
        pristine_defaults[view] = util.tableDeepCopy(loaded)
    end
    default_orders[view] = util.tableDeepCopy(pristine_defaults[view])
    defaults_revision[view] = (defaults_revision[view] or 0) + 1
    return util.tableDeepCopy(default_orders[view])
end

-- -------------------------------------------------------------------------
-- Native snapshot (Prompt 4 §2–§3): ONE definition of KOReader's current
-- arrangement before this plugin's customization.
--
--   snapshot = captureNativeSnapshot(shipped, live_mod, regs, providers)
--     -> { order, providers }
--
--   order     full menu/tab layout: shipped stock + live-adopted plugin
--             tabs, reachable provider-backed menu trees, and third-party
--             insertions into stock levels at their live-relative slots.
--   providers per-id stock/plugin stamps for adopted rows (dormancy eras).
--
-- Contamination boundary: live_mod (package.loaded ui/elements/*_menu_order)
-- is READ-ONLY here — order arrays only, never item tables — because
-- MenuSorter overlays native override files (including OUR OWN previous
-- emissions) onto that same process-lifetime table. Stock-row order and
-- stock dividers always stay shipped; only live-REGISTERED non-stock rows
-- are adopted, so our output can never feed back as default. The one hole
-- in that rule is our own echo: a live-registered row that WE placed (a
-- cross-menu move, a restored-then-moved plugin row) is re-overlaid into
-- live_mod by MenuSorter, where it is indistinguishable from a genuine
-- runtime insertion — adopting it would shift its default_parent onto the
-- echoed slot and prune the very intent that produced it (N3 generation
-- churn, R hint-home loss, Q6 divider-slot drift). Callers therefore pass
-- `own_rows` (our last emission per menu, from the materialization
-- checkpoint); echoed rows are skipped as adoption candidates while genuine
-- runtime insertions (absent from our emission) still adopt. Callback replay
-- (collectLiveRegistrations) runs against an empty captured table, never
-- against live_mod. invalidateNativeModuleCache scrubs emission pollution by
-- resetting live_mod to the last snapshot.
--
-- Caches: pristine_defaults = shipped stock file bytes, captured once and
-- NEVER overwritten by adoption (previously the warm path overwrote it,
-- destroying the untouched copy). default_orders = current snapshot
-- (shipped + adopted). defaults_revision bumps only when the snapshot or
-- provider map actually changes. Manager.default_orders[view] remains a
-- TEST-ONLY injection of replacement shipped bytes (the manager routes it
-- through captureNativeSnapshot too, so simulated updates get the same
-- adoption semantics); production always flows through here.
-- -------------------------------------------------------------------------

-- Pure snapshot constructor: no caches touched, no I/O. Shared by the cold
-- path (empty regs: stock tabs/menus visible in live_mod are still adopted
-- as structural roots? No — cold passes no regs so nothing is adopted; see
-- getDefaultOrder) and the warm path below.
--
-- own_rows (optional): { [menu_id] = { [id] = true } } rows of OUR OWN last
-- emission (checkpoint structure). Echoed rows are skipped as adoption
-- candidates (see contamination boundary above); nil/empty disables the
-- exclusion (legacy first contact has no checkpoint to consult).
local function captureNativeSnapshot(stock, live_mod, registrations, providers,
        own_rows)
    registrations = type(registrations) == "table" and registrations or {}
    providers = type(providers) == "table" and providers or {}
    local function is_own_echo(menu_id, id)
        return type(own_rows) == "table"
            and type(own_rows[menu_id]) == "table"
            and own_rows[menu_id][id] == true
    end
    local loaded = util.tableDeepCopy(stock)
    local live_tabs = type(live_mod) == "table"
        and live_mod[MenuSchema.MENU_BUTTONS_KEY] or nil
    local loaded_tabs = loaded[MenuSchema.MENU_BUTTONS_KEY]
    if type(loaded_tabs) ~= "table" then
        loaded_tabs = {}
        loaded[MenuSchema.MENU_BUTTONS_KEY] = loaded_tabs
    end

    local stock_ids = {}
    for menu_id, list in pairs(loaded) do
        if type(menu_id) == "string" then stock_ids[menu_id] = true end
        if type(list) == "table" then
            for _, id in ipairs(list) do
                if type(id) == "string" and id ~= SEPARATOR_ID then
                    stock_ids[id] = true
                end
            end
        end
    end

    local adopted_providers = {}
    local adopted_roots = {}
    local seen_tabs = {}
    for _, id in ipairs(loaded_tabs) do seen_tabs[id] = true end

    if type(live_tabs) == "table" then
        for live_index, tab_id in ipairs(live_tabs) do
            local provider = type(tab_id) == "string" and providers[tab_id]
            local is_live_root = provider ~= nil
                and registrations[tab_id] ~= nil
                and type(live_mod[tab_id]) == "table"
                and not KoreaderAdapter.isInReservedNamespace(tab_id)
            if is_live_root and not stock_ids[tab_id] and not seen_tabs[tab_id] then
                local target = math.min(live_index, #loaded_tabs + 1)
                table.insert(loaded_tabs, target, tab_id)
                seen_tabs[tab_id] = true
                adopted_roots[#adopted_roots + 1] = tab_id
                adopted_providers[tab_id] = pluginProviderStamp(provider)
            end
        end
    end

    -- Copy only the reachable provider-backed menu tree. Conditional rows
    -- absent from addToMainMenu are intentionally omitted until they become
    -- live; otherwise a static plugin MENU_ORDER would create phantom rows.
    local queue = util.tableDeepCopy(adopted_roots)
    local visited = {}
    local qindex = 1
    while qindex <= #queue do
        local menu_id = queue[qindex]
        qindex = qindex + 1
        if not visited[menu_id] then
            visited[menu_id] = true
            local source = type(live_mod) == "table" and live_mod[menu_id] or nil
            if type(source) == "table" then
                local copied = {}
                for _, id in ipairs(source) do
                    if id == SEPARATOR_ID then
                        copied[#copied + 1] = id
                    elseif type(id) == "string"
                            and not KoreaderAdapter.isInReservedNamespace(id)
                            and (stock_ids[id]
                                or (registrations[id] ~= nil and providers[id] ~= nil)) then
                        copied[#copied + 1] = id
                        if not stock_ids[id] then
                            adopted_providers[id] =
                                pluginProviderStamp(providers[id])
                            if type(live_mod[id]) == "table" then
                                queue[#queue + 1] = id
                            end
                        end
                    end
                end
                loaded[menu_id] = copied
            end
        end
    end

    -- Third-party insertions into EXISTING stock levels: a live plugin that
    -- mutates a stock menu's array (e.g. inserting a row into Tools) leaves
    -- that row in live_mod[menu_id] but not in the shipped stock file. Adopt
    -- ONLY the non-stock live-registered rows, spliced into the SHIPPED stock
    -- order at their live-relative slots. Stock-row order and stock dividers
    -- always stay shipped: live_mod also carries OUR OWN previous emissions
    -- (MenuSorter overlays native files onto it), and adopting those would
    -- feed our output back as default and prune the very intent that
    -- produced it. Anything else (stale customs, hand edits) is ignored.
    if type(live_mod) == "table" then
        for menu_id, stock_list in pairs(loaded) do
            if type(menu_id) == "string" and type(stock_list) == "table"
                    and not KoreaderAdapter.isInReservedNamespace(menu_id)
                    and menu_id ~= MenuSchema.MENU_BUTTONS_KEY
                    and menu_id ~= MenuSchema.DISABLED_KEY
                    and menu_id ~= MenuSchema.CUSTOM_SUBMENUS_KEY
                    and not visited[menu_id] then
                local live_list = live_mod[menu_id]
                if type(live_list) == "table" then
                    -- Collect genuinely new plugin rows in live order,
                    -- excluding our own echoed emission rows (which would
                    -- otherwise feed back as defaults and prune their intent).
                    local newcomers = {}
                    local seen_new = {}
                    for _, id in ipairs(live_list) do
                        if type(id) == "string" and not seen_new[id]
                                and not stock_ids[id]
                                and not KoreaderAdapter.isInReservedNamespace(id)
                                and not is_own_echo(menu_id, id)
                                and registrations[id] ~= nil
                                and providers[id] ~= nil then
                            seen_new[id] = true
                            newcomers[#newcomers + 1] = id
                        end
                    end
                    if #newcomers > 0 then
                        -- Splice each newcomer before its next live stock
                        -- neighbour (or at the end when none follows), so the
                        -- live slot is preserved without reordering stock.
                        local live_pos = {}
                        for idx, id in ipairs(live_list) do
                            if type(id) == "string" and live_pos[id] == nil then
                                live_pos[id] = idx
                            end
                        end
                        local merged = {}
                        for _, id in ipairs(stock_list) do
                            merged[#merged + 1] = id
                        end
                        local function stock_index_of(sid)
                            for i, v in ipairs(merged) do
                                if v == sid then return i end
                            end
                            return nil
                        end
                        for _, nid in ipairs(newcomers) do
                            local at = nil
                            local npos = live_pos[nid] or math.huge
                            local best_after, best_pos = nil, math.huge
                            for idx = npos + 1, #live_list do
                                local cand = live_list[idx]
                                if type(cand) == "string" and stock_ids[cand] then
                                    local si = stock_index_of(cand)
                                    if si and si < best_pos then
                                        best_pos, best_after = si, cand
                                    end
                                    break
                                end
                            end
                            if best_after then
                                at = stock_index_of(best_after)
                            else
                                -- No stock successor live: trail the nearest
                                -- live stock predecessor, else append.
                                local pred = nil
                                for idx = (live_pos[nid] or 1) - 1, 1, -1 do
                                    local cand = live_list[idx]
                                    if type(cand) == "string" and stock_ids[cand] then
                                        pred = cand break
                                    end
                                end
                                at = pred and ((stock_index_of(pred) or #merged) + 1)
                                    or (#merged + 1)
                            end
                            table.insert(merged, math.min(at, #merged + 1), nid)
                            adopted_providers[nid] =
                                pluginProviderStamp(providers[nid])
                        end
                        if not util.tableEquals(stock_list, merged) then
                            loaded[menu_id] = merged
                        end
                    end
                end
            end
        end
    end

    return loaded, adopted_providers
end

KoreaderAdapter.captureNativeSnapshot = captureNativeSnapshot
KoreaderAdapter._captureNativeSnapshotForTests = captureNativeSnapshot

-- Reconcile provider-backed menu-order mutations made after our first
-- defaults snapshot. Bookshelf is the canonical example: its init() requires
-- ui/elements/filemanager_menu_order, inserts bookshelf_tab into the shared
-- KOMenu:menu_buttons array, and adds a bookshelf_tab list. Plugin load order
-- is not an API, so this may happen before OR after Reordering Menus cached
-- the stock module. Warm path: shipped stock + live adoption via the single
-- snapshot constructor above (pristine is NEVER overwritten here — it stays
-- the untouched shipped copy; only default_orders advances).
--
-- Never copy arbitrary unknown keys from package.loaded here. MenuSorter
-- overlays user native files onto that same process-lifetime table, so it may
-- also contain stale custom submenus or hand-authored keys. A root is adopted
-- only when a currently registered widget supplies that root id and provider;
-- descendant menu levels are followed only through likewise-live entries.
-- `own_rows` (our last emission, checkpoint structure) excludes our echo
-- from newcomer candidacy; see the contamination boundary above.
function KoreaderAdapter.refreshLivePluginOrder(view, registrations, providers,
        own_rows)
    local stock = loadStockOrder(view)
    local live_mod = package.loaded[string.format(
        "ui/elements/%s_menu_order", view)]
    local loaded, adopted_providers = captureNativeSnapshot(
        stock, live_mod, registrations, providers, own_rows)

    local changed = not util.tableEquals(default_orders[view] or {}, loaded)
        or not util.tableEquals(external_default_providers[view] or {},
            adopted_providers)
    default_orders[view] = util.tableDeepCopy(loaded)
    external_default_providers[view] = adopted_providers
    if changed or defaults_revision[view] == nil then
        defaults_revision[view] = (defaults_revision[view] or 0) + 1
    end
    return util.tableDeepCopy(default_orders[view]), changed
end

function KoreaderAdapter.getExternalDefaultProviders(view)
    return util.tableDeepCopy(external_default_providers[view] or {})
end

-- -------------------------------------------------------------------------
-- Native user override files
-- -------------------------------------------------------------------------

function KoreaderAdapter.getNativePath(view)
    return string.format("%s/%s_menu_order.lua", KoreaderAdapter.getSettingsDir(), view)
end

function KoreaderAdapter.readNativeOrder(view)
    local path = KoreaderAdapter.getNativePath(view)
    -- P0-7: native order files are serialized DATA (they are also parsed by
    -- stock KOReader with plain dofile, but OUR reads never grant them
    -- application privileges).
    local res = DataLoader.loadTable(path)
    if res then return util.tableDeepCopy(res) end
    if lfs.attributes(path, "mode") == "file" then
        logger.warn("ReorderingMenus: failed to load native user order:", path)
    end
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
    KoreaderAdapter.invalidateNativeModuleCache()
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
    KoreaderAdapter.invalidateNativeModuleCache()
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
    if external_default_providers[view]
            and external_default_providers[view][id] then
        return false
    end
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
    -- Reset package.loaded for menu orders to an unpolluted baseline (stock + plugin additions + test defaults)
    -- without MenuSorter mergeAndSort user pollution (e.g. disabled items, user custom submenus).
    local M = package.loaded["lib.menuorder_manager"]
    for _, view in ipairs({ "reader", "filemanager" }) do
        local mod = string.format("ui/elements/%s_menu_order", view)
        if package.loaded[mod] ~= nil then
            local def = (M and M.default_orders and M.default_orders[view])
                or KoreaderAdapter.getDefaultOrder(view)
            package.loaded[mod] = util.tableDeepCopy(def)
        end
    end
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
                        -- Quarantined AND dropped (not recorded anywhere):
                        -- ids under our namespace are plugin-synthesized
                        -- structures, never provider contributions. The build
                        -- layer (Registry) enforces the same refusal as a
                        -- second gate. Previously the registration record was
                        -- still inserted here after logging, and only the
                        -- provider attribution was skipped.
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
                                item = item,
                                colliding = { [widget_name] = true },
                            }
                            providers[id] = widget_name
                        else
                            known.colliding[widget_name] = true
                            if widget_name < known.min then
                                known.min = widget_name
                                known.hint = type(item) == "table"
                                    and item.sorting_hint or nil
                                known.item = item
                                providers[id] = widget_name
                            end
                        end
                    end
                    if not KoreaderAdapter.isInReservedNamespace(id)
                            and not registrations[id] then
                        registrations[id] = {
                            id = id,
                            provider = widget_name and ("plugin:" .. tostring(widget_name)) or nil,
                            sorting_hint = type(item) == "table"
                                and item.sorting_hint or nil,
                            display_item = item,
                        }
                    end
                end
            end)
            if not ok then
                logger.warn("ReorderingMenus: failed collecting registrations from", tostring(name))
            end
        end
    end
    -- Re-apply the winning attributes after collection (the deterministic minimum must win).
    for id, known in pairs(contributors) do
        if not registrations[id] then
            registrations[id] = { id = id }
        end
        registrations[id].sorting_hint = known.hint
        registrations[id].provider = known.min and ("plugin:" .. tostring(known.min)) or nil
        registrations[id].display_item = known.item or registrations[id].display_item
    end
    -- Colliding ids: contributors whose value carries a LIST of widget names
    -- with more than one entry. (The value is { min, hint }; a single
    -- contributor must never be mistaken for a collision.) P1B (#2): the
    -- list is stamped on THIS module's own freshly-built registration
    -- records (never on provider-owned entry tables) AND returned as a
    -- separate map, so registry/UI consumers can use whichever is handy.
    local collisions = {}
    for id, names in pairs(contributors) do
        local count = 0
        for _ in pairs(names.colliding or {}) do count = count + 1 end
        if count > 1 then
            collisions[id] = {}
            for widget_name in pairs(names.colliding) do
                table.insert(collisions[id], widget_name)
            end
            table.sort(collisions[id])
            if type(registrations[id]) == "table" then
                registrations[id].colliding_providers =
                    util.tableDeepCopy(collisions[id])
            end
            logger.warn("ReorderingMenus: menu id", id, "contributed by multiple widgets:",
                table.concat(collisions[id], ", "),
                "- attributing to", providers[id])
        end
    end
    return registrations, providers, collisions
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
-- items pointing at an unknown menu fall back to stock orphan handling
local function shallowCopyTable(tbl)
    if type(tbl) ~= "table" then return tbl end
    local copy = {}
    for k, v in pairs(tbl) do copy[k] = v end
    return copy
end

function KoreaderAdapter.installSortingHintGuard()
    local MenuSorter = getMenuSorter()
    if not MenuSorter then return false end
    if MenuSorter.reordering_menus_hint_guard then return true end

    local orig_sort = MenuSorter.sort
    MenuSorter.sort = function(self, item_table, order)
        if type(item_table) == "table" and type(order) == "table" then
            pcall(function()
                for id, item in pairs(item_table) do
                    local hint = type(item) == "table" and item.sorting_hint
                    if hint ~= nil and id ~= MENU_BUTTONS_KEY
                            and not order[id] then
                        -- Only orphans (unplaced items) reach the guarded
                        -- branch of stock sort; placed rows never consult
                        -- their hint again.
                        local klass = KoreaderAdapter.classifyHintTarget(
                            hint, order, id, item_table)
                        if klass == "disabled" then
                            -- Follow its hidden target into invisibility
                            -- WITHOUT rewriting the provider's entry: stock
                            -- drops disabled-listed ids on its own.
                            item_table[id] = nil
                        elseif klass ~= "reachable_container"
                                and klass ~= "placed" then
                            logger.warn("ReorderingMenus: neutralized",
                                tostring(klass), "sorting_hint on", tostring(id))
                            -- P1B (#8): Never mutate provider-owned tables.
                            -- Replace the entry in item_table with a shallow copy
                            -- having sorting_hint stripped. The provider's original
                            -- table remains byte- and field-equivalent.
                            local item_copy = shallowCopyTable(item)
                            item_copy.sorting_hint = nil
                            item_table[id] = item_copy
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
-- orderedPairs' __orderedIndex scratch array onto it. The retry must
-- start from pristine copied inputs, never mutating the originals.
local function sanitizeForRetry(snapshot, item_table, order)
    local clean_items = {}
    for id, item in pairs(snapshot) do
        if type(id) == "string" and type(item) == "table"
                and id ~= "__orderedIndex" then
            local copy = shallowCopyTable(item)
            copy.sorting_hint = nil
            clean_items[id] = copy
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
                local copy = shallowCopyTable(item)
                copy.sorting_hint = nil
                clean_items[id] = copy
            end
        end
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
    if KoreaderAdapter.tabHidingSafety() ~= "safe" then
        KoreaderAdapter.installSortingHintGuard()
    end
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
--
-- P0-10: ONE semantic operation. Both views are inspected, every hazardous
-- hidden row is staged for unhide in ONE transaction, canonical state
-- commits ONCE, and every changed view is materialized by the shared
-- funnel. A failure in one view's derived output can no longer leave the
-- other view half-restored at the intent layer (it is reported truthfully
-- instead). MenuOrderManager is required lazily to avoid a load cycle.
function KoreaderAdapter.prepareForPluginRemoval(Manager)
    local M = Manager or require("lib.menuorder_manager")
    return M:prepareForPluginRemoval()
end

-- -------------------------------------------------------------------------
-- Restart (P1B #12: KOReader-native restart handling)
-- -------------------------------------------------------------------------

--- Request a KOReader restart through the SUPPORTED entry point
--- (UIManager:askForRestart). Unlike a raw broadcast of the "Restart"
--- event, this is safe on devices without restart support: stock installs
--- event_handlers.Restart only when Device:canRestart(), and askForRestart
--- checks the PowerOff handler before scheduling - on unsupported platforms
--- it is a no-op instead of an unhandled-event silence. Callers that want
--- to inform the user should show their own ConfirmBox whose ok_callback
--- invokes THIS (see UIScreens.promptRestart; the merge agent may switch
--- that callback from broadcastEvent(Event:new("Restart")) to here).
function KoreaderAdapter.requestRestart(message_text)
    local UIManager = require("ui/uimanager")
    if UIManager.askForRestart then
        UIManager:askForRestart(message_text)
    else
        local Event = require("ui/event")
        UIManager:broadcastEvent(Event:new("Restart"))
    end
    return true
end

-- True when this installation can actually restart (capability check, not
-- version sniffing): stock defines event_handlers.Restart only under
-- Device:canRestart().
function KoreaderAdapter.canRestart()
    local UIManager = require("ui/uimanager")
    return UIManager.event_handlers ~= nil
        and UIManager.event_handlers.Restart ~= nil
end

-- KOReader's MenuSorter titles a submenu marker with the content's static
-- text only (sub_menu_position.text = sub_menu_content.text), dropping
-- text_func. A submenu registered with a dynamic-only title therefore
-- renders as the literal string "nil" once relocated by a layout. Walk the
-- rebuilt tree and give every renderable row a usable title.
--
-- Third-party menu tables may self-reference, share subtrees, or contain
-- cycles. Traversal is iterative with a visited set keyed by table identity,
-- so cycles cannot recurse forever and shared subtrees are processed once.
function KoreaderAdapter.sanitizeLiveMenuTree(tree)
    if type(tree) ~= "table" then return end
    local MenuTitles = require("lib.menu_titles")
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

-- Live reload (Prompt 4 §6): architecturally one production path.
--
-- Production path — in-place rebuild, controller identity preserved:
-- KOReader retains references and closures (touch-zone handlers, key
-- dispatch, ReaderUI fields) bound to the EXISTING menu instance, so the
-- derived tree is re-derived from the updated native order on the same table
-- through the SUPPORTED setUpdateItemTable lifecycle hook. Replacing ui.menu
-- would orphan those routes on the old object while the new one never
-- receives them (the Prompt 1 stale-controller bug).
--
-- Test-compat fallback — fresh-instance construction: unit mocks (and any
-- menu whose in-place rebuild cannot produce a valid tree, e.g. a mock
-- without real stock menu_items) cannot rebuild in place, so a fresh
-- instance is built to keep compatibility surfaces working. Production
-- KOReader menus never take this branch (their in-place rebuild yields a
-- valid tree); it exists so tests can exercise save/apply without a full UI.
-- Total-failure last resort (neither path yields a tree) keeps the previous
-- renderable tree so routing stays alive — safety, not stale-reference
-- repair: nothing references the discarded table afterwards.
function KoreaderAdapter.applyLiveReload(ui, sanitize_tree_fn)
    if not ui then return false, "UI is unavailable" end
    KoreaderAdapter.invalidateNativeModuleCache()
    local is_reader = ui.document ~= nil
    local mod_name = is_reader and "apps/reader/modules/readermenu"
        or "apps/filemanager/filemanagermenu"
    if package.loaded[mod_name] ~= nil then
        local ok_call, ok_reload, reload_err = pcall(function()
            -- Test-compat constructor (see header): fresh instance carrying
            -- over registered widgets, used ONLY when in-place rebuild below
            -- cannot produce a valid tree.
            local function build_fresh_for_mocks()
                local MenuCls = require(mod_name)
                if not (MenuCls and MenuCls.new) then return nil end
                local fresh = is_reader and MenuCls:new{ ui = ui, view = ui.view }
                    or MenuCls:new{ ui = ui }
                if ui.menu and ui.menu.registered_widgets then
                    for k, w in pairs(ui.menu.registered_widgets) do
                        fresh.registered_widgets[k] = w
                    end
                end
                if fresh.setUpdateItemTable then
                    fresh:setUpdateItemTable()
                end
                if type(sanitize_tree_fn) == "function" and fresh.tab_item_table then
                    sanitize_tree_fn(fresh.tab_item_table)
                end
                return fresh
            end
            -- Production path: rebuild the derived tree in place on the
            -- SAME controller through its supported lifecycle hook.
            local function rebuild_in_place(menu)
                local saved_table = menu.tab_item_table
                local ok_inplace = pcall(function()
                    menu.tab_item_table = nil
                    menu:setUpdateItemTable()
                end)
                local valid = ok_inplace and type(menu.tab_item_table) == "table"
                    and #menu.tab_item_table > 0
                if valid then
                    if type(sanitize_tree_fn) == "function" and menu.tab_item_table then
                        sanitize_tree_fn(menu.tab_item_table)
                    end
                    return true
                end
                menu.tab_item_table = saved_table
                return false
            end
            local menu = ui.menu
            if menu and type(menu.setUpdateItemTable) == "function"
                    and rebuild_in_place(menu) then
                return true
            elseif menu and type(menu.setUpdateItemTable) == "function" then
                -- In-place rebuild failed (e.g. mock menu without real
                -- stock menu_items): test-compat fallback so the live tree
                -- still reflects the saved order.
                local saved_table = menu.tab_item_table
                local fresh = build_fresh_for_mocks()
                if fresh and type(fresh.tab_item_table) == "table"
                        and #fresh.tab_item_table > 0 then
                    ui.menu = fresh
                elseif menu.tab_item_table == nil then
                    -- Neither path produced a tree; keep the saved table
                    -- so routing stays on the old (still renderable) tree.
                    menu.tab_item_table = saved_table
                end
            else
                local fresh = build_fresh_for_mocks()
                if fresh then ui.menu = fresh end
            end
            return true
        end)
        if not ok_call then return false, ok_reload end
        if not ok_reload then return false, reload_err end
    end
    return true
end

return KoreaderAdapter

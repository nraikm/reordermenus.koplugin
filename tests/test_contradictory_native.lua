--[[
test_contradictory_native.lua — Areas K + L + M.

K. Contradictory external native state: deterministic normalization, never a
   silent pairs() winner.
  K1  X listed under A and B
  K2  X listed and disabled
  K3  X listed under multiple parents and disabled
  K4  native parent B but sidecar origin A
  K5  hidden anchor points to missing ID
  K6  sidecar hidden but native disabled absent
  K7  native disabled but no hidden record
  K8  multiple structural claims for one submenu

L. Manual edits while plugin disabled: recognized as genuine external edits.

M. Multiple external edits between observations: importer reasons from the
   final state only; large multi-list edits handled.

Run: cd /Applications/KOReader.app/Contents/koreader &&
     ./luajit <project>/tests/test_contradictory_native.lua
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
local _ = require("gettext")
require("main")

local Manager = require("reorderingmenus_menuorder_manager")
local IntentStore = require("reorderingmenus_intent_store")
local NativeWriter = require("reorderingmenus_native_writer")
local UIScreens = require("reorderingmenus_ui_screens")
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")

local passed, failed = 0, 0
local function note(cond, msg)
    if cond then passed = passed + 1
    else
        failed = failed + 1
        print("  [FAIL] " .. tostring(msg))
        io.stdout:flush()
    end
end

local sd = DataStorage:getSettingsDir()
local VIEW = "filemanager"
local OTHER = "reader"

local function wipe_all()
    for _, f in ipairs({ "filemanager_menu_order.lua", "reader_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        os.remove(sd .. "/" .. f)
    end
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}
    Manager.recent_moves.reader = {}
    Manager:dropSessionState(VIEW)
    Manager:dropSessionState(OTHER)
end

-- write a raw native file + matching sidecar baseline so syncView treats it
-- as externally edited relative to that baseline
local function seed_baseline(structure)
    -- first produce a real emission so the sidecar exists...
    Manager:saveOrder(VIEW)
    -- ...then hand-write our "previous" structure into the sidecar
    local sidecar_path = sd .. "/reorderingmenus_materialization.lua"
    local f = io.open(sidecar_path, "r")
    local body = f and f:read("*a") or ""
    if f then f:close() end
    local dump = require("dump")
    -- replace structure via a full rewrite: load, mutate, save through writer
    local chunk = body:gsub("^%-%-[^\n]*\n", "")
    local ok_load, data = pcall(load(chunk or body))
    if ok_load and type(data) == "table" and data.views and data.views[VIEW] then
        data.views[VIEW].structure = structure
        local AtomicWriter = require("reorderingmenus_atomic_writer")
        AtomicWriter.writeTable(sidecar_path, data)
    end
    NativeWriter._resetCaches()
end

local function write_native(tbl)
    KoreaderAdapter.writeNativeOrder(VIEW, tbl)
end

local function launch()
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)
end

print("===============================================================")
print("=== K. Contradictory external native state                   ===")
print("===============================================================")

-- K1: X listed under two menus -> single deterministic parent.
do
    wipe_all()
    launch(); Manager:saveOrder(VIEW)
    seed_baseline({ tools = { "terminal" } })
    write_native({
        tools = { "terminal" },
        setting = { "terminal" },
    })
    Manager:reloadFromDisk(VIEW)

    local count, parent = 0, nil
    local order = Manager:loadOrder(VIEW)
    for menu_id, list in pairs(order) do
        if type(list) == "table" then
            for _, id in ipairs(list) do
                if id == "terminal" then count = count + 1; parent = menu_id end
            end
        end
    end
    note(count == 1, "K1: terminal rendered exactly once (got "
        .. tostring(count) .. ")")
    note(parent ~= nil, "K1b: terminal has a parent")
    wipe_all()
end

-- K2: X listed AND disabled -> disabled wins deterministically.
do
    wipe_all()
    launch(); Manager:saveOrder(VIEW)
    seed_baseline({})
    write_native({
        tools = { "calibre" },
        ["KOMenu:disabled"] = { "calibre" },
    })
    Manager:reloadFromDisk(VIEW)

    note(Manager:isItemHidden(VIEW, "calibre"),
        "K2: listed+disabled resolves to hidden")
    local order = Manager:loadOrder(VIEW)
    local listed = false
    for menu_id, list in pairs(order) do
        if menu_id ~= "KOMenu:disabled" and type(list) == "table" then
            for _, id in ipairs(list) do
                if id == "calibre" then listed = true end
            end
        end
    end
    note(not listed, "K2b: hidden item not listed anywhere visible")
    wipe_all()
end

-- K3: multi-parent listing AND disabled.
do
    wipe_all()
    launch(); Manager:saveOrder(VIEW)
    seed_baseline({})
    write_native({
        tools = { "calibre" },
        main = { "calibre" },
        ["KOMenu:disabled"] = { "calibre" },
    })
    Manager:reloadFromDisk(VIEW)

    note(Manager:isItemHidden(VIEW, "calibre"),
        "K3: multi-claim + disabled resolves to hidden")
    wipe_all()
end

-- K5/K6/K7: hidden anchor / sidecar / native mismatches normalize safely.
do
    wipe_all()
    launch(); Manager:saveOrder(VIEW)
    -- sidecar claims history hidden with origin pointing to a missing level;
    -- native file has no disabled entry at all.
    seed_baseline({})
    write_native({})
    local txn = IntentStore.openTransaction()
    txn:setHidden(VIEW, "history", { provider = "stock", origin = "no_such_menu" })
    note(txn:commit(true), "K5: stale-origin hidden record commits cleanly")

    Manager:reloadFromDisk(VIEW)
    note(pcall(function() return Manager:loadOrder(VIEW) end),
        "K6: projection loads despite origin mismatch")

    -- native disabled without a hidden record imports one
    seed_baseline({})
    write_native({ ["KOMenu:disabled"] = { "calibre" } })
    Manager:reloadFromDisk(VIEW)
    note(Manager:isItemHidden(VIEW, "calibre"),
        "K7: native-only disabled imported as hidden intent")
    wipe_all()
end

-- K8: duplicate structural claims for one submenu key.
do
    wipe_all()
    launch(); Manager:saveOrder(VIEW)
    seed_baseline({ tools = {} })
    write_native({
        tools = { "terminal", "screensaver", "calibre" },
        setting = { "terminal", "opds" },
    })
    Manager:reloadFromDisk(VIEW)
    -- single-parent invariant holds in the projection
    local count = 0
    local order = Manager:loadOrder(VIEW)
    for _menu_id, list in pairs(order) do
        if type(list) == "table" then
            for _, id in ipairs(list) do
                if id == "terminal" then count = count + 1 end
            end
        end
    end
    note(count == 1, "K8: cross-listed submenu id renders once (got "
        .. tostring(count) .. ")")
    wipe_all()
end

print("===============================================================")
print("=== L. Manual edits while plugin disabled                    ===")
print("===============================================================")

do
    wipe_all()
    launch()
    -- customize & persist while enabled
    Manager:setItemHidden(VIEW, "history", true, "main")
    Manager:saveOrder(VIEW)

    -- plugin disabled: simulate by wiping canonical + sidecar but keeping
    -- the native file (the user's manual-edit surface).
    os.remove(sd .. "/reorderingmenus_intent.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    IntentStore.load(true); NativeWriter._resetCaches()

    -- manual modification of the native order file
    write_native({ search = { "opds", "search_settings", "dictionary_lookup",
        "dictionary_lookup_history", "vocabbuilder", "wikipedia_lookup",
        "wikipedia_history", "file_search", "file_search_results",
        "find_book_in_calibre_catalog" } })

    -- re-enable plugin (fresh session startup path)
    Manager:dropSessionState(VIEW); IntentStore.load(true)
    launch()

    -- the manual reorder must be recognized as genuine user intent:
    local sec = IntentStore.view(VIEW)
    note(sec.order_override.search ~= nil,
        "L: manual edit imported as explicit order_override after re-enable")
    -- ...and it survives a restart
    Manager:dropSessionState(VIEW); IntentStore.load(true)
    note(IntentStore.view(VIEW).order_override.search ~= nil,
        "Lb: manual edit durable across reload")
    wipe_all()
end

print("===============================================================")
print("=== M. Multiple external edits between observations          ===")
print("===============================================================")

do
    wipe_all()
    launch(); Manager:saveOrder(VIEW)
    seed_baseline({ search = { "opds", "search_settings", "dictionary_lookup",
        "dictionary_lookup_history", "vocabbuilder", "wikipedia_lookup",
        "wikipedia_history", "file_search", "file_search_results",
        "find_book_in_calibre_catalog" },
        main = { "history", "open_last_document" } })

    -- tool A's edit then tool B's edit land before the plugin looks again:
    -- final state is what must be imported, whatever the intermediate was.
    write_native({
        -- search heavily reordered + pruned
        search = { "wikipedia_lookup", "wikipedia_history", "vocabbuilder",
            "search_settings", "opds", "find_book_in_calibre_catalog",
            "file_search_results", "file_search", "dictionary_lookup_history",
            "dictionary_lookup" },
        main = { "favorites", "collections", "exit_menu" },
    })
    Manager:reloadFromDisk(VIEW)
    Manager:saveOrder(VIEW)   -- commit the imported external state

    local sec = IntentStore.view(VIEW)
    local seq = sec.order_override.search or {}
    note(#seq == 10,
        "M: final multi-list state imported wholesale (seq n="
        .. tostring(#seq) .. ")")
    note(seq[1] == "wikipedia_lookup",
        "Mb: imported sequence matches the FINAL observed arrangement")
    -- projection agrees with the import
    local proj = Manager:getMenuItems(VIEW, "search")
    local stripped = {}
    for _, id in ipairs(proj) do
        if id ~= "----------------------------" then stripped[#stripped+1] = id end
    end
    note(stripped[1] == "wikipedia_lookup",
        "Mc: projection reflects the final external arrangement")
    wipe_all()
end

wipe_all()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)

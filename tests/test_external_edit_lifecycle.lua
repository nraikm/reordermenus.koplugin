--[[
test_external_edit_lifecycle.lua — Areas L + M, hardened.

L.  Manual edits while the plugin is DISABLED must be recognized as genuine
    external user intent on re-enable, never overwritten as stale project
    output. Covered across every disable flavor the plugin can exhibit:

    L1  canonical intent + sidecar wiped (uninstall-style disable)
    L2  sidecar alone lost (crash during a materialization-record write)
    L3  native file rolled back to OUR OWN previous generation while intent
        stayed current (partial multi-view commit crash)
    L4  plugin fully disabled at the KOReader level: no session ever runs,
        the edit waits for the NEXT genuine launch
    L5  the imported manual edit survives a subsequent save and restart
        without being "corrected" back

M.  Multiple external edits between observations: only the FINAL state is
    observable; the importer must reason from A->C without assuming one
    UI-like move.

    M1  large multi-list edit (4 menus, 40+ rows) imports wholesale
    M2  A -> B -> C edits land before one observation; C wins everywhere
    M3  A -> B where B happens to equal stock again: net effect is a clean
        sparse revert, not a frozen snapshot of B
    M4  interleaved hide/unhide/reorder/move across lists in one final state

V.  Version interactions around external state:
    V1  v1 intent file + fresh sidecar: external edit still recognized
    V2  future-schema quarantine does not eat an external native edit
    V3  legacy dense file with no sidecar at all: imported once, then
        stable (no re-import churn)

Run: ./run_tests.sh tests/test_external_edit_lifecycle.lua
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
require("main")

local Manager = require("lib.menuorder_manager")
local IntentStore = require("lib.intent_store")
local NativeWriter = require("lib.native_writer")
local UIScreens = require("lib.ui_screens")
local KoreaderAdapter = require("lib.koreader_adapter")

local VIEW = "filemanager"
local sd = DataStorage:getSettingsDir()

local passed, failed = 0, 0
local function note(cond, msg)
    if cond then passed = passed + 1
    else failed = failed + 1
        print("  [FAIL] " .. tostring(msg))
        io.stdout:flush()
    end
end
local function assert_eq(a, e, msg) note(a == e, msg .. " (expected "
    .. tostring(e) .. ", got " .. tostring(a) .. ")") end

-- -------------------------------------------------------------------------
-- Lifecycle helpers
-- -------------------------------------------------------------------------

local function wipe_all()
    for _, f in ipairs({ "filemanager_menu_order.lua", "reader_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        os.remove(sd .. "/" .. f)
    end
    -- Quarantine artifacts too: a rerun must not inherit the previous run's
    -- unsupported-schema backups, or collision assertions start green.
    local p = io.popen('ls "' .. sd .. '/"reorderingmenus_intent.unsupported.lua '
        .. '"' .. sd .. '/"reorderingmenus_intent.lua.unsupported-* 2>/dev/null')
    for line in (p and p:read("*a") or ""):gmatch("[^\n]+") do
        os.remove(line)
    end
    if p then p:close() end
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}
    Manager.recent_moves.reader = {}
    Manager:dropSessionState(VIEW)
    Manager:dropSessionState("reader")
end

local function launch(view)
    UIScreens:reconcileRegisteredItems(
        { ui = { menu = { registered_widgets = {} } } }, view or VIEW, false)
end

local function full_restart(view)
    Manager:dropSessionState(view or VIEW)
    IntentStore.load(true)
    NativeWriter._resetCaches()
    launch(view)
end

local function write_native(tbl, view)
    KoreaderAdapter.writeNativeOrder(view or VIEW, tbl)
end

local function read_native(view)
    local ok, res = pcall(dofile, KoreaderAdapter.getNativePath(view or VIEW))
    if ok and type(res) == "table" then return res end
    return nil
end

local function strip_seps(list)
    local out = {}
    for _, id in ipairs(list or {}) do
        if id ~= "----------------------------" then table.insert(out, id) end
    end
    return out
end

print("===============================================================")
print("=== L. Manual edits while plugin disabled                    ===")
print("===============================================================")

-- L1: customize -> wipe canonical+sidecar (the "disabled" world) -> manual
-- edit of the native order -> re-enable. The edit must be imported.
do
    wipe_all(); launch()
    Manager:setItemHidden(VIEW, "history", true, "main")
    Manager:saveOrder(VIEW)

    -- plugin disabled / state lost: canonical + sidecar gone, native kept
    os.remove(sd .. "/reorderingmenus_intent.lua")
    os.remove(sd .. "/reorderingmenus_materialization.lua")
    IntentStore.load(true); NativeWriter._resetCaches()

    -- manual modification of the native order file by the user
    local manual_search = { "opds", "search_settings", "dictionary_lookup",
        "dictionary_lookup_history", "vocabbuilder", "wikipedia_lookup",
        "wikipedia_history", "file_search", "file_search_results",
        "find_book_in_calibre_catalog" }
    write_native({ search = manual_search })

    -- re-enable plugin (fresh session startup path runs the import)
    full_restart(VIEW)

    local sec = IntentStore.view(VIEW)
    note(sec.order_override.search ~= nil,
        "L1: manual edit imported as explicit order_override after re-enable")
    local seq_record = sec.order_override.search or {}
    -- Schema v3: sequences persist as { entries = { {id=...}, ... } }.
    local seq = type(seq_record) == "table" and seq_record.entries
        or seq_record
    assert_eq(#(seq or {}), #manual_search, "L1b: whole sequence imported")
    local first = type(seq[1]) == "table" and seq[1].id or seq[1]
    assert_eq(first, "opds", "L1c: sequence matches the manual arrangement")

    -- L5 folded in: save and restart again; the import must survive verbatim
    -- (recognized as genuine intent, never overwritten as stale output).
    Manager:saveOrder(VIEW)
    local function first_entry()
        local rec = IntentStore.view(VIEW).order_override.search or {}
        local entries = type(rec) == "table" and rec.entries or rec
        local e = (entries or {})[1]
        return type(e) == "table" and e.id or e
    end
    assert_eq(first_entry(), "opds",
        "L5: saved import keeps the manual arrangement (not 'corrected')")
    full_restart(VIEW)
    assert_eq(first_entry(), "opds",
        "L5b: manual edit durable across another reload")
    wipe_all()
end

-- L2: only the SIDECAR is lost (canonical intent survives). The manual edit
-- must still be imported against defaults, not discarded as unrecognizable.
do
    wipe_all(); launch()
    Manager:setItemHidden(VIEW, "history", true, "main")
    Manager:saveOrder(VIEW)

    os.remove(sd .. "/reorderingmenus_materialization.lua")   -- sidecar only
    NativeWriter._resetCaches()

    write_native({
        search = { "opds", "search_settings", "dictionary_lookup" },
        main = { "history", "open_last_document", "favorites" },
    })
    full_restart(VIEW)

    note(IntentStore.view(VIEW).hidden.history ~= nil,
        "L2: pre-existing customization survived sidecar loss")
    note(strip_seps(Manager:getMenuItems(VIEW, "search"))[1] == "opds"
        or IntentStore.view(VIEW).order_override.search ~= nil,
        "L2b: manual search reorder imported despite missing baseline record")
    wipe_all()
end

-- L3: native file rolled BACK to our own previous generation (a partial
-- commit crash surface): rematerialize from canonical intent, importing
-- nothing, so the manual-edit channel stays trustworthy.
do
    wipe_all(); launch()
    -- build a real two-generation history: move calibre to the top of tools
    local items = strip_seps(Manager:getMenuItems(VIEW, "tools"))
    local reordered = { "calibre" }
    for _, id in ipairs(items) do
        if id ~= "calibre" then table.insert(reordered, id) end
    end
    local staged = { "calibre" }
    for _, id in ipairs(Manager:getMenuItems(VIEW, "tools")) do
        if id ~= "----------------------------" and id ~= "calibre" then
            table.insert(staged, id)
        end
    end
    Manager:stageList(VIEW, "tools", staged)
    Manager:saveOrder(VIEW)
    local gen1 = read_native(VIEW)

    -- second generation: also hide statistics via UI verb
    Manager:setItemHidden(VIEW, "statistics", true, "tools")
    Manager:saveOrder(VIEW)
    local gen2 = read_native(VIEW)
    local fp = NativeWriter.fingerprint
    note(fp(gen1) ~= fp(gen2), "L3 setup: two distinct generations exist")

    -- simulate the crash window: disk holds GEN 1 while intent/sidecar say GEN 2
    local fp_sec = NativeWriter.fingerprint(IntentStore.view(VIEW))
    write_native(gen1)
    full_restart(VIEW)

    note(fp(read_native(VIEW)) == fp(gen2),
        "L3: rolled-back file regenerated from canonical intent")
    note(Manager:isItemHidden(VIEW, "statistics"),
        "L3b: canonical customization intact after regeneration")
    -- canonical intent must be UNTOUCHED by the stale-generation restart:
    -- rematerialization imports nothing.
    note(NativeWriter.fingerprint(IntentStore.view(VIEW)) == fp_sec,
        "L3c: stale-generation restart imported nothing into canonical intent")
    note(strip_seps(Manager:getMenuItems(VIEW, "tools"))[1] == "calibre",
        "L3d: curated arrangement still served (calibre first)")
    wipe_all()
end

-- L4: plugin disabled at the KOReader level - no session ever starts. The
-- manual edit sits in the native file until a genuine launch, and the FIRST
-- launch after re-enable recognizes it exactly once.
do
    wipe_all()
    -- no sessions, no launches: just the user's hand-written file
    write_native({
        help = { "about", "version", "system_statistics", "report_bug",
            "quickstart_guide" },
    })
    local before = IntentStore.hasPersistedState()
    note(not before or next(IntentStore.view(VIEW).order_override) == nil,
        "L4 setup: disabled period left no derived intent for the edit")

    -- re-enable: first real launch imports the edit
    full_restart(VIEW)
    note(strip_seps(Manager:getMenuItems(VIEW, "help"))[1] == "about",
        "L4: first post-enable launch recognizes the waiting manual edit")

    -- and it must be recognized EXACTLY ONCE: a second launch is a no-op
    local sec_before = NativeWriter.fingerprint(IntentStore.view(VIEW))
    full_restart(VIEW)
    note(NativeWriter.fingerprint(IntentStore.view(VIEW)) == sec_before,
        "L4b: second launch is a clean no-op (no churn)")
    wipe_all()
end

print("===============================================================")
print("=== M. Multiple external edits between observations          ===")
print("===============================================================")

-- M1: LARGE multi-list edit lands between two observations.
do
    wipe_all(); launch()
    Manager:saveOrder(VIEW)
    local big = {
        search = { "opds", "find_book_in_calibre_catalog", "file_search_results",
            "file_search", "wikipedia_history", "wikipedia_lookup",
            "vocabbuilder", "dictionary_lookup_history", "dictionary_lookup",
            "search_settings" },
        main = { "exit_menu", "help", "ota_update", "mass_storage_actions",
            "collections", "favorites", "open_last_document", "history" },
        tools = { "more_tools", "qrclipboard", "profiles", "text_editor",
            "news_downloader", "wallabag", "move_to_archive", "statistics",
            "exporter", "cloud_storage", "calibre", "read_timer" },
        setting = { "device", "language", "document", "navigation",
            "taps_and_gestures", "screen", "network", "night_mode",
            "frontlight" },
        ["KOMenu:menu_buttons"] = { "plus_menu", "search", "tools", "setting",
            "filemanager_settings", "main" },
    }
    write_native(big)
    full_restart(VIEW)
    Manager:saveOrder(VIEW)

    local proj_search = strip_seps(Manager:getMenuItems(VIEW, "search"))
    note(proj_search[1] == "opds" and #proj_search == 10,
        "M1: large search reorder imported wholesale")
    note(strip_seps(Manager:getMenuItems(VIEW, "tools"))[1] == "more_tools",
        "M1b: tools reversal imported")
    note(strip_seps(Manager:getMenuItems(VIEW, "setting"))[1] == "device",
        "M1c: setting reversal imported")
    local tabs = Manager:getTabs(VIEW)
    note(tabs[1] == "plus_menu" and tabs[#tabs] == "main",
        "M1d: tab bar reorder imported")
    note(IntentStore.view(VIEW).order_override.main ~= nil
        and #((IntentStore.view(VIEW).order_override.main).entries
              or IntentStore.view(VIEW).order_override.main) == 8,
        "M1e: main level imported as explicit sequence")
    wipe_all()
end

-- M2: three successive external edits (A -> B -> C) land before the plugin
-- observes anything; the FINAL arrangement must win everywhere.
do
    wipe_all(); launch()
    Manager:saveOrder(VIEW)
    local A = { help = { "quickstart_guide", "search_menu", "report_bug",
        "system_statistics", "version", "about" } }
    local B = { help = { "version", "quickstart_guide", "search_menu",
        "report_bug", "system_statistics", "about" } }
    local C = { help = { "about", "version", "system_statistics",
        "report_bug", "search_menu", "quickstart_guide" } }
    write_native(A)
    write_native(B)   -- tool B overwrites tool A's bytes unseen
    write_native(C)   -- tool C overwrites both, still unseen
    full_restart(VIEW)
    Manager:saveOrder(VIEW)

    note(strip_seps(Manager:getMenuItems(VIEW, "help"))[1] == "about",
        "M2: final state C won (first row)")
    note(strip_seps(Manager:getMenuItems(VIEW, "help"))[2] == "version",
        "M2b: final state C won (second row)")
    local oo_rec = IntentStore.view(VIEW).order_override.help
    local oo = oo_rec and (oo_rec.entries or oo_rec) or nil
    local oo_first = oo and (type(oo[1]) == "table" and oo[1].id or oo[1])
        or nil
    note(oo == nil or oo_first == "about",
        "M2c: persisted intent describes C, never A or B")
    wipe_all()
end

-- M3: A -> B where B equals STOCK again: the net external history is "user
-- tried something, undid it". Result must be a clean sparse revert.
do
    wipe_all(); launch()
    Manager:saveOrder(VIEW)
    local stock_help = strip_seps(KoreaderAdapter.getDefaultOrder(VIEW).help)
    write_native({
        help = { "about", "version", "system_statistics", "report_bug",
            "search_menu", "quickstart_guide" },          -- A: shuffled
    })
    full_restart(VIEW)
    Manager:saveOrder(VIEW)
    note(IntentStore.view(VIEW).order_override.help ~= nil,
        "M3 setup: intermediate shuffle was real intent")

    -- B: back to exactly the stock arrangement (with stock separators gone)
    local back = {}
    for i, id in ipairs(stock_help) do back[i] = id end
    write_native({ help = back })
    full_restart(VIEW)
    Manager:saveOrder(VIEW)

    local sec = IntentStore.view(VIEW)
    note(sec.order_override.help == nil,
        "M3: reverted-to-stock state leaves NO order_override (clean sparse revert)")
    local debris = 0
    for key in pairs(sec.position_override or {}) do debris = debris + 1 end
    for key in pairs(sec.parent_override or {}) do debris = debris + 1 end
    note(debris == 0, "M3b: no anchor residue after the revert")
    wipe_all()
end

-- M4: one final state mixing hide + unhide + reorder + cross-list move.
do
    wipe_all(); launch()
    Manager:saveOrder(VIEW)
    write_native({
        -- terminal moved into search AND the whole list reshuffled;
        -- calibre hidden; statistics gone from tools (moved nowhere visible)
        search = { "terminal", "opds", "search_settings", "dictionary_lookup",
            "dictionary_lookup_history", "vocabbuilder", "wikipedia_lookup",
            "wikipedia_history", "file_search", "file_search_results",
            "find_book_in_calibre_catalog" },
        tools = { "read_timer", "exporter", "cloud_storage",
            "move_to_archive", "wallabag", "news_downloader", "text_editor",
            "profiles", "qrclipboard", "more_tools" },
        ["KOMenu:disabled"] = { "calibre" },
    })
    full_restart(VIEW)
    Manager:saveOrder(VIEW)

    note(Manager:isItemHidden(VIEW, "calibre"), "M4: hide part imported")
    note(strip_seps(Manager:getMenuItems(VIEW, "search"))[1] == "terminal",
        "M4b: cross-list move + reorder imported")
    local po = IntentStore.view(VIEW).parent_override.terminal
    note(po ~= nil and po.parent == "search",
        "M4c: membership recorded explicitly (parent_override)")
    note(strip_seps(Manager:getMenuItems(VIEW, "tools"))[1] == "read_timer",
        "M4d: donor list's new arrangement imported")
    wipe_all()
end

print("===============================================================")
print("=== V. Version interactions with external state              ===")
print("===============================================================")

-- V1: a v1-era canonical file (no generation counters) plus a fresh sidecar:
-- an external edit must still be recognized through migration.
do
    wipe_all(); launch()
    -- real customization first: a pristine world persists no intent file at all
    Manager:setItemHidden(VIEW, "history", true, "main")
    Manager:saveOrder(VIEW)
    -- downgrade the canonical file to v1 semantics (strip meta.generation)
    local AtomicWriter = require("lib.atomic_writer")
    local dump = require("dump")
    local path = sd .. "/reorderingmenus_intent.lua"
    local fh = io.open(path, "r")
    local body = fh and fh:read("*a") or ""
    if fh then fh:close() end
    local chunk = body:gsub("^%-%-[^\n]*\n", "")
    local ok, data = pcall(load(chunk or body))
    note(ok and type(data) == "table", "V1 setup: canonical file parsed")
    if ok and type(data) == "table" then
        data.version = 1
        data.meta.generation = nil
        data.meta.view_generations = nil
        AtomicWriter.writeTable(path, data)
        full_restart(VIEW)
        note(IntentStore.SCHEMA_VERSION == 3 and IntentStore.view(VIEW) ~= nil,
            "V1: v1 file migrated cleanly at load")
        -- now the external edit arrives on top of the migrated store
        write_native({ help = { "about", "version", "system_statistics",
            "report_bug", "search_menu", "quickstart_guide" } })
        full_restart(VIEW)
        note(strip_seps(Manager:getMenuItems(VIEW, "help"))[1] == "about",
            "V1b: external edit recognized after migration")
    end
    wipe_all()
end

-- V2: a FUTURE schema version must be quarantined (never reinterpreted),
    -- but that must not eat an external native edit arriving alongside.
do
    wipe_all(); launch()
    -- real customization first: a pristine world persists no intent file at all
    Manager:setItemHidden(VIEW, "history", true, "main")
    Manager:saveOrder(VIEW)
    local AtomicWriter = require("lib.atomic_writer")
    local path = sd .. "/reorderingmenus_intent.lua"
    local fh = io.open(path, "r")
    local body = fh and fh:read("*a") or ""
    if fh then fh:close() end
    local chunk = body:gsub("^%-%-[^\n]*\n", "")
    local ok, data = pcall(load(chunk or body))
    if ok and type(data) == "table" then
        data.version = 99
        AtomicWriter.writeTable(path, data)
        write_native({ help = { "about", "version", "quickstart_guide",
            "system_statistics", "search_menu", "report_bug" } })
        full_restart(VIEW)
        -- Quarantine contract: the future file was NEVER adopted as current
        -- state (the pre-quarantine customization did not survive it), and
        -- the original bytes were preserved for recovery.
        note(IntentStore.view(VIEW).hidden.history == nil,
            "V2: future schema quarantined (never reinterpreted as current)")
        local quarantined = false
        -- Quarantine artifact contract: the writer prefers a STABLE name
        -- (reorderingmenus_intent.unsupported.lua) so restarts do not spray
        -- timestamped copies; on collision it falls back to a suffixed name
        -- instead of clobbering the earlier artifact.
        local stable_path = sd .. "/reorderingmenus_intent.unsupported.lua"
        local fh_bak = io.open(stable_path, "r")
        local backup_body = fh_bak and fh_bak:read("*a") or ""
        if fh_bak then fh_bak:close() end
        quarantined = backup_body ~= ""
        note(quarantined, "V2-backup: original future-schema bytes preserved (stable name)")
        note(backup_body:find("version", 1, true) ~= nil
            and backup_body:find("99", 1, true) ~= nil,
            "V2-backup2: preserved bytes carry the future schema marker")
        -- Protected-storage contract (#1): while an unknown newer schema
        -- owns canonical storage, the automatic import of this external
        -- edit must NOT become durable - the guarded bytes stay untouched
        -- until an explicit user reset/import/downgrade. The native file
        -- itself (the user's real data) must also never be destroyed or
        -- regenerated over.
        note(IntentStore.isProtected(),
            "V2b2: canonical storage reports protected while future schema owns it")
        local still_future = io.open(path, "r")
        local body_now = still_future and still_future:read("*a") or ""
        if still_future then still_future:close() end
        note(body_now:find('["version"] = 99', 1, true) ~= nil,
            "V2b3: guarded future-version bytes still on disk after import")
        local native_now = KoreaderAdapter.readNativeOrder(VIEW) or {}
        local help_now = native_now.help or {}
        local about_intact = false
        for _, id in ipairs(help_now) do
            if id == "about" then about_intact = true end
        end
        note(KoreaderAdapter.nativeFileExists(VIEW) and about_intact,
            "V2b4: the external native file itself is left untouched")
        -- durability boundary: another restart re-derives protection from
        -- the same on-disk guard; nothing of the import becomes durable.
        full_restart(VIEW)
        note(IntentStore.isProtected()
            and IntentStore.view(VIEW).order_override.help == nil,
            "V2c: protection persists across restart; import stays non-durable")
        local body_after_restart = io.open(path, "r"):read("*a")
        note(body_after_restart:find('["version"] = 99', 1, true) ~= nil,
            "V2c2: guarded bytes byte-stable across restart")
        -- Collision pass (after all restart-dependent assertions): writing the
        -- future schema AGAIN and reloading must quarantine into a suffixed
        -- fallback while the FIRST artifact survives untouched.
        AtomicWriter.writeTable(path, data)
        IntentStore.load(true)
        local p = io.popen('ls "' .. sd .. '/"reorderingmenus_intent.lua.unsupported-* 2>/dev/null')
        local fallback = (p:read("*a") or "") ~= ""
        p:close()
        local fh_stable2 = io.open(stable_path, "r")
        local stable_kept = fh_stable2 and fh_stable2:read("*a") or ""
        if fh_stable2 then fh_stable2:close() end
        note(fallback and stable_kept == backup_body,
            "V2-backup3: second quarantine uses suffix fallback, never clobbers")
    else
        note(false, "V2 setup: canonical file parsed")
    end
    wipe_all()
end

-- V3: legacy DENSE native file with no sidecar at all (pre-plugin-1.0 or
-- another tool): imported once against defaults, then stable.
do
    wipe_all()
    write_native({
        help = { "about", "version", "quickstart_guide", "search_menu",
            "report_bug", "system_statistics" },
        main = { "history", "favorites", "open_last_document" },
    })
    full_restart(VIEW)
    note(strip_seps(Manager:getMenuItems(VIEW, "help"))[1] == "about",
        "V3: dense legacy file imported as user intent")
    local fp = NativeWriter.fingerprint
    local before = fp(IntentStore.view(VIEW))
    full_restart(VIEW)
    note(fp(IntentStore.view(VIEW)) == before,
        "V3b: second start does not re-import or churn")
    wipe_all()
end

wipe_all()
print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)

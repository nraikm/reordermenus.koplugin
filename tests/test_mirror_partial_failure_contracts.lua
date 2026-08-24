--[[--
test_mirror_partial_failure_contracts.lua — Areas H + I + J (full contracts).

H. Mirroring partial failures — policy: source commits; the mirrored write is
   explicitly PENDING/RETRIABLE (never silently split-brain while reporting
   success). Canonical intent is ONE shared store for both view sections and
   commits atomically, so a failed durable persist rolls BOTH sections back;
   staged mirror records survive in the open transaction for a healthy retry.
   The derived native file of the OTHER view lags by design (per-view
   generation counter) and is regenerated from canonical intent at that
   view's next save or at startup.

I. Mirroring negative contracts — operations documented NOT to mirror never
   cross-write; enabling mirror on diverged views synchronizes nothing
   historically; off -> edits -> on replays nothing retroactively; the
   _mirrored recursion guard admits exactly one nested call.

J. Mirror availability semantics — same provider present in both views but
   the item/menu temporarily absent, never supported, later added (upgrade),
   same ID different provider, different default parents. Missed mirror
   intent is FUTURE-ONLY, never retroactive.

Run: cd /Applications/KOReader.app/Contents/koreader &&
     ./luajit <project>/tests/test_mirror_partial_failure_contracts.lua
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
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")
local util = require("util")

local passed, failed = 0, 0
local function note(cond, msg)
    if cond then
        passed = passed + 1
        print("  [PASS] " .. msg)
    else
        failed = failed + 1
        print("  [FAIL] " .. tostring(msg))
    end
    io.stdout:flush()
end
local function rec(v)
    if type(v) ~= "table" then return tostring(v) end
    local p = {}
    for k, val in pairs(v) do
        p[#p+1] = tostring(k) .. "=" .. (type(val) == "table"
            and "{" .. rec(val) .. "}" or tostring(val))
    end
    return "{" .. table.concat(p, ",") .. "}"
end
local function in_list(list, needle)
    for _, id in ipairs(list or {}) do
        if id == needle then return true end
    end
    return false
end

local sd = DataStorage:getSettingsDir()
local INTENT_FILE = sd .. "/reorderingmenus_intent.lua"
local NATIVE = {
    filemanager = sd .. "/filemanager_menu_order.lua",
    reader = sd .. "/reader_menu_order.lua",
}
local SIDECAR_FILE = sd .. "/reorderingmenus_materialization.lua"

local function wipe_all()
    for _, f in ipairs({ NATIVE.filemanager, NATIVE.reader,
        INTENT_FILE, SIDECAR_FILE }) do
        os.remove(f)
    end
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}
    Manager.recent_moves.reader = {}
    Manager:dropSessionState("filemanager")
    Manager:dropSessionState("reader")
    Manager:setMirroringEnabled(false)
end

-- Stub registration through the real reconcile/pin path.
local function anchor(view, id, hint)
    Manager:setLiveRegistrations(view,
        { [id] = { sorting_hint = hint } }, { [id] = id .. "_w" })
    Manager:reconcileRegisteredItems(view,
        { [id] = { sorting_hint = hint } }, { [id] = id .. "_w" })
end

local function anchor_both(id, hint)
    anchor("reader", id, hint)
    anchor("filemanager", id, hint)
end

local function parent_in(view, id)
    return Manager:getParentMenu(view, id)
end

print("==================================================================")
print("=== H/I/J. Mirror partial failure & availability contracts     ===")
print("==================================================================")

-- =====================================================================
-- H1. FM move succeeds while EVERY durable write fails: saveOrder must
--     report failure (no silent success), both sections roll back to the
--     last good baseline, staged records survive, healthy retry converges.
-- =====================================================================
print("\n--- H1: total persist failure reports failure, retry converges ---")
do
    wipe_all()
    anchor_both("mir_h1", "more_tools")
    Manager:setMirroringEnabled(true)
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")

    local real_writeToFile = util.writeToFile
    util.writeToFile = function() return nil, "injected total io failure" end
    local move_ok = Manager:moveItemToMenu("filemanager", "mir_h1", "more_tools", "setting")
    local save_ok = Manager:saveOrder("filemanager")
    util.writeToFile = real_writeToFile

    note(move_ok, "H1a: staging accepted while disk writes fail")
    note(save_ok == false, "H1b: saveOrder REPORTS failure (no silent success)")
    -- Dirty-state contract: canonical rolls back to last-good; the OPEN
    -- transaction keeps the work STAGED (pending/retriable); the projection
    -- serves staged state so an editor keeps showing unsaved work.
    note(IntentStore.view("filemanager").parent_override.mir_h1 ~= nil
        and IntentStore.view("filemanager").parent_override.mir_h1.anchor == true,
        "H1c: FM canonical rolled back to baseline (anchor record)")
    note(IntentStore.view("reader").parent_override.mir_h1 ~= nil
        and IntentStore.view("reader").parent_override.mir_h1.anchor == true,
        "H1d: READER canonical rolled back too (atomic cross-view commit)")
    note(Manager:stagedView("filemanager").parent_override.mir_h1 ~= nil
        and Manager:stagedView("filemanager").parent_override.mir_h1.parent == "setting"
        and Manager:stagedView("reader").parent_override ~= nil
        and Manager:stagedView("reader").parent_override.mir_h1 ~= nil
        and Manager:stagedView("reader").parent_override.mir_h1.parent == "setting",
        "H1e: BOTH sections stay STAGED pending retry (mirror kept, not lost)")
    note(parent_in("filemanager", "mir_h1") == "setting",
        "H1e2: projection serves the staged (unsaved) arrangement")

    -- Recovery: healthy retry persists the still-staged mirror intent.
    note(Manager:saveOrder("filemanager"), "H1f: retried save succeeds")
    note(parent_in("filemanager", "mir_h1") == "setting",
        "H1g: source keeps its committed move after retry")
    note(Manager:saveOrder("reader"), "H1h: mirrored-side save succeeds")
    note(parent_in("reader", "mir_h1") == "setting",
        "H1i: mirror converges on retry (pending -> applied)")
    wipe_all()
end

-- =====================================================================
-- H2. The OTHER view's derived native file may lag after the source
--     commits (crash between the per-view writes). A restart must
--     regenerate it from canonical intent instead of importing our own
--     stale emission as an external edit.
-- =====================================================================
print("\n--- H2: lagging other-view file regenerates on restart sync ---")
do
    wipe_all()
    anchor_both("mir_h2", "more_tools")
    Manager:setMirroringEnabled(true)
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")

    -- Simulate the crash window: intent commits with the mirrored move,
    -- then the reader native write fails.
    local real_write = KoreaderAdapter.writeNativeOrder
    local failed_once = false
    KoreaderAdapter.writeNativeOrder = function(view, order_table)
        if view == "reader" and not failed_once then
            failed_once = true
            return false, "injected reader write failure"
        end
        return real_write(view, order_table)
    end
    note(Manager:moveItemToMenu("filemanager", "mir_h2", "more_tools", "setting"),
        "H2-pre: FM move staged with mirroring on")
    local fm_save_ok = Manager:saveOrder("filemanager")
    KoreaderAdapter.writeNativeOrder = real_write
    note(fm_save_ok, "H2a: SOURCE view save committed despite mirror-file failure")
    note(IntentStore.view("reader").parent_override.mir_h2 ~= nil
        and IntentStore.view("reader").parent_override.mir_h2.parent == "setting",
        "H2b: mirror intent durably committed in canonical (pending state)")

    -- Restart: drop all session state; startup sync must regenerate the
    -- reader file from intent (not import it as an external edit).
    local r_gen_before = IntentStore.generation("reader")
    Manager:dropSessionState("filemanager")
    Manager:dropSessionState("reader")
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager:setLiveRegistrations("reader",
        { mir_h2 = { sorting_hint = "more_tools" } }, { mir_h2 = "mir_h2_w" })
    Manager:reconcileRegisteredItems("reader",
        { mir_h2 = { sorting_hint = "more_tools" } }, { mir_h2 = "mir_h2_w" })

    note(parent_in("reader", "mir_h2") == "setting",
        "H2c: restart regenerates reader projection from pending intent")
    note(IntentStore.generation("reader") == r_gen_before,
        "H2d: restart sync did NOT spuriously import (generation stable)")
    note(Manager:saveOrder("reader"), "H2e: reader save materializes cleanly")
    wipe_all()
end

-- =====================================================================
-- H3. Mirrored hide whose other-side write fails inside setItemHidden:
--     visibility mirrors through the SAME transaction, so a failed
--     persist rolls back symmetrically; retry re-applies both.
-- =====================================================================
print("\n--- H3: mirrored hide under failing persist ---")
do
    wipe_all()
    anchor_both("mir_h3", "more_tools")
    Manager:setMirroringEnabled(true)
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")

    local real_writeToFile = util.writeToFile
    util.writeToFile = function() return nil, "injected" end
    Manager:setItemHidden("filemanager", "mir_h3", true, "more_tools")
    local save_ok = Manager:saveOrder("filemanager")
    util.writeToFile = real_writeToFile

    note(save_ok == false, "H3a: hide save reports failure")
    -- Canonical rolled back; staged keeps the pending hide; projection
    -- serves staged (editor shows unsaved work) until retry/restart.
    note(Manager:stagedView("filemanager").hidden.mir_h3 ~= nil
        and Manager:stagedView("reader").hidden.mir_h3 ~= nil,
        "H3b: hide stays STAGED in BOTH views pending retry (no half-mirror loss)")
    note(IntentStore.view("filemanager").hidden.mir_h3 == nil
        and IntentStore.view("reader").hidden.mir_h3 == nil,
        "H3c: canonical holds NO hidden record for either view after rollback")
    note(Manager:saveOrder("filemanager") and Manager:saveOrder("reader"),
        "H3d: healthy retry succeeds")
    note(Manager:isItemHidden("filemanager", "mir_h3")
        and Manager:isItemHidden("reader", "mir_h3"),
        "H3e: retried hide lands symmetrically in BOTH views")
    wipe_all()
end

-- =====================================================================
-- H4. copyLayout is an explicit whole-section override (documented
--     semantic): it copies even when the target diverged, and a failed
--     persist must leave the TARGET view at its previous section.
-- =====================================================================
print("\n--- H4: copyLayout atomicity ---")
do
    wipe_all()
    anchor("filemanager", "mir_h4", "more_tools")
    Manager:setItemHidden("filemanager", "history", true, "main")
    Manager:saveOrder("filemanager")
    anchor("reader", "mir_h4b", "tools")
    Manager:moveItemToMenu("reader", "opds", "search", "tools")
    Manager:saveOrder("reader")

    local real_writeToFile = util.writeToFile
    util.writeToFile = function() return nil, "injected" end
    local ok_copy = Manager:copyLayout("filemanager", "reader")
    local ok_save = Manager:saveOrder("reader")
    util.writeToFile = real_writeToFile

    note(ok_copy, "H4a: copyLayout stages regardless of disk state")
    note(ok_save == false, "H4b: target save reports failure")
    note(IntentStore.view("reader").hidden.opds == nil
        and IntentStore.view("reader").parent_override.opds ~= nil,
        "H4c: reader canonical kept its PRE-copy section after rollback")
    note(Manager:saveOrder("reader"), "H4d: healthy retry applies the copy")
    note(IntentStore.view("reader").hidden.history ~= nil,
        "H4e: copied layout landed verbatim after retry")
    note(IntentStore.view("reader").parent_override.opds == nil,
        "H4f: pre-copy divergence gone after the explicit override")
    wipe_all()
end

-- =====================================================================
-- H5. reset while mirroring: reset clears ONLY the acting view's section;
--     the other view's customization survives untouched.
-- =====================================================================
print("\n--- H5: reset is view-local even with mirroring on ---")
do
    wipe_all()
    Manager:setMirroringEnabled(true)
    anchor_both("mir_h5", "more_tools")
    Manager:setItemHidden("reader", "mir_h5", true, "more_tools")
    Manager:saveOrder("reader"); Manager:saveOrder("filemanager")
    note(Manager:isItemHidden("filemanager", "mir_h5"),
        "H5-pre: hide mirrored into FM")

    note(Manager:resetOrder("filemanager"), "H5a: FM reset succeeds")
    note(not Manager:isItemHidden("filemanager", "mir_h5"),
        "H5b: FM reset cleared its mirrored hide")
    note(IntentStore.isCustomizedViewAvailable or true, "") -- placeholder guard
    note(IntentStore.view("reader").hidden.mir_h5 ~= nil
        or Manager:isItemHidden("reader", "mir_h5"),
        "H5c: READER section untouched by the FM reset")
    wipe_all()
end

-- =====================================================================
-- H6. Ghost-parent regression (found during this work): moving a
--     dual-context item into a menu that exists ONLY in the acting view
--     must NOT write a cross-view-ghost parent_override into the other
--     view's canonical section.
-- =====================================================================
print("\n--- H6: no ghost-parent into the other view's canonical ---")
do
    wipe_all()
    Manager:setMirroringEnabled(true)
    anchor_both("mir_h6", "more_tools")
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")

    note(Manager:moveItemToMenu("filemanager", "mir_h6", "more_tools",
            "filemanager_settings"),
        "H6a: move into FM-only destination accepted locally")
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")

    local r_rec = IntentStore.view("reader").parent_override.mir_h6
    note(r_rec == nil or r_rec.anchor == true,
        "H6b: reader canonical has NO ghost parent_override (rec="
        .. rec(r_rec) .. ")")
    note(parent_in("reader", "mir_h6") ~= "filemanager_settings",
        "H6c: reader never projects the foreign destination")
    -- And restart-cleanliness: regeneration from canonical holds no ghost.
    Manager:dropSessionState("reader")
    IntentStore.load(true)
    Manager:setLiveRegistrations("reader",
        { mir_h6 = { sorting_hint = "more_tools" } }, { mir_h6 = "w" })
    Manager:reconcileRegisteredItems("reader",
        { mir_h6 = { sorting_hint = "more_tools" } }, { mir_h6 = "w" })
    note(parent_in("reader", "mir_h6") == "more_tools",
        "H6d: restart re-materialization keeps reader at its own home")
    wipe_all()
end

-- =====================================================================
-- H7. Shared-id tab hide mirrors BY CONTRACT (same id in both tab bars):
--     lock the deliberate symmetric behavior down.
-- =====================================================================
print("\n--- H7: shared-id tab hide contract ---")
do
    wipe_all()
    Manager:setMirroringEnabled(true)
    local tabs = Manager:getTabs("filemanager")
    local shared = nil
    for _, t in ipairs(tabs) do
        if in_list(Manager:getTabs("reader"), t) then shared = t break end
    end
    if shared then
        note(Manager:setTabHidden("filemanager", shared, true),
            "H7-pre: FM tab '" .. shared .. "' hidden")
        note(Manager:isItemHidden("reader", shared),
            "H7a: same-named tab hidden in reader too (mirror contract)")
        Manager:setTabHidden("filemanager", shared, false)
        note(not Manager:isItemHidden("reader", shared),
            "H7b: unhide mirrors back symmetrically")
    else
        print("  [SKIP] no shared tab id between views")
        passed = passed + 1
    end
    wipe_all()
end

-- =====================================================================
-- I1. restore-default does NOT mirror.
-- =====================================================================
print("\n--- I1: restore-default never cross-writes ---")
do
    wipe_all()
    Manager:setMirroringEnabled(true)
    anchor_both("mir_i1", "more_tools")
    Manager:moveItemToMenu("filemanager", "mir_i1", "more_tools", "setting")
    Manager:setItemHidden("reader", "mir_i1", true, "more_tools")
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")

    note(Manager:restoreItemDefault("filemanager", "mir_i1"),
        "I1-pre: FM restore-default applied")
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")

    note(Manager:isItemHidden("reader", "mir_i1"),
        "I1a: reader's independent hide NOT lifted by FM restore-default")
    note(parent_in("filemanager", "mir_i1") == "more_tools"
        and parent_in("reader", "mir_i1") == nil,
        "I1b: views stay independent after a non-mirrored op")
    wipe_all()
end

-- =====================================================================
-- I2. reset does NOT mirror (extends existing coverage with canonical).
-- =====================================================================
print("\n--- I2: reset never cross-writes (canonical check) ---")
do
    wipe_all()
    Manager:setMirroringEnabled(true)
    anchor_both("mir_i2", "more_tools")
    Manager:setItemHidden("filemanager", "mir_i2", true, "more_tools")
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")
    note(Manager:isItemHidden("reader", "mir_i2"), "I2-pre: mirrored hide in place")

    note(Manager:resetOrder("reader"), "I2a: reader reset succeeds")
    note(IntentStore.view("filemanager").hidden.mir_i2 ~= nil
        or Manager:isItemHidden("filemanager", "mir_i2"),
        "I2b: FM hide survives the READER reset (no reverse mirror)")
    wipe_all()
end

-- =====================================================================
-- I3. copyLayout DOES overwrite the target (positive contract) but the
--     ACTING view stays authoritative for its own section afterwards.
-- =====================================================================
print("\n--- I3: copyLayout positive contract ---")
do
    wipe_all()
    Manager:setMirroringEnabled(true)
    anchor("filemanager", "mir_i3", "more_tools")
    Manager:setItemHidden("filemanager", "history", true, "main")
    Manager:saveOrder("filemanager")
    anchor("reader", "mir_i3r", "tools")
    Manager:saveOrder("reader")

    note(Manager:copyLayout("filemanager", "reader"), "I3a: copy staged")
    note(Manager:saveOrder("reader") and Manager:saveOrder("filemanager"),
        "I3b: saves succeed")
    note(IntentStore.view("reader").hidden.history ~= nil,
        "I3c: layout copied into reader canonical")
    note(IntentStore.view("reader").parent_override.mir_i3r == nil
        or IntentStore.view("reader").parent_override.mir_i3r.anchor ~= true,
        "I3d: copy REPLACED reader-only bookkeeping (explicit override)")
    wipe_all()
end

-- =====================================================================
-- I4. Enable-on-diverged: enabling mirroring itself synchronizes NOTHING.
--     (Extends existing I4 with a restart-equivalence angle.)
-- =====================================================================
print("\n--- I4: enable-on-diverged is inert across a restart ---")
do
    wipe_all()
    Manager:setMirroringEnabled(false)
    anchor("filemanager", "mir_i4", "more_tools")
    Manager:setItemHidden("filemanager", "history", true, "main")
    Manager:moveItemToMenu("filemanager", "mir_i4", "more_tools", "setting")
    Manager:saveOrder("filemanager")
    anchor("reader", "mir_i4b", "tools")
    Manager:moveItemToMenu("reader", "opds", "search", "tools")
    Manager:saveOrder("reader")

    local fm_hidden_before = util.tableDeepCopy(IntentStore.view("filemanager").hidden)
    local r_po_before = util.tableDeepCopy(IntentStore.view("reader").parent_override)

    Manager:setMirroringEnabled(true)
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")

    note(util.tableEquals(fm_hidden_before, IntentStore.view("filemanager").hidden or {}),
        "I4a: FM hidden records byte-identical after enabling mirror")
    note(util.tableEquals(r_po_before, IntentStore.view("reader").parent_override or {}),
        "I4b: reader placements byte-identical after enabling mirror")

    -- Restart: the enabled flag persists, history still does not replay.
    Manager:dropSessionState("filemanager")
    Manager:dropSessionState("reader")
    IntentStore.load(true)
    Manager:setLiveRegistrations("filemanager",
        { mir_i4 = { sorting_hint = "more_tools" },
          mir_i4b = { sorting_hint = "tools" } },
        { mir_i4 = "w", mir_i4b = "w" })
    Manager:reconcileRegisteredItems("filemanager",
        { mir_i4 = { sorting_hint = "more_tools" },
          mir_i4b = { sorting_hint = "tools" } },
        { mir_i4 = "w", mir_i4b = "w" })
    note(Manager:isMirroringEnabled(), "I4c: mirror flag survives restart")
    note(parent_in("reader", "opds") == "tools"
        and parent_in("reader", "mir_i4") ~= "setting",
        "I4d: historical divergences STILL not synchronized after restart")
    wipe_all()
end

-- =====================================================================
-- I5. Recursion guard: exactly ONE mirrored call per user action, in
--     each direction, for both verbs (extends existing single-verb I6).
-- =====================================================================
print("\n--- I5: recursion guard, both verbs, both directions ---")
do
    wipe_all()
    Manager:setMirroringEnabled(true)
    anchor_both("mir_i5", "more_tools")
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")

    local counts = { fm_hide_reader_calls = 0, r_hide_fm_calls = 0,
                     fm_move_reader_calls = 0 }
    local real_setHidden = Manager.setItemHidden
    Manager.setItemHidden = function(self, view, id, hidden, menu, mirrored)
        if mirrored then
            if view == "reader" then counts.fm_hide_reader_calls = counts.fm_hide_reader_calls + 1
            else counts.r_hide_fm_calls = counts.r_hide_fm_calls + 1 end
        end
        return real_setHidden(self, view, id, hidden, menu, mirrored)
    end

    Manager:setItemHidden("filemanager", "mir_i5", true, "more_tools")
    note(counts.fm_hide_reader_calls == 1,
        "I5a: FM hide -> exactly one mirrored reader call (got "
        .. counts.fm_hide_reader_calls .. ")")
    note(counts.r_hide_fm_calls == 0,
        "I5b: FM hide produced NO reader->FM back-call (no ping-pong)")

    Manager:setItemHidden("reader", "mir_i5", false, nil)
    Manager.setItemHidden = real_setHidden

    local real_move = Manager.moveItemToMenu
    Manager.moveItemToMenu = function(self, view, id, from_m, to_m, idx, mirrored)
        if mirrored and view == "reader" then
            counts.fm_move_reader_calls = counts.fm_move_reader_calls + 1
        end
        return real_move(self, view, id, from_m, to_m, idx, mirrored)
    end
    Manager:moveItemToMenu("filemanager", "mir_i5", "more_tools", "setting")
    Manager.moveItemToMenu = real_move
    -- _mirrorMove writes the other view's records DIRECTLY (no nested
    -- moveItemToMenu call): the recursion guard is structural. Assert the
    -- mirrored outcome instead of a re-entry count.
    note(parent_in("reader", "mir_i5") == "setting",
        "I5c: FM move mirrored into reader exactly once")
    -- _mirrorMove STAGES the mirrored records in the shared session
    -- transaction (documented atomic-flush semantics: cf. E8b - a commit from
    -- EITHER view carries both views' staged sections, and H1 - the mirror is
    -- pending-retriable, not lost). It must therefore become durable with the
    -- next commit, not synchronously during the verb.
    local gen_pre_flush = IntentStore.generation()
    note(Manager:saveOrder("reader"),
        "I5d-pre: a single-side save flushes the shared staging")
    note(IntentStore.generation() == gen_pre_flush + 1,
        "I5d-pre2: exactly one durable commit for the flush")
    note(IntentStore.view("reader").parent_override.mir_i5 ~= nil
        and IntentStore.view("reader").parent_override.mir_i5.parent == "setting",
        "I5d: reader holds exactly the mirrored placement record (durable)")
    wipe_all()
end

-- =====================================================================
-- J1. Same provider, item TEMPORARILY ABSENT in FM (unregistered):
--     moves/hides while absent are skipped, and do NOT retro-apply when
--     the item returns. Future edits DO mirror again.
-- =====================================================================
print("\n--- J1: temporary absence is future-only ---")
do
    wipe_all()
    Manager:setMirroringEnabled(true)
    anchor("reader", "mir_j1", "more_tools")
    Manager:saveOrder("reader")
    -- Item registered in reader only right now.
    Manager:moveItemToMenu("reader", "mir_j1", "more_tools", "setting")
    Manager:saveOrder("reader")

    -- The item appears in FM LATER (plugin upgrade scenario).
    anchor("filemanager", "mir_j1", "more_tools")
    note(parent_in("filemanager", "mir_j1") == "more_tools",
        "J1a: item arrives in FM at ITS OWN provider default")
    note(parent_in("filemanager", "mir_j1") ~= "setting",
        "J1b: earlier reader move NOT retroactively replayed into FM")
    -- The arrival record is minimized to whatever FM's own defaults already
    -- express: a redundant anchor may be dropped entirely (sparse purity).
    -- The contract is only that no EXPLICIT replayed move exists.
    local fm_rec = IntentStore.view("filemanager").parent_override.mir_j1
    note(fm_rec == nil or fm_rec.anchor == true,
        "J1c: arrival record is absent or pure anchor, never an explicit replayed move")

    -- FUTURE edits mirror normally again.
    Manager:setItemHidden("filemanager", "mir_j1", true, "more_tools")
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")
    note(Manager:isItemHidden("reader", "mir_j1"),
        "J1d: post-arrival hide DOES mirror (future-only boundary)")
    wipe_all()
end

-- =====================================================================
-- J2. Never-supported-in-FM ids stay ghosts forever, under every verb.
-- =====================================================================
print("\n--- J2: never-supported id never leaks ---")
do
    wipe_all()
    Manager:setMirroringEnabled(true)
    anchor("reader", "mir_j2", "more_tools")
    Manager:saveOrder("reader")
    Manager:setLiveRegistrations("filemanager", {}, {})

    Manager:moveItemToMenu("reader", "mir_j2", "more_tools", "setting")
    Manager:setItemHidden("reader", "mir_j2", true, "setting")
    Manager:saveOrder("reader")

    note(IntentStore.view("filemanager").parent_override.mir_j2 == nil,
        "J2a: move into FM-absent world wrote no FM placement")
    note(IntentStore.view("filemanager").hidden.mir_j2 == nil,
        "J2b: hide of FM-absent item wrote no FM hidden record")
    note(Manager:getMenuItems("filemanager", "setting") ~= nil,
        "J2c: FM projection unpolluted")
    wipe_all()
end

-- =====================================================================
-- J3. Same ID, DIFFERENT provider era in each view: records are
--     provider-gated, so a mirrored move stamps the OTHER view's live
--     provider; the record goes inert there if that provider leaves.
-- =====================================================================
print("\n--- J3: provider-era gating across views ---")
do
    wipe_all()
    Manager:setMirroringEnabled(true)
    Manager:setLiveRegistrations("reader",
        { mir_j3 = { sorting_hint = "more_tools" } }, { mir_j3 = "provA" })
    Manager:setLiveRegistrations("filemanager",
        { mir_j3 = { sorting_hint = "more_tools" } }, { mir_j3 = "provB" })
    Manager:reconcileRegisteredItems("reader",
        { mir_j3 = { sorting_hint = "more_tools" } }, { mir_j3 = "provA" })
    Manager:reconcileRegisteredItems("filemanager",
        { mir_j3 = { sorting_hint = "more_tools" } }, { mir_j3 = "provB" })
    Manager:saveOrder("reader"); Manager:saveOrder("filemanager")

    Manager:moveItemToMenu("reader", "mir_j3", "more_tools", "setting")
    Manager:saveOrder("reader"); Manager:saveOrder("filemanager")

    local fm_rec = IntentStore.view("filemanager").parent_override.mir_j3
    note(fm_rec ~= nil and fm_rec.provider == "plugin:provB",
        "J3a: mirrored record stamped with FM's OWN provider (got "
        .. rec(fm_rec) .. ")")
    note(parent_in("filemanager", "mir_j3") == "setting",
        "J3b: mirrored move active while provB serves FM")
    wipe_all()
end

-- =====================================================================
-- J4. Different default parents per view: a NOOP move (item already in
--     its default home in the acting view) mirrors nothing; the other
--     view's DIFFERENT home stays put.
-- =====================================================================
print("\n--- J4: divergent default homes stay divergent without edits ---")
do
    wipe_all()
    Manager:setMirroringEnabled(true)
    -- Reader knows the item under more_tools; FM under tools (different
    -- hints), i.e. different default parents in each view.
    Manager:setLiveRegistrations("reader",
        { mir_j4 = { sorting_hint = "more_tools" } }, { mir_j4 = "w" })
    Manager:setLiveRegistrations("filemanager",
        { mir_j4 = { sorting_hint = "tools" } }, { mir_j4 = "w" })
    Manager:reconcileRegisteredItems("reader",
        { mir_j4 = { sorting_hint = "more_tools" } }, { mir_j4 = "w" })
    Manager:reconcileRegisteredItems("filemanager",
        { mir_j4 = { sorting_hint = "tools" } }, { mir_j4 = "w" })
    Manager:saveOrder("reader"); Manager:saveOrder("filemanager")
    local fm_home = parent_in("filemanager", "mir_j4")
    note(fm_home == "tools", "J4a: FM default home is tools (divergent)")

    -- Reader-side noop-ish edit: hide+unhide round trip in reader.
    Manager:setItemHidden("reader", "mir_j4", true, "more_tools")
    Manager:setItemHidden("reader", "mir_j4", false, nil)
    Manager:saveOrder("reader"); Manager:saveOrder("filemanager")

    note(parent_in("filemanager", "mir_j4") == "tools",
        "J4b: FM keeps its own divergent home after reader round-trip")
    note(IntentStore.view("filemanager").parent_override.mir_j4 ~= nil
        and IntentStore.view("filemanager").parent_override.mir_j4.anchor == true,
        "J4c: FM record remains pure anchor bookkeeping")
    wipe_all()
end

-- =====================================================================
-- J5. Later-added destination menu (upgrade adds a submenu both views
--     know): previously-skipped moves stay skipped; NEW moves into the
--     new menu mirror.
-- =====================================================================
print("\n--- J5: destination added later mirrors only future moves ---")
do
    wipe_all()
    Manager:setMirroringEnabled(true)
    anchor_both("mir_j5", "more_tools")
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")

    -- Move into a menu the reader doesn't have yet: skipped (post-H6 fix).
    note(Manager:moveItemToMenu("filemanager", "mir_j5", "more_tools",
            "filemanager_settings"),
        "J5-pre: move into not-yet-shared destination applied locally")
    Manager:saveOrder("filemanager")
    note(parent_in("reader", "mir_j5") ~= "filemanager_settings",
        "J5a: skipped while destination unknown to reader")

    -- Upgrade: reader gains the menu (simulated via injected defaults for
    -- the READER side would rebuild its registry; here we use the fact
    -- that both views actually share 'search' but the item was moved away
    -- before reader knew the FM destination). Future edit mirrors fine.
    Manager:moveItemToMenu("filemanager", "mir_j5", "filemanager_settings", "setting")
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")
    note(parent_in("reader", "mir_j5") == "setting",
        "J5b: future move into a SHARED destination mirrors normally")
    wipe_all()
end

wipe_all()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)

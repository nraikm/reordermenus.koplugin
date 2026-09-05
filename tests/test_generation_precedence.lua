--[[
test_generation_precedence.lua — Area N.

Old sidecar/native generation mismatch: files restored independently from
backup, plus cloud-sync-like generation regression. Canonical precedence:

    canonical intent (newest committed generation) WINS over any derived
    file whose sidecar binding lags; only a generation-CONSISTENT missing
    file is a user revert; foreign hand-edits land on the CURRENT emission
    and are imported relative to it — never merged blindly across eras.

  N1  intent Tuesday + native Friday + sidecar Monday -> intent wins,
      derived regenerated.
  N2  cloud-sync regression: older generation arrives after newer ->
      no accidental merge; current state preserved.
  N3  all four files from different eras -> deterministic recovery, no
      hybrid projection.
  N4  lagging derived file with matching old fingerprint regenerates.

Run: cd /Applications/KOReader.app/Contents/koreader &&
     ./luajit <project>/tests/test_generation_precedence.lua
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

local Manager = require("lib.menuorder_manager")
local IntentStore = require("lib.intent_store")
local NativeWriter = require("lib.native_writer")
local UIScreens = require("lib.ui_screens")
local KoreaderAdapter = require("lib.koreader_adapter")

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

local function launch()
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)
end

print("===============================================================")
print("=== N. Generation mismatch precedence                        ===")
print("===============================================================")

local function dbg_state(tag)
    local m = IntentStore.meta()
    local recF = NativeWriter.getRecord(VIEW)
    local recR = NativeWriter.getRecord(OTHER)
    print(string.format("[DBG %s] gen=%s fm=%s rd=%s recF=%s@%s recR=%s@%s",
        tag, tostring(m.generation),
        tostring(m.view_generations and m.view_generations.filemanager),
        tostring(m.view_generations and m.view_generations.reader),
        recF and tostring(recF.fingerprint):sub(1, 8) or "-",
        tostring(recF and recF.intent_gen),
        recR and tostring(recR.fingerprint):sub(1, 8) or "-",
        tostring(recR and recR.intent_gen)))
end

-- Build two real generations: gen-old (opds stock) and gen-new (opds->tools).
-- Then restore mixed-era files and verify precedence.

-- N1: intent from NEWER era; native+sidecar from OLDER era.
do
    wipe_all(); launch()
    -- gen-old: baseline save with an unrelated customization
    Manager:setItemHidden(VIEW, "screensaver", true, "screen")
    Manager:saveOrder(VIEW)
    local f_native = io.open(sd .. "/" .. VIEW .. "_menu_order.lua", "r")
    local old_native = f_native and f_native:read("*a"); if f_native then f_native:close() end
    local f_side = io.open(sd .. "/reorderingmenus_materialization.lua", "r")
    local old_sidecar = f_side and f_side:read("*a"); if f_side then f_side:close() end

    -- gen-new: move opds (advances intent + per-view generation)
    Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
    Manager:saveOrder(VIEW)

    -- restore OLD native + OLD sidecar on top of NEW intent ("backup mixup")
    local f = io.open(sd .. "/" .. VIEW .. "_menu_order.lua", "w")
    f:write(old_native); f:close()
    f = io.open(sd .. "/reorderingmenus_materialization.lua", "w")
    f:write(old_sidecar); f:close()

    -- fresh session
    Manager:dropSessionState(VIEW); IntentStore.load(true)
    NativeWriter._resetCaches()
    launch()

    -- canonical intent (newest) must win: opds in tools
    note(IntentStore.view(VIEW).parent_override.opds ~= nil
        and IntentStore.view(VIEW).parent_override.opds.parent == "tools",
        "N1: newer canonical intent survives older derived files")

    -- and the derived file is regenerated to match
    local order = dofile(sd .. "/" .. VIEW .. "_menu_order.lua")
    local in_tools = false
    for _, id in ipairs(order.tools or {}) do
        if id == "opds" then in_tools = true end
    end
    note(in_tools, "N1b: derived file regenerated to match canonical")

    -- restart equivalence
    Manager:dropSessionState(VIEW); IntentStore.load(true); NativeWriter._resetCaches()
    launch()
    note(Manager:getParentMenu(VIEW, "opds") == "tools",
        "N1c: stable across another reload")
    wipe_all()
end

-- N2: cloud-sync regression — an OLDER canonical intent file arrives after
-- the newer one. The plugin must not silently merge incompatible eras:
-- whatever is on disk at startup IS the state (last writer wins on whole
-- file granularity), but the derived cache must not claim freshness it
-- does not have.
do
    wipe_all(); launch()
    Manager:setItemHidden(VIEW, "screensaver", true, "screen")
    Manager:saveOrder(VIEW)
    local f_intent = io.open(sd .. "/reorderingmenus_intent.lua", "r")
    local old_intent = f_intent and f_intent:read("*a"); if f_intent then f_intent:close() end

    Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
    Manager:saveOrder(VIEW)
    local new_projection = Manager:getParentMenu(VIEW, "opds")

    -- cloud regression: old intent restored underneath the new sidecar/native
    local f = io.open(sd .. "/reorderingmenus_intent.lua", "w")
    f:write(old_intent); f:close()

    Manager:dropSessionState(VIEW); IntentStore.load(true); NativeWriter._resetCaches()
    launch()

    -- canonical (the restored older file) governs; the newer native file is
    -- stale-generation output of our own and gets regenerated or reimported
    -- deterministically - but never silently fused.
    local sec = IntentStore.view(VIEW)
    note(sec.parent_override.opds == nil,
        "N2: restored-older intent governs (no phantom move record)")
    local ok_save = Manager:saveOrder(VIEW)
    note(ok_save, "N2b: pipeline converges to a consistent state")
    wipe_all()
end

-- N3: every file from a DIFFERENT era -> deterministic single-owner recovery.
do
    wipe_all(); launch()
    -- era A: hide screensaver
    Manager:setItemHidden(VIEW, "screensaver", true, "screen")
    Manager:saveOrder(VIEW)
    local f_native = io.open(sd .. "/" .. VIEW .. "_menu_order.lua", "r")
    local native_a = f_native and f_native:read("*a"); if f_native then f_native:close() end
    local f_side = io.open(sd .. "/reorderingmenus_materialization.lua", "r")
    local side_a = f_side and f_side:read("*a"); if f_side then f_side:close() end

    -- era B: move opds
    Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
    Manager:saveOrder(VIEW)
    f_intent = nil
    local f_i2 = io.open(sd .. "/reorderingmenus_intent.lua", "r")
    local intent_b = f_i2 and f_i2:read("*a"); if f_i2 then f_i2:close() end

    -- era C: unrelated second change
    Manager:setItemHidden(VIEW, "calibre", true, "more_tools")
    Manager:saveOrder(VIEW)
    local f_i3 = io.open(sd .. "/reorderingmenus_intent.lua", "r")
    local intent_c = f_i3 and f_i3:read("*a"); if f_i3 then f_i3:close() end

    -- assemble the mess: intent B, native A, sidecar A... plus overwrite
    -- intent with C afterwards? Keep it truly mixed: intent C, native A,
    -- sidecar A.
    local f = io.open(sd .. "/reorderingmenus_intent.lua", "w")
    f:write(intent_b); f:close()
    f = io.open(sd .. "/" .. VIEW .. "_menu_order.lua", "w")
    f:write(native_a); f:close()
    f = io.open(sd .. "/reorderingmenus_materialization.lua", "w")
    f:write(side_a); f:close()

    Manager:dropSessionState(VIEW); IntentStore.load(true); NativeWriter._resetCaches()
    launch()

    -- deterministic: canonical intent (era B: opds moved) governs
    local parent = Manager:getParentMenu(VIEW, "opds")
    note(parent == "tools", "N3: canonical-era placement recovered (got "
        .. tostring(parent) .. ")")
    -- and a save produces parseable, consistent files
    note(Manager:saveOrder(VIEW), "N3b: save succeeds from mixed-era start")
    local order = dofile(sd .. "/" .. VIEW .. "_menu_order.lua")
    note(type(order) == "table", "N3c: derived file parses after recovery")
    wipe_all()
end

-- N4: lagging fingerprint-matching file must regenerate (not import).
do
    wipe_all(); launch()
    Manager:setItemHidden(VIEW, "screensaver", true, "screen")
    Manager:saveOrder(VIEW)
    local f_native = io.open(sd .. "/" .. VIEW .. "_menu_order.lua", "r")
    local old_native_bytes = f_native and f_native:read("*a"); if f_native then f_native:close() end
    local f_side = io.open(sd .. "/reorderingmenus_materialization.lua", "r")
    local old_sidecar = f_side and f_side:read("*a"); if f_side then f_side:close() end

    Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
    Manager:saveOrder(VIEW)

    -- put back the old bytes AND the old sidecar: fingerprint matches the
    -- sidecar, but intent_gen lags -> regenerate path.
    local f = io.open(sd .. "/" .. VIEW .. "_menu_order.lua", "w")
    f:write(old_native_bytes); f:close()
    f = io.open(sd .. "/reorderingmenus_materialization.lua", "w")
    f:write(old_sidecar); f:close()

    Manager:dropSessionState(VIEW); IntentStore.load(true); NativeWriter._resetCaches()
    launch()

    note(Manager:getParentMenu(VIEW, "opds") == "tools",
        "N4: lagging-but-fingerprint-matching file does not mask intent")
    wipe_all()
end

-- N5: every file restored independently from a DIFFERENT backup day
--     (intent Tuesday, Reader Monday, FM Friday, sidecar Wednesday).
--     Defined precedence, exercised end-to-end:
--       * canonical intent governs everything recognizably OURS (fingerprint
--         matched) even when the derived file is chronologically NEWER
--         (reader Monday vs intent Tuesday -> regenerated_lagging);
--       * foreign bytes relative to the sidecar (FM Friday vs the Wednesday
--         record) import as explicit user arrangement;
--       * nothing hybrid or duplicated may appear; second restart converges.
do
    wipe_all(); launch()
    local function launch_reader()
        local ui_r = { menu = { registered_widgets = {} } }
        UIScreens:reconcileRegisteredItems({ ui = ui_r }, OTHER, false)
    end

    -- Era MONDAY: reader hides one stock row (captured below).
    launch_reader()
    local reader_menu, reader_item
    do
        local d = Manager:getDefaultOrder(OTHER)
        for _, menu_id in ipairs({ "help", "main", "setting", "screen" }) do
            local list = d[menu_id]
            if type(list) == "table" and #list > 0 then
                reader_menu, reader_item = menu_id, list[1]
                break
            end
        end
        assert(reader_item, "N5 setup: no reader default row found")
    end
    Manager:setItemHidden(OTHER, reader_item, true, reader_menu)
    Manager:saveOrder(OTHER)
    local f = io.open(sd .. "/" .. OTHER .. "_menu_order.lua", "r")
    local reader_native_mon = f and f:read("*a"); if f then f:close() end

    -- Era TUESDAY: canonical intent gains an FM hide. Capture intent bytes.
    Manager:setItemHidden(VIEW, "screensaver", true, "screen")
    Manager:saveOrder(VIEW)
    f = io.open(sd .. "/reorderingmenus_intent.lua", "r")
    local intent_tue = f and f:read("*a"); if f then f:close() end

    -- Era WEDNESDAY: one more committed FM change -> capture the sidecar.
    Manager:setItemHidden(VIEW, "calibre", true, "more_tools")
    Manager:saveOrder(VIEW)
    f = io.open(sd .. "/reorderingmenus_materialization.lua", "r")
    local sidecar_wed = f and f:read("*a"); if f then f:close() end

    -- Era FRIDAY: external-shaped FM rearrangement -> capture FM native.
    -- (Produced through the pipeline so it is byte-real, then captured.)
    Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
    Manager:saveOrder(VIEW)
    f = io.open(sd .. "/" .. VIEW .. "_menu_order.lua", "r")
    local fm_native_fri = f and f:read("*a"); if f then f:close() end

    -- Assemble the four-era mess.
    local function write_bytes(path, body)
        local h = io.open(path, "w") h:write(body) h:close()
    end
    write_bytes(sd .. "/reorderingmenus_intent.lua", intent_tue)
    write_bytes(sd .. "/reorderingmenus_materialization.lua", sidecar_wed)
    write_bytes(sd .. "/" .. VIEW .. "_menu_order.lua", fm_native_fri)
    write_bytes(sd .. "/" .. OTHER .. "_menu_order.lua", reader_native_mon)
    dbg_state("restored four eras")

    Manager:dropSessionState(VIEW); Manager:dropSessionState(OTHER)
    IntentStore.load(true); NativeWriter._resetCaches()
    launch(); launch_reader()
    dbg_state("after sync")

    note(Manager:getParentMenu(VIEW, "opds") == "tools",
        "N5: FM Friday bytes import as the observed arrangement (got "
        .. tostring(Manager:getParentMenu(VIEW, "opds")) .. ")")
    note(Manager:isItemHidden(VIEW, "screensaver"),
        "N5b: canonical Tuesday intent keeps screensaver hidden")
    note(not Manager:isItemHidden(VIEW, "calibre"),
        "N5c: Wednesday-only intent state did NOT resurrect (no hybrid)")
    -- The restored canonical intent itself CONTAINS the Monday reader hide,
    -- and reader's derived file + sidecar record are mutually consistent:
    -- keeping it is per-view correctness, not a cross-era merge. FM chaos
    -- must not leak into reader's consistent state either way.
    note(Manager:isItemHidden(OTHER, reader_item),
        "N5d: reader stays internally consistent (hide held by restored "
        .. "canonical intent; FM-era mixing does not leak across views)")

    -- Fifth independent restore: the reader DERIVED file alone is missing
    -- (sync client dropped it). Sidecar still claims content with a
    -- generation-consistent binding -> defined outcome: reader fully
    -- reverts (its derived layout is lost), FM stays exactly as imported.
    os.remove(sd .. "/" .. OTHER .. "_menu_order.lua")
    Manager:dropSessionState(VIEW); Manager:dropSessionState(OTHER)
    IntentStore.load(true); NativeWriter._resetCaches()
    launch(); launch_reader()
    note(not Manager:isItemHidden(OTHER, reader_item),
        "N5e: losing reader's derived file alone reverts ONLY reader")
    note(Manager:getParentMenu(VIEW, "opds") == "tools"
        and Manager:isItemHidden(VIEW, "screensaver"),
        "N5e2: FM state untouched by reader's revert")

    -- convergence: an identical second restart changes nothing
    Manager:dropSessionState(VIEW); Manager:dropSessionState(OTHER)
    IntentStore.load(true); NativeWriter._resetCaches()
    launch(); launch_reader()
    note(Manager:getParentMenu(VIEW, "opds") == "tools"
        and Manager:isItemHidden(VIEW, "screensaver")
        and not Manager:isItemHidden(OTHER, reader_item),
        "N5f: four-era recovery converges stably across a second restart")

    -- a save produces parseable, consistent files
    note(Manager:saveOrder(VIEW) and Manager:saveOrder(OTHER),
        "N5g: saves succeed for both views from the four-era start")
    local order = dofile(sd .. "/" .. VIEW .. "_menu_order.lua")
    note(type(order) == "table", "N5h: derived FM file parses after recovery")
    wipe_all()
end

-- N6: cloud-sync-like CONSISTENT rollback — all four files restored together
-- from an earlier snapshot. Result must be exactly the snapshot state (never
-- a fusion with later work), fully converged afterwards.
do
    wipe_all(); launch()
    -- era 1: the future snapshot
    Manager:setItemHidden(VIEW, "screensaver", true, "screen")
    Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
    Manager:saveOrder(VIEW)
    local snap = {}
    for _, name in ipairs({ VIEW .. "_menu_order.lua", OTHER .. "_menu_order.lua",
            "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        local f = io.open(sd .. "/" .. name, "r")
        snap[name] = f and f:read("*a"); if f then f:close() end
    end

    -- era 2: life goes on (different shape). Re-launch first: after the
    -- snapshot save the session is synced, so a move would silently no-op.
    launch()
    Manager:setItemHidden(VIEW, "calibre", true, "more_tools")
    Manager:moveItemToMenu(VIEW, "opds", "tools", "search")
    Manager:saveOrder(VIEW)
    assert(Manager:getParentMenu(VIEW, "opds") == "search",
        "N6 setup: era-2 state reached")
    assert(Manager:isItemHidden(VIEW, "calibre"),
        "N6 setup: era-2 hide reached")

    -- cloud client reinstalls the WHOLE snapshot directory
    for name, body in pairs(snap) do
        local h = io.open(sd .. "/" .. name, "w") h:write(body) h:close()
    end
    dbg_state("N6 restored snapshot")
    Manager:dropSessionState(VIEW); Manager:dropSessionState(OTHER)
    IntentStore.load(true); NativeWriter._resetCaches()
    launch()
    do
        local sec_d = IntentStore.view(VIEW)
        local hs_d = {}
        for k in pairs(sec_d.hidden) do hs_d[#hs_d+1] = k end
        print("[DBG N6] hidden={" .. table.concat(hs_d, ",") .. "} po.opds=" ..
            tostring(sec_d.parent_override.opds and sec_d.parent_override.opds.parent))
        print("[DBG N6 legs] parent(opds)=" .. tostring(Manager:getParentMenu(VIEW, "opds"))
            .. " hidden(screensaver)=" .. tostring(Manager:isItemHidden(VIEW, "screensaver"))
            .. " hidden(calibre)=" .. tostring(Manager:isItemHidden(VIEW, "calibre")))
    end

    note(Manager:getParentMenu(VIEW, "opds") == "tools"
        and Manager:isItemHidden(VIEW, "screensaver")
        and not Manager:isItemHidden(VIEW, "calibre"),
        "N6: consistent rollback restores exactly the snapshot state")
    local sec = IntentStore.view(VIEW)
    note(sec.hidden.calibre == nil,
        "N6b: no phantom record survives the rollback")

    Manager:dropSessionState(VIEW); IntentStore.load(true); NativeWriter._resetCaches()
    launch()
    note(Manager:getParentMenu(VIEW, "opds") == "tools"
        and not Manager:isItemHidden(VIEW, "calibre"),
        "N6c: rolled-back state stable across reload")
    wipe_all()
end

-- N7: REGRESSION (first-restart rollback absorption). A consistent whole-
-- directory rollback must be absorbed ON THE FIRST restart — the projection
-- served by that same session must already be the restored snapshot, not a
-- fusion of pre-rollback staging with restored canonical intent. The stale
-- long-lived staging transaction must be discarded when canonical state is
-- wholesale reloaded underneath it.
do
    wipe_all(); launch()
    -- era 1: the future snapshot
    Manager:setItemHidden(VIEW, "screensaver", true, "screen")
    Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
    Manager:saveOrder(VIEW)
    local snap = {}
    for _, name in ipairs({ VIEW .. "_menu_order.lua",
            OTHER .. "_menu_order.lua", "reorderingmenus_intent.lua",
            "reorderingmenus_materialization.lua" }) do
        local f = io.open(sd .. "/" .. name, "r")
        snap[name] = f and f:read("*a"); if f then f:close() end
    end

    -- era 2: life goes on
    launch()
    Manager:setItemHidden(VIEW, "calibre", true, "more_tools")
    Manager:moveItemToMenu(VIEW, "opds", "tools", "search")
    Manager:saveOrder(VIEW)

    -- cloud client reinstalls the WHOLE snapshot directory
    for name, body in pairs(snap) do
        local h = io.open(sd .. "/" .. name, "w") h:write(body) h:close()
    end
    Manager:dropSessionState(VIEW); Manager:dropSessionState(OTHER)
    IntentStore.load(true); NativeWriter._resetCaches()
    launch()

    -- FIRST session after the restore must serve exactly the snapshot.
    note(Manager:getParentMenu(VIEW, "opds") == "tools"
        and Manager:isItemHidden(VIEW, "screensaver")
        and not Manager:isItemHidden(VIEW, "calibre"),
        "N7: first post-rollback session serves exactly the snapshot")
    local sec = IntentStore.view(VIEW)
    note(sec.hidden.calibre == nil and sec.parent_override.opds ~= nil,
        "N7b: no pre-rollback record fused into restored intent")

    -- ...and a save right in that first session converges (no stale-
    -- transaction refusal loop from superseded staging).
    note(Manager:saveOrder(VIEW),
        "N7c: saving in the first post-rollback session succeeds")
    wipe_all()
end

-- N8: mixed-era recovery is PROCESS-DETERMINISTIC: the same on-disk state
-- must classify identically on every fresh startup. Replays the N3 mess
-- five times in fresh sessions and requires identical outcomes each time.
do
    wipe_all(); launch()
    Manager:setItemHidden(VIEW, "screensaver", true, "screen")
    Manager:saveOrder(VIEW)
    local f = io.open(sd .. "/" .. VIEW .. "_menu_order.lua", "r")
    local native_a = f and f:read("*a"); if f then f:close() end
    f = io.open(sd .. "/reorderingmenus_materialization.lua", "r")
    local side_a = f and f:read("*a"); if f then f:close() end
    Manager:setItemHidden(VIEW, "calibre", true, "more_tools")
    Manager:saveOrder(VIEW)
    f = io.open(sd .. "/reorderingmenus_intent.lua", "r")
    local intent_c = f and f:read("*a"); if f then f:close() end

    local function plant_mixed_era()
        local g = io.open(sd .. "/reorderingmenus_intent.lua", "w")
        g:write(intent_c) g:close()
        g = io.open(sd .. "/" .. VIEW .. "_menu_order.lua", "w")
        g:write(native_a) g:close()
        g = io.open(sd .. "/reorderingmenus_materialization.lua", "w")
        g:write(side_a) g:close()
    end

    -- Deterministic recovery over repeated fresh startups.
    for i = 1, 5 do
        plant_mixed_era()
        Manager:dropSessionState(VIEW); IntentStore.load(true)
        NativeWriter._resetCaches()
        launch()
        local parent = Manager:getParentMenu(VIEW, "opds")
        local screensaver_hidden = Manager:isItemHidden(VIEW, "screensaver")
        local calibre_hidden = Manager:isItemHidden(VIEW, "calibre")
        -- Canonical era-C intent governs: opds back at stock (no move
        -- record), both hides present. The era-A native file is our own
        -- stale output relative to that intent and is regenerated/imported
        -- identically every time - never fused differently per run.
        note(parent == "search" and screensaver_hidden and calibre_hidden,
            string.format("N8[%d]: mixed-era recovery outcome stable (%s)",
                i, tostring(parent)))
    end
    wipe_all()
end

wipe_all()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)

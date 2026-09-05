--[[--
test_mirror_failure_matrix_gaps.lua — H/I/J residual gaps.

Complements test_mirror_partial_failure_contracts.lua (H1-H7, I1-I5, J1-J5)
and test_cross_view_partial_failure.lua (H1, I1-I6, J1-J2). Covers the rows
the spec demands that neither suite locks down yet:

H. Failure-injected matrix rows still missing:
   - H8 unhide whose durable persist fails;
   - H9 restore-default whose durable persist fails (local-only semantics);
   - H10 reset whose durable commit fails (other view must survive the
     failure window untouched, retry finishes the job).

I. Non-mirrored operations beyond separators/presets/tab-order:
   - N6 intra-menu reorder (moveItem) never mirrors;
   - N7 custom-submenu create/delete never mirror;
   - N8 off -> source-only edits -> ON -> ONE unrelated edit crosses exactly
     itself (per-item retroactive-replay precision).

J. Temporary-absence HIDES (J1 covered moves):
   - J6 hide while the other view lacks the id is skipped, never applied
     retroactively on arrival, and future hides mirror again.

Policy under test (source-commits-mirror-pending, decision #2): a failed
durable write rolls canonical back to last-good on BOTH views atomically,
keeps the work staged/pending/retriable, serves the projection from staged,
and reports failure to the caller - never silent split-brain with success.

Run: cd /Applications/KOReader.app/Contents/koreader &&
     ./luajit <project>/tests/test_mirror_failure_matrix_gaps.lua
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
local KoreaderAdapter = require("lib.koreader_adapter")
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

local sd = DataStorage:getSettingsDir()
local INTENT_FILE = sd .. "/reorderingmenus_intent.lua"
local NATIVE = {
    filemanager = sd .. "/filemanager_menu_order.lua",
    reader = sd .. "/reader_menu_order.lua",
}
local SIDECAR_FILE = sd .. "/reorderingmenus_materialization.lua"

local live_stubs = { reader = {}, filemanager = {} }
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
    live_stubs = { reader = {}, filemanager = {} }
end

-- Stub registration through the real reconcile/pin path.
local function anchor(view, id, hint)
    live_stubs[view][id] = { sorting_hint = hint }
    local w = {}
    for k in pairs(live_stubs[view]) do w[k] = k .. "_w" end
    Manager:setLiveRegistrations(view, live_stubs[view], w)
    Manager:reconcileRegisteredItems(view, live_stubs[view], w)
end

local function anchor_both(id, hint)
    anchor("reader", id, hint)
    anchor("filemanager", id, hint)
end

local function parent_in(view, id)
    return Manager:getParentMenu(view, id)
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

print("==================================================================")
print("=== H/I/J residual gaps: failure matrix + non-mirrored ops     ===")
print("==================================================================")

-- =====================================================================
-- H8. Mirrored UNHIDE under failing persist: canonical stays hidden in
--     BOTH views (atomic rollback), the unhide stays staged/retriable in
--     both, the projection serves the staged visibility, retry converges.
-- =====================================================================
print("\n--- H8: mirrored unhide under failing persist ---")
do
    wipe_all()
    anchor_both("mir_h8", "more_tools")
    Manager:setMirroringEnabled(true)
    -- Establish a COMMITTED hidden baseline on both sides.
    Manager:setItemHidden("filemanager", "mir_h8", true, "more_tools")
    note(Manager:saveOrder("filemanager") and Manager:saveOrder("reader"),
        "H8-pre: committed hidden baseline on both views")

    local real_writeToFile = util.writeToFile
    util.writeToFile = function() return nil, "injected" end
    Manager:setItemHidden("filemanager", "mir_h8", false, nil)
    local save_ok = Manager:saveOrder("filemanager")
    util.writeToFile = real_writeToFile

    note(save_ok == false, "H8a: unhide save reports failure (no silent success)")
    note(IntentStore.view("filemanager").hidden.mir_h8 ~= nil
        and IntentStore.view("reader").hidden.mir_h8 ~= nil,
        "H8b: canonical stays HIDDEN in both views after rollback (atomic)")
    note(Manager:stagedView("filemanager").hidden.mir_h8 == nil
        and Manager:stagedView("reader").hidden.mir_h8 == nil,
        "H8c: unhide stays STAGED pending retry in BOTH views")
    note(not Manager:isItemHidden("filemanager", "mir_h8"),
        "H8d: projection serves the staged (unsaved) unhide")

    note(Manager:saveOrder("filemanager") and Manager:saveOrder("reader"),
        "H8e: healthy retry succeeds")
    note(IntentStore.view("filemanager").hidden.mir_h8 == nil
        and IntentStore.view("reader").hidden.mir_h8 == nil,
        "H8f: retried unhide clears hidden records symmetrically")
    note(not Manager:isItemHidden("filemanager", "mir_h8")
        and not Manager:isItemHidden("reader", "mir_h8"),
        "H8g: both views serve the restored row after retry")
    wipe_all()
end

-- =====================================================================
-- H9. RESTORE-DEFAULT under failing persist. Restore-default is a LOCAL
--     operation (does not mirror, I1): on failure the acting view rolls
--     back to its explicit override, the OTHER view's mirrored placement
--     is untouched in canonical AND staged, and a retried restore lands
--     locally only - the other view keeps its customized home.
-- =====================================================================
print("\n--- H9: restore-default under failing persist ---")
do
    wipe_all()
    anchor_both("mir_h9", "more_tools")
    Manager:setMirroringEnabled(true)
    Manager:moveItemToMenu("filemanager", "mir_h9", "more_tools", "setting")
    note(Manager:saveOrder("filemanager") and Manager:saveOrder("reader"),
        "H9-pre: mirrored move committed on both views")

    local real_writeToFile = util.writeToFile
    util.writeToFile = function() return nil, "injected" end
    local r_ok = Manager:restoreItemDefault("filemanager", "mir_h9")
    local save_ok = Manager:saveOrder("filemanager")
    util.writeToFile = real_writeToFile

    note(r_ok == true, "H9a: restore staging accepted while writes fail")
    note(save_ok == false, "H9b: save reports failure")
    local fm_canon = IntentStore.view("filemanager").parent_override.mir_h9
    note(fm_canon ~= nil and fm_canon.parent == "setting",
        "H9c: FM canonical rolled back to the explicit override (last good)")
    local rd_canon = IntentStore.view("reader").parent_override.mir_h9
    note(rd_canon ~= nil and rd_canon.parent == "setting",
        "H9d: reader canonical untouched through FM's failed restore")
    note(Manager:stagedView("filemanager").parent_override.mir_h9 == nil,
        "H9e: restore stays STAGED (override cleared) pending retry in FM")
    note(Manager:stagedView("reader").parent_override.mir_h9 ~= nil
        and Manager:stagedView("reader").parent_override.mir_h9.parent == "setting",
        "H9f: reader staged equally untouched (local-only op)")

    note(Manager:saveOrder("filemanager"), "H9g: retried FM save succeeds")
    local fm_after = IntentStore.view("filemanager").parent_override.mir_h9
    note(fm_after == nil or fm_after.anchor == true or fm_after.parent ~= "setting",
        "H9h: FM no longer holds the explicit 'setting' override after retry")
    note(parent_in("filemanager", "mir_h9") ~= "setting",
        "H9i: FM serves the default home again")
    note(parent_in("reader", "mir_h9") == "setting",
        "H9j: reader KEEPS its mirrored customized home (no cross-view revert)")
    wipe_all()
end

-- =====================================================================
-- H10. RESET under failing persist: the commit fails BEFORE the derived
--      files are removed, so disk state stays coherent; the OTHER view's
--      customization survives the failure window in canonical, staged,
--      AND projection; retry completes the acting view's reset only.
-- =====================================================================
print("\n--- H10: reset under failing persist ---")
do
    wipe_all()
    anchor_both("mir_h10", "more_tools")
    Manager:setMirroringEnabled(true)
    Manager:setItemHidden("filemanager", "mir_h10", true, "more_tools")
    Manager:setItemHidden("reader", "mir_h10", true, "more_tools")
    note(Manager:saveOrder("filemanager") and Manager:saveOrder("reader"),
        "H10-pre: independent hides committed per view")

    local real_writeToFile = util.writeToFile
    util.writeToFile = function() return nil, "injected" end
    local reset_ok = Manager:resetOrder("filemanager")
    util.writeToFile = real_writeToFile

    note(reset_ok == false, "H10a: reset reports failure (no silent success)")
    note(file_exists(NATIVE.filemanager),
        "H10b: derived FM native file NOT removed when commit failed first")
    note(IntentStore.view("filemanager").hidden.mir_h10 ~= nil,
        "H10c: FM canonical rolled back (customization intact)")
    note(IntentStore.view("reader").hidden.mir_h10 ~= nil,
        "H10d: reader canonical untouched by FM's failed reset")
    note(Manager:isItemHidden("reader", "mir_h10"),
        "H10e: reader projection unaffected during the failure window")

    note(Manager:resetOrder("filemanager"), "H10f: retried reset succeeds")
    note(IntentStore.view("filemanager").hidden.mir_h10 == nil,
        "H10g: FM canonical emptied after retry")
    note(IntentStore.view("reader").hidden.mir_h10 ~= nil
        and Manager:isItemHidden("reader", "mir_h10"),
        "H10h: reader customization SURVIVES the completed reset")
    wipe_all()
end

-- =====================================================================
-- N6. Intra-menu reorder (moveItem) is NOT a mirrored operation: only
--     cross-parent moves carry mirror semantics. The other view's order
--     records and projection stay byte-identical.
-- =====================================================================
print("\n--- N6: intra-menu reorder never mirrors ---")
do
    wipe_all()
    anchor_both("mir_n6", "more_tools")
    Manager:setMirroringEnabled(true)
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")

    local reader_before = util.tableDeepCopy(Manager:getMenuItems("reader", "more_tools"))

    local items = Manager:getMenuItems("filemanager", "more_tools")
    local idx = nil
    for i, id in ipairs(items) do
        if id == "mir_n6" then idx = i break end
    end
    note(idx ~= nil and idx > 1, "N6-pre: stub located inside FM more_tools")
    note(Manager:moveItem("filemanager", "more_tools", idx, 1),
        "N6-pre2: intra-menu reorder accepted")

    note(Manager:saveOrder("filemanager") and Manager:saveOrder("reader"),
        "N6-pre3: both saves succeed")

    local r_sec = IntentStore.view("reader")
    note(r_sec.order_override == nil or r_sec.order_override.more_tools == nil,
        "N6a: reader canonical gained NO order_override from FM's reorder")
    note(util.tableEquals(reader_before, Manager:getMenuItems("reader", "more_tools")),
        "N6b: reader projection arrangement unchanged")
    -- The minimizer may encode the head-move as a single position_override
    -- rather than a whole-list order_override; both are legitimate local
    -- encodings of the same user intent.
    local f_sec = IntentStore.view("filemanager")
    note((f_sec.position_override ~= nil and f_sec.position_override.mir_n6 ~= nil)
        or (f_sec.order_override ~= nil and f_sec.order_override.more_tools ~= nil),
        "N6c: FM retains its reorder durably (position or order record)")
    note(Manager:getMenuItems("filemanager", "more_tools")[1] == "mir_n6",
        "N6d: FM projection still serves the reordered arrangement post-save")
    wipe_all()
end

-- =====================================================================
-- N7. Custom submenu create/delete never mirror: the submenu record and
--     its entry in the parent list exist ONLY in the acting view.
-- =====================================================================
print("\n--- N7: custom submenu create/delete never mirror ---")
do
    wipe_all()
    anchor_both("mir_n7", "tools")
    Manager:setMirroringEnabled(true)
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")

    local ok, sub_id = Manager:createSubmenu("filemanager", "tools", "Mirror Probe", 1)
    note(ok and sub_id ~= nil, "N7-pre: submenu created in FM")
    note(Manager:saveOrder("filemanager"), "N7-pre2: FM save succeeds")

    local r_sec = IntentStore.view("reader")
    note(r_sec.custom_menus == nil or next(r_sec.custom_menus) == nil,
        "N7a: reader canonical holds NO custom_menus record")
    local reader_tools = Manager:getMenuItems("reader", "tools")
    local leaked = false
    for _, id in ipairs(reader_tools) do
        if id == sub_id then leaked = true break end
    end
    note(not leaked, "N7b: reader parent list carries no submenu entry")

    note(Manager:deleteCustomSubmenu("filemanager", sub_id),
        "N7-pre3: empty submenu deleted in FM")
    note(Manager:saveOrder("filemanager") and Manager:saveOrder("reader"),
        "N7-pre4: saves succeed")

    local r_after = IntentStore.view("reader")
    note(r_after.custom_menus == nil or next(r_after.custom_menus) == nil,
        "N7c: deletion likewise crossed nothing to reader")
    wipe_all()
end

-- =====================================================================
-- N8. Retroactive-replay precision: mirror OFF, TWO source-only edits
--     (cross-parent move of an FM-only id + a stock hide), saves; then
--     mirror ON and exactly ONE unrelated reader-initiated edit. Only
--     that single edit crosses; neither historical edit appears on the
--     other side.
-- =====================================================================
print("\n--- N8: off -> edits -> on -> one edit crosses exactly itself ---")
do
    wipe_all()
    anchor("filemanager", "mir_n8_solo", "more_tools")   -- FM-only id
    anchor_both("mir_n8_pair", "more_tools")             -- dual id
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")

    Manager:moveItemToMenu("filemanager", "mir_n8_solo", "more_tools", "setting")
    Manager:setItemHidden("filemanager", "history", true, "main")
    note(Manager:saveOrder("filemanager"), "N8-pre: source-only edits saved (mirror OFF)")

    Manager:setMirroringEnabled(true)
    -- Single legitimate mirrored edit, initiated from READER.
    Manager:setItemHidden("reader", "mir_n8_pair", true, "more_tools")
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")

    local r_sec = IntentStore.view("reader")
    note(r_sec.parent_override.mir_n8_solo == nil,
        "N8a: FM-only historical move never replayed into reader")
    note(r_sec.hidden.history == nil,
        "N8b: historical stock hide never replayed into reader")
    note(r_sec.hidden.mir_n8_pair ~= nil,
        "N8c: THE post-enable edit IS present in reader canonical")
    note(IntentStore.view("filemanager").hidden.mir_n8_pair ~= nil,
        "N8d: ...and it mirrored back into FM exactly once (symmetric)")
    wipe_all()
end

-- =====================================================================
-- J6. Temporary-absence HIDES: reader hides an id FM does not register
--     yet - skipped silently; when FM later gains the id (upgrade), the
--     missed hide is NOT retro-applied (arrival follows FM's OWN
--     defaults); a FUTURE hide mirrors normally again.
-- =====================================================================
print("\n--- J6: hide during temporary absence is future-only ---")
do
    wipe_all()
    anchor("reader", "mir_j6", "more_tools")
    Manager:setMirroringEnabled(true)
    Manager:saveOrder("reader")

    Manager:setItemHidden("reader", "mir_j6", true, "more_tools")
    note(Manager:saveOrder("reader"), "J6-pre: reader hide saved while FM lacks the id")
    note(IntentStore.view("filemanager").hidden.mir_j6 == nil,
        "J6a: hide skipped, FM canonical unpolluted")

    -- Upgrade: FM gains the id afterwards.
    anchor("filemanager", "mir_j6", "more_tools")
    note(parent_in("filemanager", "mir_j6") == "more_tools",
        "J6b: arrival honors FM's own default home")
    note(not Manager:isItemHidden("filemanager", "mir_j6"),
        "J6c: missed hide NOT retroactively applied on arrival")

    -- An unrelated mirrored edit must not drag the old hide along either.
    anchor_both("mir_j6b", "tools")
    Manager:setItemHidden("reader", "mir_j6b", true, "tools")
    Manager:saveOrder("reader"); Manager:saveOrder("filemanager")
    note(IntentStore.view("filemanager").hidden.mir_j6 == nil,
        "J6d: unrelated later edit does not resurrect the missed hide")

    -- FUTURE hide of the arrived id mirrors normally.
    Manager:setItemHidden("reader", "mir_j6", false, nil)
    Manager:saveOrder("reader")
    Manager:setItemHidden("reader", "mir_j6", true, "more_tools")
    Manager:saveOrder("reader"); Manager:saveOrder("filemanager")
    note(IntentStore.view("filemanager").hidden.mir_j6 ~= nil,
        "J6e: post-arrival hide mirrors (future-only boundary)")
    wipe_all()
end

wipe_all()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)

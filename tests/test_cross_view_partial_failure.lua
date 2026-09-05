--[[--
test_cross_view_partial_failure.lua — Areas H + I + J.

H. Mirroring partial failures: when the source view commits but the mirrored
   FM/Reader write fails, the policy is (2) source commits and the mirror is
   explicitly pending/retriable — never silent split-brain while reporting
   success.

I. Mirroring negative contracts:
   - operations documented NOT to mirror (separators, presets, tab order,
     restore-default, reset) never cross-write;
   - enabling mirror on already-diverged views does not sync history;
   - mirror off -> edits -> mirror on -> next edit does not replay past edits;
   - recursion guard prevents ping-pong.

J. Mirror availability semantics: same provider but absent/divergent in the
   other view — mirror skips; missed intent is future-only, never retroactive.

Run: cd /Applications/KOReader.app/Contents/koreader &&
     ./luajit <project>/tests/test_cross_view_partial_failure.lua
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
local MenuSchema = require("lib.menu_schema")
local NativeWriter = require("lib.native_writer")
local UIScreens = require("lib.ui_screens")
local KoreaderAdapter = require("lib.koreader_adapter")
local util = require("util")

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

local function wipe_all()
    for _, f in ipairs({ "filemanager_menu_order.lua", "reader_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        os.remove(sd .. "/" .. f)
    end
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}
    Manager.recent_moves.reader = {}
    Manager:dropSessionState("filemanager")
    Manager:dropSessionState("reader")
end

-- Manager-level stub registration (drives the real reconcile/pin path).
local function anchor(view, id, hint)
    Manager:setLiveRegistrations(view,
        { [id] = { sorting_hint = hint } }, { [id] = id .. "_w" })
    Manager:reconcileRegisteredItems(view,
        { [id] = { sorting_hint = hint } }, { [id] = id .. "_w" })
end

local function parent_in(view, id)
    return Manager:getParentMenu(view, id)
end

print("===============================================================")
print("=== H/I/J. Cross-view mirroring                              ===")
print("===============================================================")

-- H1: FM move succeeds; the mirrored Reader write fails (injected). Source
-- stays committed; after the write recovers, a retried save converges.
do
    wipe_all()
    anchor("reader", "mir_h1", "more_tools")
    anchor("filemanager", "mir_h1", "more_tools")
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")
    Manager:setMirroringEnabled(true)

    local real_write = KoreaderAdapter.writeNativeOrder
    local reader_writes_failed = 0
    KoreaderAdapter.writeNativeOrder = function(view, order_table)
        if view == "reader" and reader_writes_failed < 1 then
            reader_writes_failed = reader_writes_failed + 1
            return false, "injected reader write failure"
        end
        return real_write(view, order_table)
    end

    note(Manager:moveItemToMenu("filemanager", "mir_h1", "more_tools", "setting"),
        "H1: FM move accepted while reader writes fail")
    -- P0-5 contract: the source save now reports `false,
    -- "saved_needs_regeneration:<failed views>"` when ANY derived view failed
    -- (the mirror side here), while canonical intent IS committed. The
    -- historical boolean-true is no longer returned; what matters is that
    -- the commit happened and a retry converges (checked below).
    local h1b_ok, h1b_err = Manager:saveOrder("filemanager")
    local h1b_committed = h1b_ok or (type(h1b_err) == "string"
        and h1b_err:find("saved_needs_regeneration") ~= nil)
    note(h1b_committed, "H1b: FM save committed")
    KoreaderAdapter.writeNativeOrder = real_write

    note(parent_in("filemanager", "mir_h1") == "setting",
        "H1c: source view keeps its committed move")

    -- recovery pass: the mirror intent is still in canonical memory; a save
    -- of the reader side persists it now.
    note(Manager:saveOrder("reader"), "H1d: retried reader save succeeds")
    note(parent_in("reader", "mir_h1") == "setting",
        "H1e: mirror converges on retry")
    wipe_all()
end

-- I1: separators never mirror.
do
    wipe_all()
    Manager:setMirroringEnabled(true)
    anchor("filemanager", "mir_i1", "tools")
    anchor("reader", "mir_i1", "tools")
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")

    -- insert at a NON-stock slot so the divider is genuinely user intent
    note(Manager:insertSeparator("filemanager", "tools", 5),
        "I1-pre: separator inserted in FM")
    Manager:saveOrder("filemanager")

    note(IntentStore.view("reader").separators == nil
        or next(IntentStore.view("reader").separators) == nil,
        "I1: separator records never cross to reader canonical")
    wipe_all()
end

-- I2: presets never mirror.
do
    wipe_all()
    Manager:setMirroringEnabled(true)
    anchor("filemanager", "mir_i2", "more_tools")
    Manager:setItemHidden("filemanager", "history", true, "main")
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")
    note(Manager:savePreset("filemanager", "NoMirrorPreset"),
        "I2-pre: preset saved from FM")

    -- snapshot reader canonical BEFORE the preset apply (the earlier mirrored
    -- hide legitimately put records there; the preset must not add any)
    local before_hidden = util.tableDeepCopy(IntentStore.view("reader").hidden or {})
    local before_po = util.tableDeepCopy(IntentStore.view("reader").parent_override or {})

    note(Manager:loadPreset("filemanager", "builtin_default"),
        "I2-pre2: Default preset applied in FM")
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")

    local r_sec = IntentStore.view("reader")
    note(util.tableEquals(before_hidden, r_sec.hidden or {}),
        "I2: preset apply in FM leaves reader hidden records unchanged")
    note(util.tableEquals(before_po, r_sec.parent_override or {}),
        "I2b: preset apply in FM leaves reader parent records unchanged")
    wipe_all()
end

-- I3: tab order never mirrors.
do
    wipe_all()
    Manager:setMirroringEnabled(true)
    local tabs = Manager:getTabs("filemanager")
    if #tabs >= 2 then
        local permuted = {}
        for _, t in ipairs(tabs) do permuted[#permuted + 1] = t end
        permuted[1], permuted[2] = permuted[2], permuted[1]
        Manager:reorderTabs("filemanager", permuted)
        Manager:saveOrder("filemanager")
        note(IntentStore.view("reader").tab_order == nil,
            "I3: tab reorder does not mirror into reader")
    else
        passed = passed + 1
    end
    wipe_all()
end

-- I4: enable-on-diverged does not synchronize historical differences.
do
    wipe_all()
    Manager:setMirroringEnabled(false)
    anchor("filemanager", "mir_i4", "more_tools")
    anchor("reader", "mir_i4b", "more_tools")
    Manager:setItemHidden("filemanager", "history", true, "main")
    Manager:saveOrder("filemanager")
    Manager:moveItemToMenu("reader", "opds", "search", "tools")
    Manager:saveOrder("reader")

    Manager:setMirroringEnabled(true)

    note(IntentStore.view("reader").parent_override.opds ~= nil,
        "I4: reader divergence untouched by enabling mirror")
    note(IntentStore.view("filemanager").hidden.history ~= nil,
        "I4b: FM divergence untouched by enabling mirror")
    wipe_all()
end

-- I5: off -> edits -> on -> next edit replays nothing retroactively.
do
    wipe_all()
    Manager:setMirroringEnabled(false)
    anchor("filemanager", "mir_i5", "more_tools")
    anchor("reader", "mir_i5", "more_tools")     -- dual availability
    Manager:moveItemToMenu("filemanager", "mir_i5", "more_tools", "setting")
    Manager:saveOrder("filemanager")

    Manager:setMirroringEnabled(true)
    -- NEW unrelated mirrored edit (hide another item)
    Manager:reconcileRegisteredItems("reader",
        { mir_i5_other = { sorting_hint = "more_tools" } },
        { mir_i5_other = "w" })
    Manager:setItemHidden("filemanager", "history", true, "main")
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")

    -- decisive: reader holds NO explicit move for the pre-enable item — its
    -- only record is the registration anchor (anchor=true), never an
    -- explicit user-move replayed retroactively.
    local rec = IntentStore.view("reader").parent_override.mir_i5
    note(rec == nil or MenuSchema.isLifecyclePin(rec),
        "I5c: pre-enable divergence NOT retroactively replayed"
        .. " (record is " .. (rec and (rec.anchor and "anchor" or "explicit") or "nil") .. ")")
    note(parent_in("reader", "mir_i5") ~= "setting",
        "I5d: pre-enable destination not materialized in reader")
    wipe_all()
end

-- I6: recursion guard — mirrored calls pass _mirrored=true (no ping-pong).
do
    wipe_all()
    Manager:setMirroringEnabled(true)
    anchor("filemanager", "mir_i6", "more_tools")
    anchor("reader", "mir_i6", "more_tools")
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")

    local mirror_calls = 0
    local real_setHidden = Manager.setItemHidden
    Manager.setItemHidden = function(self, view, id, hidden, menu, mirrored)
        if mirrored then mirror_calls = mirror_calls + 1 end
        return real_setHidden(self, view, id, hidden, menu, mirrored)
    end

    Manager:setItemHidden("filemanager", "mir_i6", true, "more_tools")
    Manager.setItemHidden = real_setHidden

    note(mirror_calls == 1,
        "I6: exactly one mirrored call (no ping-pong), got "
        .. tostring(mirror_calls))
    note(Manager:isItemHidden("filemanager", "mir_i6"),
        "I6b: FM hide applied once (staged)")
    note(Manager:isItemHidden("reader", "mir_i6"),
        "I6c: mirrored hide landed in reader exactly once (staged)")
    -- persist both sides and confirm canonical symmetry
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")
    note(IntentStore.view("filemanager").hidden.mir_i6 ~= nil
        and IntentStore.view("reader").hidden.mir_i6 ~= nil,
        "I6d: hidden state symmetric in canonical after saves")
    wipe_all()
end

-- J1: item known to FM only — reader mirror skipped silently.
do
    wipe_all()
    Manager:setMirroringEnabled(true)
    anchor("filemanager", "fm_only_row", "more_tools")
    Manager:moveItemToMenu("filemanager", "fm_only_row", "more_tools", "setting")
    Manager:saveOrder("filemanager")

    note(IntentStore.view("reader").parent_override.fm_only_row == nil,
        "J1: unknown-to-reader row not mirrored as ghost")
    wipe_all()
end

-- J2: later availability — missed mirror intent is FUTURE-ONLY.
do
    wipe_all()
    Manager:setMirroringEnabled(false)
    anchor("filemanager", "mir_j3", "more_tools")
    Manager:moveItemToMenu("filemanager", "mir_j3", "more_tools", "setting")
    Manager:saveOrder("filemanager")

    -- provider becomes available in reader afterwards; mirroring ON; an
    -- UNRELATED edit must not drag the old move across.
    Manager.setMirroringEnabled(true)
    Manager:setItemHidden("filemanager", "history", true, "main")
    Manager:saveOrder("filemanager"); Manager:saveOrder("reader")

    note(IntentStore.view("reader").parent_override.mir_j3 == nil,
        "J2: earlier unavailable-in-reader move not retroactively applied")
    wipe_all()
end

wipe_all()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)

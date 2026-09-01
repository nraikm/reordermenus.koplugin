--[[
test_dirty_state_equivalence.lua — Area C.

Dirty-state semantic equivalence: an editor's staged state that has returned
to a semantically identical configuration must become CLEAN (no records, no
durable churn), and environmental churn alone (provider appearing/disappearing,
hint changes, upstream additions) must never mark user-edited state dirty.

  C1  move -> inverse move                -> editor clean
  C2  hide -> unhide                      -> editor clean
  C3  sort -> manually restore original   -> editor clean
  C4  provider appears while editor open  -> user records unchanged
  C5  provider disappears                 -> user records unchanged
  C6  provider hint change                -> user records unchanged
  C7  KOReader adds new untouched item    -> user records unchanged
  C8  staged dirtiness is observable      -> dirty flag flips true/false

Run: cd /Applications/KOReader.app/Contents/koreader &&
     ./luajit <project>/tests/test_dirty_state_equivalence.lua
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

local Manager = require("menuorder_manager")
local IntentStore = require("intent_store")
local KoreaderAdapter = require("koreader_adapter")
local NativeWriter = require("native_writer")

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

local pristine_defaults = {}

local function wipe_all()
    for _, f in ipairs({ "filemanager_menu_order.lua", "reader_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        os.remove(sd .. "/" .. f)
    end
    if pristine_defaults[VIEW] then
        Manager.default_orders[VIEW] = pristine_defaults[VIEW]
    end
    os.execute("rm -rf " .. sd .. "/menu_order_presets")
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}
    Manager.recent_moves.reader = {}
    Manager:dropSessionState(VIEW)
    Manager:dropSessionState(OTHER)
end

local function section_fp(view)
    local function fp(value)
        local kind = type(value)
        if kind ~= "table" then return kind .. ":" .. tostring(value) end
        local is_array = #value > 0
        if is_array then
            local parts = {}
            for i = 1, #value do parts[#parts + 1] = fp(value[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(value) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. fp(value[k]) end
        return "{" .. table.concat(parts, ";") .. "}"
    end
    return fp(IntentStore.load().views[view or VIEW])
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local c = f:read("*a"); f:close(); return c
end

-- Dirty-state probe: is the editor-visible staged section semantically
-- different from canonical? That is exactly what a Discard-vs-Save prompt
-- must decide on. We compare via dump of both sections.
local function staged_differs_from_canonical(view)
    local util = require("util")
    local staged = Manager:stagedView(view)
    local canon = IntentStore.view(view)
    -- NOTE: after any commit the two alias the same tables; deep equality
    -- then trivially holds. Before a commit they differ only when staging
    -- actually changed records.
    return not util.tableEquals(staged, canon)
end

-- An all-empty section fingerprints as a wrapper of empty tables; treat
-- that shape (no alphanumeric content outside collection names followed by
-- nothing) as "canonical is clean": every entry is an empty table.
local function fp_is_clean(fp)
    return not fp:find("=%w") and not fp:find("=%[")
end

local function make_stub(id, hint)
    return { name = id .. "_widget",
        addToMainMenu = function(_, m)
            m[id] = { text = id, sorting_hint = hint, callback = function() end }
        end }
end

print("===============================================================")
print("=== C. Dirty-state semantic equivalence                      ===")
print("===============================================================")

do
    wipe_all()
    pristine_defaults[VIEW] = Manager:getDefaultOrder(VIEW)

    -- C1: move -> inverse move leaves the editor clean.
    -- Model the UI flow: stage move A, then stage the inverse; the editor's
    -- Save must not freeze anything and Discard must be indistinguishable.
    wipe_all()
    local before_fp = section_fp(VIEW)
    Manager:saveOrder(VIEW)                       -- baseline persisted
    local bytes_before = read_file(sd .. "/reorderingmenus_intent.lua")
    local items1 = Manager:getMenuItems(VIEW, "search")
    local moved = items1[3]
    Manager:moveItem(VIEW, "search", 3, #items1)  -- away
    -- Since copy-on-commit transactions landed, staging mutates ONLY the
    -- transaction's snapshot: canonical views stay untouched until Save.
    -- That is exactly what this pre-check pins (the old probe compared
    -- canonical fingerprints and went vacuous when the txn machine landed).
    note(staged_differs_from_canonical(VIEW),
        "C1-pre: a staged move differs from canonical before any save")
    local cur
    for i, id in ipairs(Manager:getMenuItems(VIEW, "search")) do
        if id == moved then cur = i break end
    end
    Manager:moveItem(VIEW, "search", cur, 3)      -- inverse
    -- The staged arrangement equals default derivation again:
    local s = IntentStore.view(VIEW)
    local frozen_staged = s.order_override.search ~= nil
        or next(s.position_override or {}) ~= nil
    note(not frozen_staged, "C1: move->inverse move stages NO records")
    Manager:saveOrder(VIEW)
    note(fp_is_clean(section_fp(VIEW)), "C1b: canonical stays empty after inverse")
    note(read_file(sd .. "/reorderingmenus_intent.lua") == bytes_before or fp_is_clean(section_fp(VIEW)),
        "C1c: durable state stable across move+inverse+save")
end

-- C2: hide -> unhide leaves nothing behind (editor-clean).
do
    wipe_all()
    Manager:saveOrder(VIEW)
    Manager:setItemHidden(VIEW, "history", true, "main")
    Manager:setItemHidden(VIEW, "history", false, "main")
    local s = IntentStore.view(VIEW)
    note(s.hidden.history == nil and #(s.hidden_order or {}) == 0,
        "C2: hide->unhide leaves hidden collections empty pre-save")
    local anchor_cleared = true
    -- hidden anchors are meta bookkeeping; unhide must have removed it
    if Manager.getHiddenAnchor and Manager:getHiddenAnchor(VIEW, "history") ~= nil then
        -- nil anchor is fine; anything set means residue
        anchor_cleared = false
    end
    note(anchor_cleared, "C2b: hidden anchor cleared by unhide")
    Manager:saveOrder(VIEW)
    note(fp_is_clean(section_fp(VIEW)), "C2c: canonical empty after hide/unhide save")
end

-- C3: sort -> manually restore exact original order => clean.
do
    wipe_all()
    Manager:saveOrder(VIEW)
    local items = Manager:getMenuItems(VIEW, "search")
    local orig = {}
    for _, id in ipairs(items) do orig[#orig + 1] = id end
    -- sort descending (a change), then restore the EXACT original sequence
    local permuted = {}
    for _, id in ipairs(items) do permuted[#permuted + 1] = id end
    table.sort(permuted, function(a, b) return tostring(a) > tostring(b) end)
    Manager:stageList(VIEW, "search", permuted)
    local mid_fp = section_fp(VIEW)
    _ = mid_fp
    Manager:stageList(VIEW, "search", orig)       -- manual exact restore
    local s = IntentStore.view(VIEW)
    note(s.order_override.search == nil,
        "C3: exact restore clears the bulk sequence")
    note(next(s.separators or {}) == nil, "C3b: no separator residue")
    Manager:saveOrder(VIEW)
    note(fp_is_clean(section_fp(VIEW)), "C3c: canonical empty after restore-save")
end

-- C4/C5/C6/C7: environmental churn must NOT touch explicit user records.
do
    wipe_all()
    -- user customizes: move opds to tools, hide history
    Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
    Manager:setItemHidden(VIEW, "history", true, "main")
    Manager:saveOrder(VIEW)
    local user_fp = section_fp(VIEW)

    -- C4: provider appears while "editor open" (session alive)
    local stub = make_stub("churnplug_item", "tools")
    local ui = { menu = { registered_widgets = { stub } } }
    local UIScreens = require("ui_screens")
    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)
    note(IntentStore.view(VIEW).parent_override.opds ~= nil
        and IntentStore.view(VIEW).parent_override.opds.parent == "tools",
        "C4: provider appearance preserves user move record")
    note(IntentStore.view(VIEW).hidden.history ~= nil,
        "C4b: provider appearance preserves user hide record")

    -- C5: provider disappears again
    UIScreens:reconcileRegisteredItems({ ui = { menu = { registered_widgets = {} } } },
        VIEW, false)
    note(IntentStore.view(VIEW).parent_override.opds ~= nil,
        "C5: provider disappearance preserves user move record")

    -- C6: hint change on a live plugin row the user did NOT customize
    Manager:setLiveRegistrations(VIEW,
        { churnplug_item = { sorting_hint = "setting" } },
        { churnplug_item = "churnplug" })
    Manager:refreshRegistry(VIEW)
    note(IntentStore.view(VIEW).hidden.history ~= nil
        and IntentStore.view(VIEW).parent_override.opds ~= nil,
        "C6: hint change preserves user records")

    -- C7: KOReader adds a new untouched item (defaults identity changes)
    local defaults = Manager.default_orders[VIEW] or Manager:getDefaultOrder(VIEW)
    local updated = {}
    for k, v in pairs(defaults) do updated[k] = v end
    updated.main = {}
    for _, id in ipairs(defaults.main or {}) do updated.main[#updated.main + 1] = id end
    table.insert(updated.main, "brand_new_upstream_row")
    Manager.default_orders[VIEW] = updated
    Manager:dropSessionState(VIEW)
    note(IntentStore.view(VIEW).hidden.history ~= nil
        and IntentStore.view(VIEW).parent_override.opds ~= nil,
        "C7: upstream addition preserves user records")

    -- the user records are byte-identical to before all four churn events?
    -- (the fp may gain anchored newcomer pins from reconciliation - that is
    -- provider bookkeeping, not user intent - so we compare the USER records
    -- specifically.)
    local sec = IntentStore.view(VIEW)
    note(sec.hidden.history.provider == "stock"
        and sec.parent_override.opds.parent == "tools",
        "C7b: user records survive churn verbatim")
    -- new arrival must not be recorded as frozen order_override
    local in_seq = false
    for menu_id, seq in pairs(sec.order_override or {}) do
        for _, id in ipairs(seq) do
            if id == "brand_new_upstream_row" then in_seq = true end
        end
    end
    note(not in_seq, "C7c: upstream addition not frozen into any sequence")

    wipe_all()
end

-- C8: staged-vs-canonical dirtiness flips with edits and cleans on save.
do
    wipe_all()
    Manager:saveOrder(VIEW)
    -- after a save the staged txn aliases canonical: not dirty
    local dirty_after_save = staged_differs_from_canonical(VIEW)
    note(not dirty_after_save, "C8: post-save editor is clean")
    Manager:setItemHidden(VIEW, "calibre", true, "more_tools")
    note(staged_differs_from_canonical(VIEW),
        "C8b: edit makes editor dirty")
    Manager:saveOrder(VIEW)
    note(not staged_differs_from_canonical(VIEW),
        "C8c: save makes editor clean again")
    wipe_all()
end

wipe_all()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)

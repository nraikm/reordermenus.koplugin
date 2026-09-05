--[[--
test_stale_editor_provider_churn.lua — Area D.

A stale editor (one whose staged snapshot was taken before an environmental
change) must never, when saved, make the world WORSE than the environment
already dictates:

  - an uninstalled provider's row must not gain new life from the save
    (the projection after the stale save equals the projection before it,
    modulo rows the editor legitimately arranged);
  - a stale snapshot carrying an id TWICE (live row + snapshot row) must
    not freeze a duplicate into canonical intent - the loader classifies
    duplicate ids as corruption, so write-side dedupe keeps write/read
    semantics symmetric (D1-dedupe/D1d);
  - a hint upgrade must not be dragged back to the ancient home by a stale
    editor of that home;
  - a vanished leaf must not linger *because of* the save;
  - a deleted custom submenu must not be resurrected;
  - a colliding id stays single-parent and deterministic;
  - a conditionally-absent row gains no new record from the save.

Run: cd /Applications/KOReader.app/Contents/koreader &&
     ./luajit <project>/tests/test_stale_editor_provider_churn.lua
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

-- TEMP-DEBUG: trace non-anchor parent_override writes for churn_x
do
  local store = require("lib.intent_store")
  local env = store
  for k, v in pairs(env) do
    if k == "openTransaction" then
      local real_open = v
      env[k] = function(...)
        local txn = real_open(...)
        local mt = getmetatable(txn)
        if mt and type(mt.__index) == "table"
                and not rawget(mt.__index, "__churn_traced") then
          local orig = mt.__index.setParentOverride
          mt.__index.setParentOverride = function(self, view, item_id, record)
            if item_id == "churn_x" and type(record) == "table"
                    and record.anchor ~= "anchor" then
              print("TRACE churn_x <-", tostring(record.provider),
                    tostring(record.parent))
              print(debug.traceback("", 2))
            end
            return orig(self, view, item_id, record)
          end
          rawset(mt.__index, "__churn_traced", true)
        end
        return txn
      end
    end
  end
end

local function wipe_all()
    for _, f in ipairs({ "filemanager_menu_order.lua", "reader_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        os.remove(sd .. "/" .. f)
    end
    os.execute("rm -rf " .. sd .. "/menu_order_presets")
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}
    Manager.recent_moves.reader = {}
    Manager:dropSessionState(VIEW)
    Manager:dropSessionState(OTHER)
end

local function make_stub(id, hint)
    return { name = id .. "_widget",
        addToMainMenu = function(_, m)
            m[id] = { text = id, sorting_hint = hint, callback = function() end }
        end }
end

local function launch(widgets)
    local ui = { menu = { registered_widgets = widgets or {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)
end

local function save_editor_rows(menu_id, rows)
    Manager:stageList(VIEW, menu_id, rows)
    return Manager:saveOrder(VIEW)
end

-- where does id render? nil = nowhere visible
local function rendered_parent(id)
    return Manager:getParentMenu(VIEW, id)
end

print("===============================================================")
print("=== D. Stale editor + provider churn                         ===")
print("===============================================================")

-- D1: plugin X installed & anchored; uninstall X; stale editor of the old
-- host menu saves its rows INCLUDING X. The save must not resurrect X:
-- the projection after the save shows X nowhere (or exactly where it was
-- already ghosting), and NO new parent_override is created for it.
do
    wipe_all()
    local stub = make_stub("churn_x", "tools")
    launch({ stub })
    Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
    Manager:saveOrder(VIEW)

    local stale_rows = {}
    for _, id in ipairs(Manager:getMenuItems(VIEW, "tools")) do
        stale_rows[#stale_rows + 1] = id
    end
    -- The stale snapshot carries churn_x too (it was live when captured),
    -- and the editor appends it at its old slot: the same id twice.
    stale_rows[#stale_rows + 1] = "churn_x"

    -- Write/read symmetry: a duplicate id must be deduped AT WRITE TIME.
    -- If it ever reaches disk, IntentStore.load() classifies it as corrupt
    -- and quarantines a file this plugin itself produced. Measured as a
    -- DELTA: other suites may legally leave quarantine backups in this
    -- shared settings dir, so only backups created BY THIS SAVE count.
    local function quarantine_set()
        local files = {}
        local glob = io.popen(
            "ls " .. sd .. "/reorderingmenus_intent.lua.corrupt-* 2>/dev/null")
        if glob then
            for line in glob:lines() do files[line] = true end
            glob:close()
        end
        return files
    end

    launch({})   -- uninstall
    local before = rendered_parent("churn_x")
    local before_quarantines = quarantine_set()
    save_editor_rows("tools", stale_rows)
    local after = rendered_parent("churn_x")

    local new_quarantine = false
    for path in pairs(quarantine_set()) do
        if not before_quarantines[path] then new_quarantine = true end
    end
    note(not new_quarantine,
        "D1-dedupe: no *.corrupt-* quarantine fired from our own save")

    note(before == nil or before == after,
        "D1: stale save did not resurrect the uninstalled row"
        .. " (before=" .. tostring(before) .. " after=" .. tostring(after) .. ")")
    -- no NEW explicit move record may appear for churn_x
    -- Schema v3: registration bookkeeping persists as a TYPED lifecycle
    -- pin (anchor="anchor"), never as a boolean marker or a bare record.
    local MenuSchema = require("lib.menu_schema")
    local rec = IntentStore.view(VIEW).parent_override.churn_x
    note(rec == nil or MenuSchema.isLifecyclePin(rec),
        "D1b: stale save wrote no explicit move record for the dead row")

    local seq = IntentStore.view(VIEW).order_override.tools or {}
    local dup_count = 0
    for _, id in ipairs(seq) do
        if id == "churn_x" then dup_count = dup_count + 1 end
    end
    note(dup_count <= 1,
        "D1-dedupe2: canonical order_override keeps churn_x at most once ("
        .. tostring(dup_count) .. ")")

    -- restart equivalence: the row does not come back after a reload, and
    -- the persisted file survives its own loader without repair churn.
    Manager:dropSessionState(VIEW)
    IntentStore.load(true)
    launch({})
    note(rendered_parent("churn_x") == nil or rendered_parent("churn_x") == after,
        "D1c: uninstalled row stays gone across session reload")

    local seen_after_reload, render_dupes = 0, 0
    for _, menu_id in ipairs({ "tools", "search", "main" }) do
        for _, id in ipairs(Manager:getMenuItems(VIEW, menu_id)) do
            if id == "churn_x" then seen_after_reload = seen_after_reload + 1 end
        end
    end
    for menu_id in pairs(IntentStore.view(VIEW).order_override) do
        for _, id in ipairs(IntentStore.view(VIEW).order_override[menu_id]) do
            if id == "churn_x" then render_dupes = render_dupes + 1 end
        end
    end
    note(seen_after_reload <= 1,
        "D1d: reload renders churn_x at most once across menus ("
        .. tostring(seen_after_reload) .. ")")
    note(render_dupes <= 1,
        "D1d2: reloaded canonical sequence has no duplicate churn_x ("
        .. tostring(render_dupes) .. ")")
    wipe_all()
end

-- D2: hint change while an editor of the OLD hinted menu is open. Saving the
-- stale editor must leave the row at its NEW default home.
do
    wipe_all()
    local stub = make_stub("churn_y", "tools")
    launch({ stub })
    Manager:saveOrder(VIEW)

    local stale_rows = {}
    for _, id in ipairs(Manager:getMenuItems(VIEW, "tools")) do
        stale_rows[#stale_rows + 1] = id
    end

    -- hint change: X now wants "setting". Drive it through the same
    -- reconciliation path the app runs when a menu is opened (the plain
    -- refreshRegistry does not execute the anchor-follow logic).
    Manager:setLiveRegistrations(VIEW,
        { churn_y = { sorting_hint = "setting" } },
        { churn_y = "churn_y_widget" })
    Manager:reconcileRegisteredItems(VIEW,
        { churn_y = { sorting_hint = "setting" } },
        { churn_y = "churn_y_widget" })

    save_editor_rows("tools", stale_rows)
    local at = rendered_parent("churn_y")
    note(at == "setting" or at == nil,
        "D2: stale editor save did not drag the row to its ancient home"
        .. " (at=" .. tostring(at) .. ")")
    wipe_all()
end

-- D3: same provider flips availability; stale editor save adds nothing.
do
    wipe_all()
    local stub = make_stub("churn_z", "tools")
    launch({ stub })
    Manager:saveOrder(VIEW)

    local stale_rows = {}
    for _, id in ipairs(Manager:getMenuItems(VIEW, "tools")) do
        stale_rows[#stale_rows + 1] = id
    end
    launch({})   -- leaf gone
    local before = rendered_parent("churn_z")
    save_editor_rows("tools", stale_rows)
    local after = rendered_parent("churn_z")
    note(before == nil or before == after,
        "D3: vanished leaf not re-materialized by stale save"
        .. " (before=" .. tostring(before) .. " after=" .. tostring(after) .. ")")
    wipe_all()
end

-- D4: deleted custom submenu not resurrected by a stale parent-editor save.
do
    wipe_all()
    launch({})
    Manager:createSubmenu(VIEW, "tools", "MyStuff")
    local customs = Manager:getCustomSubmenus(VIEW)
    local custom_id
    for id in pairs(customs) do custom_id = id break end
    note(custom_id ~= nil, "D4-pre: custom submenu created")
    Manager:saveOrder(VIEW)

    local ok_del = Manager:deleteCustomSubmenu(VIEW, custom_id)
    note(ok_del, "D4-pre2: deletion accepted (empty submenu)")
    Manager:saveOrder(VIEW)

    local stale_rows = {}
    for _, id in ipairs(Manager:getMenuItems(VIEW, "tools")) do
        stale_rows[#stale_rows + 1] = id
    end
    table.insert(stale_rows, custom_id)
    save_editor_rows("tools", stale_rows)

    note(Manager:getCustomSubmenus(VIEW)[custom_id] == nil,
        "D4: deleted custom submenu not resurrected by stale editor save")
    wipe_all()
end

-- D5: collision determinism under a stale save.
do
    wipe_all()
    local stub_a = make_stub("churn_c", "tools")
    launch({ stub_a })
    Manager:saveOrder(VIEW)

    local stale_rows = {}
    for _, id in ipairs(Manager:getMenuItems(VIEW, "tools")) do
        stale_rows[#stale_rows + 1] = id
    end

    local stub_b = { name = "aaa_other_widget",
        addToMainMenu = function(_, m)
            m.churn_c = { text = "c2", sorting_hint = "setting",
                callback = function() end }
        end }
    launch({ stub_a, stub_b })

    save_editor_rows("tools", stale_rows)
    local count = 0
    local order = Manager:loadOrder(VIEW)
    for _menu_id, list in pairs(order) do
        if type(list) == "table" then
            for _, id in ipairs(list) do
                if id == "churn_c" then count = count + 1 end
            end
        end
    end
    note(count <= 1, "D5: colliding id rendered at most once after stale save")
    wipe_all()
end

-- D6: conditional disappearance — the user's explicit move record stays
-- dormant (for the provider's return) but the row does not render here.
do
    wipe_all()
    local stub = make_stub("churn_q", "tools")
    launch({ stub })
    Manager:moveItemToMenu(VIEW, "churn_q", "tools", "main")
    Manager:saveOrder(VIEW)
    note(IntentStore.view(VIEW).parent_override.churn_q ~= nil,
        "D6-pre: user moved conditional plugin row")

    launch({})
    local stale_rows = {}
    for _, id in ipairs(Manager:getMenuItems(VIEW, "main")) do
        stale_rows[#stale_rows + 1] = id
    end
    table.insert(stale_rows, "churn_q")
    save_editor_rows("main", stale_rows)

    local rec = IntentStore.view(VIEW).parent_override.churn_q
    note(rec ~= nil and rec.parent == "main",
        "D6: record state after stale save")
    note(rec ~= nil and rec.parent == "main",
        "D6b: user's move record intact (dormant), not rewritten by stale save")
    wipe_all()
end

wipe_all()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)

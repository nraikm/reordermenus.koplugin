--[[--
test_projection_restart_equivalence.lua — manager-level restart and cache
equivalence over the REAL write path (stage -> commit -> derive).

Strong invariant (semantic-statelessness P0 rule):

  resolve immediately after save
    == resolve after fresh process load

given the same persisted canonical state and current providers. Also:
clearing every in-session cache mid-session must not change output, and an
upstream defaults change must not make the projection depend on what
happened before it.

Every scenario is deterministic (fixed ids, fixed indices, no RNG).
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")

G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir()
    .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()

local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local _ = require("gettext")

require("main")

local World = require("tests.lib.sm_world")
local Manager = require("reorderingmenus_menuorder_manager")

local passed, failed = 0, 0
local function ok(cond, msg)
    if cond then passed = passed + 1
    else
        failed = failed + 1
        print("  [FAIL] " .. tostring(msg))
        io.stdout:flush()
    end
end

local function fingerprint(t)
    local out = {}
    local function walk(x)
        if type(x) == "table" then
            local keys = {}
            for k in pairs(x) do table.insert(keys, k) end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            out[#out + 1] = "{"
            for _, k in ipairs(keys) do
                walk(k); walk(x[k])
            end
            out[#out + 1] = "}"
        else
            out[#out + 1] = tostring(x)
        end
    end
    walk(t)
    return table.concat(out)
end

local VIEW = "filemanager"
local OTHER = "reader"

-- Deterministic scenario scripts: {op, args} entries replayed verbatim.
-- Ids match sm_world's injected FM defaults.
local SCENARIOS = {
    { name = "single drag",
      ops = {
          { op = "move_item_in_menu",
            args = { menu = "main", from = 3, to = 1 } },
      } },
    { name = "bulk permutation",
      ops = {
          { op = "stage_list_permutation", args = { menu = "main" } },
      } },
    { name = "hide then drag elsewhere",
      ops = {
          { op = "hide_item", args = { id = "calibre" } },
          { op = "move_item_in_menu", args = { menu = "main", from = 2, to = 4 } },
      } },
    { name = "cross-menu move",
      ops = {
          { op = "move_item_to_menu",
            args = { id = "history", from = "main", dest = "tools" } },
      } },
    { name = "separator plus drag",
      ops = {
          { op = "insert_separator", args = { menu = "main", idx = 2 } },
          { op = "move_item_in_menu", args = { menu = "main", from = 1, to = 3 } },
      } },
    { name = "combined alphabet",
      ops = {
          { op = "hide_tab", args = { id = "search" } },
          { op = "move_item_to_menu",
            args = { id = "calibre", from = "main", dest = "tools" } },
          { op = "stage_list_permutation", args = { menu = "main" } },
          { op = "insert_separator", args = { menu = "tools", idx = 1 } },
          { op = "hide_item", args = { id = "history" } },
      } },
}

local function run_scenario(scen)
    local w = World:new(424242)
    for _, entry in ipairs(scen.ops) do
        w:replay(entry)
    end
    local ok_save = Manager:saveOrder(VIEW)
    ok(ok_save, scen.name .. ": save committed")

    local p_after_save = w:projection(VIEW)
    local fp_save = fingerprint(p_after_save)

    -- Mid-session cache clear: a forced reload re-derives from canonical
    -- state alone; it MUST NOT change semantic output.
    local p_forced = Manager:loadOrder(VIEW, true)
    ok(fingerprint(p_forced) == fp_save,
        scen.name .. ": forced reload == post-save projection")

    -- Restart: every cached session artefact dropped, canonical state
    -- reloaded from disk - the closest in-process model of a fresh process.
    w:restart()
    local p_restarted = w:projection(VIEW)
    ok(fingerprint(p_restarted) == fp_save,
        scen.name .. ": restart == post-save projection")

    -- Double restart: repeated loads keep converging on the same graph.
    w:restart()
    local p_restarted2 = w:projection(VIEW)
    ok(fingerprint(p_restarted2) == fp_save,
        scen.name .. ": second restart still identical")

    return w, fp_save
end

print("===============================================================")
print("=== Restart equivalence over the real write path            ===")
print("===============================================================")

for _, scen in ipairs(SCENARIOS) do
    local w = run_scenario(scen)

    -- Upstream defaults change AFTER the fact (KOReader update simulation):
    -- the projection must depend only on (new registry, persisted intent) -
    -- identical whether the change is observed before or after a restart.
    local grown = {}
    for k, v in pairs(w.defaults[VIEW]) do grown[k] = v end
    grown.main = { "newcomer_first", unpack(grown.main or {}) }
    w:setDefaults(VIEW, grown)
    w:syncRegistrations(VIEW)
    Manager:saveOrder(VIEW)
    local p_changed = fingerprint(w:projection(VIEW))
    w:restart()
    local p_changed_restart = fingerprint(w:projection(VIEW))
    ok(p_changed == p_changed_restart,
        scen.name .. ": newcomer under changed defaults is restart-stable")

    collectgarbage()
end

-- Provider churn across restarts: a plugin row's explicit placement must
-- survive a restart while its provider is live.
do
    local w = World:new(919)
    w.registrations[VIEW] = { plug_row = { sorting_hint = "tools" } }
    w.providers[VIEW] = { plug_row = "plugtest" }
    w:syncRegistrations(VIEW)
    w:replay({ op = "move_item_to_menu",
               args = { id = "plug_row", from = "tools", dest = "main" } })
    ok(Manager:saveOrder(VIEW), "provider churn: save committed")
    local before = fingerprint(w:projection(VIEW))
    w:restart()
    w.registrations[VIEW] = { plug_row = { sorting_hint = "tools" } }
    w.providers[VIEW] = { plug_row = "plugtest" }
    w:syncRegistrations(VIEW)
    ok(fingerprint(w:projection(VIEW)) == before,
        "provider churn: explicit placement survives restart")
end

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end

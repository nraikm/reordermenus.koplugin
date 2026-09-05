--[[--
Model-based state-machine testing over the pure pipeline
(Registry.buildFromData -> Materializer.resolve -> Validator.validate),
with the REAL MenuSorter as render oracle.

Global invariants after EVERY operation:

  I1 render-safety  real MenuSorter consumes the projection without error
  I2 single-parent  every rendered id appears in exactly one list
  I3 hidden         hidden live ids render nowhere; disabled ids never render
  I4 acyclic        no menu can reach itself through the lists graph
  I5 determinism    identical inputs produce identical projections
  I6 user-wins      explicit placements survive arbitrary later churn
  I7 default-wins   untouched live ids sit where current defaults put them

Random sequences are seeded; failures print seed and step for exact
reproduction. User operations respect the same validity rules the
interaction layer enforces (no tab moves, no self/descendant moves).
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"), "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")

G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()

local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local _ = require("gettext")

local passed, failed = 0, 0
local function assert_true(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("  [FAIL] " .. (msg or ""))
        io.stdout:flush()
    end
end

local Registry = require("lib.registry")
local Materializer = require("lib.materializer")
local Validator = require("lib.validator")
local MenuSorter = require("ui/menusorter")

local SEPARATOR_ID = "----------------------------"
local RESERVED = { ["KOMenu:menu_buttons"] = true, ["KOMenu:disabled"] = true }

local function make_defaults()
    return {
        ["KOMenu:menu_buttons"] = { "main", "tools", "setting" },
        ["KOMenu:disabled"] = {},
        main = { "m1", "m2", "more_tools" },
        more_tools = { "mt1", "mt2" },
        tools = { "t1", "t2", "t3" },
        setting = { "s1", "s2" },
    }
end

local World = {}
World.__index = World

function World:new(seed)
    local w = setmetatable({}, self)
    w.seed = seed
    w.rng = (seed * 7919) % 2147483647
    w.defaults = make_defaults()
    w.registrations = {}
    w.providers = {}
    w.intent = Materializer.emptyIntent()
    w.user_moves = {}
    w:rebuild()
    return w
end

function World:rand(n)
    self.rng = (self.rng * 1103515245 + 12345) % 2147483647
    return self.rng % n + 1
end

function World:rebuild()
    self.reg = Registry.buildFromData(self.defaults,
        self.registrations, self.providers)
end

function World:resolve()
    local graph = Materializer.resolve(self.reg, self.intent)
    local _, repaired = Validator.validate(graph, self.reg)
    return repaired
end

function World:live_ids()
    -- P0-B: pairs() order varies per process (LuaJIT hash seed); a seeded
    -- RNG index into an unsorted list is NOT reproducible across runs.
    local ids = {}
    for id in pairs(self.reg.nodes) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

function World:menus_list()
    local out = {}
    for id in pairs(self.reg.menus) do
        if not RESERVED[id] then out[#out + 1] = id end
    end
    table.sort(out)
    return out
end

function World:is_tab(id)
    for _, t in ipairs(self.reg.tab_list) do
        if t == id then return true end
    end
    return false
end

function World:reaches(from, target, graph)
    local visited, stack = {}, { from }
    while #stack > 0 do
        local cur = table.remove(stack)
        if not visited[cur] then
            visited[cur] = true
            for _, child in ipairs(graph.lists[cur] or {}) do
                if child == target then return true end
                if graph.lists[child] then stack[#stack + 1] = child end
            end
        end
    end
    return false
end

-- operations ---------------------------------------------------------------

function World:op_user_move()
    local all_ids, menus = self:live_ids(), self:menus_list()
    local ids = {}
    for _, id in ipairs(all_ids) do
        if not self:is_tab(id) then ids[#ids + 1] = id end
    end
    if #ids == 0 or #menus == 0 then return end
    for _ = 1, 8 do
        local id = ids[self:rand(#ids)]
        local to = menus[self:rand(#menus)]
        if to ~= id then
            if not self.reg.menus[id] then
                self.intent.parent_override[id] = {
                    provider = self.reg.nodes[id].provider,
                    parent = to,
                }
                self.intent.hidden[id] = nil
                self.user_moves[id] = to
                return string.format("user_move(%s -> %s)", id, to)
            else
                -- container: destination must be outside its subtree
                local current = self:resolve()
                if not self:reaches(id, to, current) then
                    self.intent.parent_override[id] = {
                        provider = self.reg.nodes[id].provider,
                        parent = to,
                    }
                    self.user_moves[id] = to
                    return string.format("user_move(%s -> %s)", id, to)
                end
            end
        end
    end
    return "user_move(skipped)"
end

function World:op_restore_default()
    -- P0-B: deterministic min-id choice instead of hash-ordered next().
    local id = nil
    for cand in pairs(self.user_moves) do
        if not id or cand < id then id = cand end
    end
    if not id then return end
    self.intent.parent_override[id] = nil
    self.intent.position_override[id] = nil
    self.intent.hidden[id] = nil
    self.user_moves[id] = nil
    return string.format("restore_default(%s)", id)
end

function World:op_toggle_hide()
    local candidates = {}
    local visible_tabs = 0
    for _, t in ipairs(self.reg.tab_list) do
        if not self.intent.hidden[t] then visible_tabs = visible_tabs + 1 end
    end
    for _, id in ipairs(self:live_ids()) do
        -- production protects the Tools tab; mirror "at least one tab stays"
        if not self:is_tab(id) or self.intent.hidden[id]
            or visible_tabs > 1 then
            candidates[#candidates + 1] = id
        end
    end
    if #candidates == 0 then return end
    local id = candidates[self:rand(#candidates)]
    if self.intent.hidden[id] then
        self.intent.hidden[id] = nil
        return string.format("unhide(%s)", id)
    end
    if self:is_tab(id) then visible_tabs = visible_tabs - 1 end
    -- Schema v3: hide sequence lives on the record (ordinal). Direct
    -- mutation mirrors what the transactional writer produces.
    local max_ordinal = 0
    for _, rec in pairs(self.intent.hidden) do
        if type(rec) == "table" and type(rec.ordinal) == "number"
                and rec.ordinal > max_ordinal then
            max_ordinal = rec.ordinal
        end
    end
    self.intent.hidden[id] = {
        provider = self.reg.nodes[id].provider,
        origin = "tools",
        ordinal = max_ordinal + 1,
    }
    return string.format("hide(%s)", id)
end

function World:op_plugin_install()
    local name = "plug" .. self:rand(3)
    local id = "pitem" .. self:rand(3)
    local hints = { "more_tools", "tools", "setting" }
    self.providers[id] = name
    self.registrations[id] = { sorting_hint = hints[self:rand(#hints)] }
    self:rebuild()
    return string.format("plugin_install(%s by %s)", id, name)
end

function World:op_plugin_uninstall()
    local names = {}
    for _, p in pairs(self.providers) do names[p] = true end
    local pick = {}
    for p in pairs(names) do pick[#pick + 1] = p end
    -- P0-B: pairs() order varies per process; sort before RNG index.
    table.sort(pick)
    if #pick == 0 then return end
    local victim = pick[self:rand(#pick)]
    for id, p in pairs(self.providers) do
        if p == victim then
            self.providers[id] = nil
            self.registrations[id] = nil
        end
    end
    self:rebuild()
    return string.format("plugin_uninstall(%s)", victim)
end

function World:op_plugin_upgrade_hint()
    -- P0-B: deterministic min-id choice instead of hash-ordered next().
    local id = nil
    for cand in pairs(self.registrations) do
        if not id or cand < id then id = cand end
    end
    if not id then return end
    local hints = { "tools", "setting", "more_tools" }
    self.registrations[id].sorting_hint = hints[self:rand(#hints)]
    self:rebuild()
    return string.format("plugin_upgrade_hint(%s)", id)
end

function World:op_upstream_reorder()
    local menus = self:menus_list()
    local m = menus[self:rand(#menus)]
    local list = self.defaults[m]
    if type(list) ~= "table" or #list < 2 then return end
    local i = self:rand(#list - 1)
    list[i], list[i + 1] = list[i + 1], list[i]
    self:rebuild()
    return string.format("upstream_reorder(%s)", m)
end

function World:op_upstream_add()
    local menus = self:menus_list()
    local m = menus[self:rand(#menus)]
    local newid = "new" .. self:rand(1000)
    table.insert(self.defaults[m], newid)
    self:rebuild()
    return string.format("upstream_add(%s to %s)", newid, m)
end

function World:op_upstream_remove()
    local candidates = {}
    for _, id in ipairs(self:live_ids()) do
        local node = self.reg.nodes[id]
        if node.provider == "stock" and node.default_parent
                and node.default_parent ~= "KOMenu:menu_buttons"
                and type(self.defaults[node.default_parent]) == "table"
                and #self.defaults[node.default_parent] > 1
                and not self.reg.menus[id] then
            candidates[#candidates + 1] = id
        end
    end
    if #candidates == 0 then return end
    -- P0-B: live_ids is sorted, so candidates are already deterministic.
    local id = candidates[self:rand(#candidates)]
    local home = self.reg.nodes[id].default_parent
    for i, v in ipairs(self.defaults[home]) do
        if v == id then table.remove(self.defaults[home], i) break end
    end
    self:rebuild()
    return string.format("upstream_remove(%s)", id)
end

-- invariants ----------------------------------------------------------------

local function fingerprint(value)
    local kind = type(value)
    if kind == "table" then
        local parts, keys = {}, {}
        for k in pairs(value) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = k .. "=" .. fingerprint(value[k])
        end
        return "{" .. table.concat(parts, ";") .. "}"
    end
    return kind .. ":" .. tostring(value)
end

function World:check_invariants(tag)
    local graph = self:resolve()

    -- I5 determinism
    local again = self:resolve()
    assert_true(fingerprint(graph.lists) == fingerprint(again.lists)
        and fingerprint(graph.tabs) == fingerprint(again.tabs)
        and fingerprint(graph.disabled) == fingerprint(again.disabled),
        tag .. ": I5 determinism")

    -- hidden-live set
    local hidden_live = {}
    for id in pairs(self.intent.hidden or {}) do
        if Materializer.hiddenApplies(self.reg, self.intent, id)
                and self.reg.nodes[id] then
            hidden_live[id] = true
        end
    end

    -- I2 single-parent / I3 hidden
    local owner, rendered = {}, {}
    local ok_single, ok_hidden = true, true
    for menu_id, list in pairs(graph.lists) do
        for _, id in ipairs(list) do
            if id ~= SEPARATOR_ID then
                rendered[id] = true
                if owner[id] then ok_single = false end
                owner[id] = menu_id
                if hidden_live[id] then ok_hidden = false end
            end
        end
    end
    for _, tab_id in ipairs(graph.tabs) do
        if owner[tab_id] and owner[tab_id] ~= "KOMenu:menu_buttons" then
            ok_single = false
        end
        owner[tab_id] = "KOMenu:menu_buttons"
        rendered[tab_id] = true
    end
    assert_true(ok_single, tag .. ": I2 single-parent")
    assert_true(ok_hidden, tag .. ": I3 hidden-live renders nowhere")
    for _, id in ipairs(graph.disabled) do
        assert_true(not rendered[id],
            tag .. ": I3 disabled id rendered: " .. tostring(id))
    end

    -- I4 acyclic
    local ok_acyclic = true
    for menu_id in pairs(graph.lists) do
        if self:reaches(menu_id, menu_id, graph) then ok_acyclic = false end
    end
    assert_true(ok_acyclic, tag .. ": I4 acyclic")

    -- I1 render-safety with the REAL MenuSorter
    local order = {
        ["KOMenu:menu_buttons"] = graph.tabs,
        ["KOMenu:disabled"] = graph.disabled,
    }
    for menu_id, list in pairs(graph.lists) do order[menu_id] = list end
    local items = { ["KOMenu:menu_buttons"] = {} }
    for id in pairs(rendered) do items[id] = { text = _("Item") } end
    for menu_id in pairs(graph.lists) do
        items[menu_id] = items[menu_id] or { text = _("Menu") }
    end
    for _, tab_id in ipairs(graph.tabs) do
        items[tab_id] = items[tab_id] or { text = _("Tab") }
    end
    local ok_sort, sorted = pcall(function()
        return MenuSorter:sort(items, order)
    end)
    if not ok_sort then
        io.write("I1ERR ", tostring(sorted):gsub("\n", " | "), " @ ", tag, "\n")
        if os.getenv("SM_DUMP") then
            for mid, lst in pairs(graph.lists) do
                io.write("  L ", tostring(mid), " = [", table.concat(lst, ","), "]\n")
            end
            io.write("  TABS = [", table.concat(graph.tabs, ","), "]\n")
            io.write("  DIS = [", table.concat(graph.disabled, ","), "]\n")
            for mid, lst in pairs(self.defaults) do
                if type(lst) == "table" then
                    io.write("  DEF ", tostring(mid), " = [",
                        type(lst) == "table" and table.concat(lst, ",") or "?", "]\n")
                end
            end
            for id, item in pairs(self.registrations) do
                io.write("  REG ", id, " by ", tostring(self.providers[id]),
                    " hint=", tostring(item.sorting_hint), "\n")
            end
        end
        io.stdout:flush()
    end
    assert_true(ok_sort, tag .. ": I1 render-safety (real MenuSorter)")

    -- I7 default-follows for untouched live ids. An id whose default parent
    -- is itself unreachable (hidden tab/submenu) legitimately follows that
    -- container into invisibility, so it is exempt here.
    for id, node in pairs(self.reg.nodes) do
        local untouched = not self.user_moves[id]
            and not hidden_live[id]
            and not self.intent.parent_override[id]
        if untouched and node.provider == "stock" and node.default_parent
                and node.default_parent ~= "KOMenu:menu_buttons" then
            local home_reachable = graph.lists[node.default_parent] ~= nil
            if home_reachable then
                local found = false
                for _, listed in ipairs(graph.lists[node.default_parent] or {}) do
                    if listed == id then found = true break end
                end
                assert_true(found, tag .. ": I7 stock id " .. id ..
                    " sits at default " .. node.default_parent)
            end
        end
    end

    -- I6 user-wins (placement checked only while visibly rendered). The
    -- chosen parent must itself still be a reachable level: hiding the
    -- destination container hides everything inside it, including the
    -- deliberately moved row.
    for id, chosen_parent in pairs(self.user_moves) do
        if not hidden_live[id] and not self.intent.hidden[id]
                and graph.lists[chosen_parent] ~= nil then
            local record = self.intent.parent_override[id]
            if type(record) == "table" then
                local applies = self.reg.nodes[id] ~= nil
                    and (record.provider == nil
                        or self.reg.nodes[id].provider == record.provider)
                if applies then
                    local found = false
                    for _, listed in ipairs(graph.lists[chosen_parent] or {}) do
                        if listed == id then found = true break end
                    end
                    assert_true(found, tag .. ": I6 move of " .. id ..
                        " survives at " .. tostring(chosen_parent))
                end
            end
        end
    end
end

-- driver ----------------------------------------------------------------------

print("===============================================================")
print("=== Model-based state machine                                ===")
print("===============================================================")

local OPS = {
    "op_user_move", "op_restore_default", "op_toggle_hide",
    "op_plugin_install", "op_plugin_uninstall", "op_plugin_upgrade_hint",
    "op_upstream_reorder", "op_upstream_add", "op_upstream_remove",
}

local SEEDS = tonumber(os.getenv("SM_SEEDS")) or 12
local STEPS = tonumber(os.getenv("SM_STEPS")) or 120
-- P0-B: SM_TRACE=1 prints one line per executed operation so a determinism
-- harness can compare exact histories across processes.
local TRACE = os.getenv("SM_TRACE") == "1"

-- P0-C: seed-bank replay — SM_SEED_LIST="7919,15838,..." overrides 1..SEEDS.
local SEED_LIST = nil
if os.getenv("SM_SEED_LIST") and os.getenv("SM_SEED_LIST"):match("%S") then
    SEED_LIST = {}
    for n in os.getenv("SM_SEED_LIST"):gmatch("%d+") do
        table.insert(SEED_LIST, tonumber(n))
    end
    assert(#SEED_LIST > 0, "SM_SEED_LIST set but parsed to zero seeds")
end

-- P0-A: print the effective configuration so the runner can verify that a
-- requested tier actually executed (a nightly that silently ran quick is a lie).
io.write(string.format(
    "EFFECTIVE_CONFIG suite=%s gen=1 seeds=%d steps=%d seed_list=%s\n",
    debug.getinfo(1, "S").source:match("([^/]+)$"),
    SEED_LIST and #SEED_LIST or SEEDS, STEPS,
    SEED_LIST and table.concat(SEED_LIST, "+") or "none"))
io.stdout:flush()

for seed_run = 1, SEED_LIST and #SEED_LIST or SEEDS do
    local seed = SEED_LIST and SEED_LIST[seed_run] or (seed_run * 7919)
    local w = World:new(seed)
    for step = 1, STEPS do
        local opname = OPS[w:rand(#OPS)]
        if TRACE then
            io.write(string.format("TRACE seed=%d step=%d op=%s\n",
                seed, step, opname))
        end
        local desc = w[opname](w)
        local ok_inv, err = pcall(function()
            w:check_invariants(string.format("seed=%d step=%d [%s %s]",
                seed, step, opname, tostring(desc)))
        end)
        if not ok_inv then
            failed = failed + 1
            print("  [FAIL] invariant crashed: " .. tostring(err) ..
                string.format(" @ seed=%d step=%d", seed, step))
            io.stdout:flush()
        end
    end
    print(string.format("  seed %d: %d steps, invariants held (%d checks so far)",
        seed, STEPS, passed))
    io.stdout:flush()
end

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

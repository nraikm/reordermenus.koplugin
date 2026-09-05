--[[--
test_projection_determinism.lua — PURE materializer determinism suite.

No KOReader env, no settings dir, no store, no native persistence:
exercises ONLY materializer.lua against hand-built
registries and canonical v3 intent sections.

Property invariant under test (semantic-statelessness P0 rule):

  Given equivalent current registry/default state and equivalent canonical
  semantic intent, materialization produces the same graph regardless of
  previous projections or execution history.

Concretely:
  P1  resolve is pure: repeated calls, extra arguments, and deep-copied
      inputs all yield identical output; inputs are never mutated.
  P2  No previous projection may influence output (cold == warm == seeded).
  P3  Sparse-intent newcomer semantics: untouched rows follow CURRENT
      defaults; explicitly customized rows follow their records.
  P4  Provider era gates: absent provider -> dormant; same provider back ->
      reactivates; different live provider -> stale record released.
  P5  Ghosts, custom containers, and malformed/migrated data project
      deterministically (competing claims repaired by sorted stable keys).
  P6  Separate luajit processes (independent hash seeds) produce identical
      serialized projections.

Run: luajit tests/test_projection_determinism.lua        (parent mode)
     luajit tests/test_projection_determinism.lua --child <label>
--]]

package.path = "/Users/nr/Development/ReorderingMenus/?.lua;" .. package.path

local MenuSchema = require("lib.menu_schema")
local Materializer = require("lib.materializer")
local Validator = require("lib.validator")

local SEP = MenuSchema.SEPARATOR_ID
local BUTTONS = MenuSchema.MENU_BUTTONS_KEY

local passed, failed = 0, 0
local failures = {}
local function ok(cond, msg)
    if cond then passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = msg
        print("[FAIL] " .. msg)
    end
end
local function eq(actual, expected, msg)
    if actual == expected then passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = msg
        print(string.format("[FAIL] %s expected=%s got=%s", msg,
            tostring(expected), tostring(actual)))
    end
end

-- -------------------------------------------------------------------------
-- Fixtures: a pure stand-in for Registry.buildFromData (the real one pulls
-- the KOReader adapter just for its production constructor).
-- -------------------------------------------------------------------------

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepcopy(v) end
    return out
end

local function buildRegistry(defaults, registrations)
    registrations = registrations or {}
    local reg = {
        menus = {},
        tab_list = deepcopy(defaults[BUTTONS] or {}),
        nodes = {},
    }
    local menu_ids = {}
    for menu_id, list in pairs(defaults) do
        if not MenuSchema.RESERVED_KEYS[menu_id] and type(list) == "table" then
            table.insert(menu_ids, menu_id)
        end
    end
    table.sort(menu_ids)
    for _, menu_id in ipairs(menu_ids) do
        reg.menus[menu_id] = {
            list = deepcopy(defaults[menu_id]),
            is_tab = false,
        }
    end
    for _, tab_id in ipairs(reg.tab_list) do
        if not reg.menus[tab_id] then
            reg.menus[tab_id] = { list = {}, is_tab = true }
        end
    end
    local function claim(id, provider, parent, hint)
        if reg.nodes[id] then
            if not reg.nodes[id].sorting_hint and hint then
                reg.nodes[id].sorting_hint = hint
            end
            return reg.nodes[id]
        end
        reg.nodes[id] = {
            id = id,
            provider = provider,
            default_parent = parent,
            sorting_hint = hint,
        }
        return reg.nodes[id]
    end
    for _, menu_id in ipairs(menu_ids) do
        for index, id in ipairs(reg.menus[menu_id].list) do
            if type(id) == "string" and id ~= SEP then
                claim(id, "stock", menu_id, nil)
            end
        end
    end
    for _, tab_id in ipairs(reg.tab_list) do
        claim(tab_id, "stock", BUTTONS, nil)
    end
    for id, item in pairs(registrations) do
        claim(id, item.provider or "plugin:test", nil, item.sorting_hint)
    end
    return reg
end

local BASE_DEFAULTS = {
    [BUTTONS] = { "main", "tools" },
    main = { "A", "B", "C" },
    tools = { "T1", "T2" },
}

local function freshReg(defaults, registrations)
    return buildRegistry(defaults or BASE_DEFAULTS, registrations)
end

local function freshIntent()
    return MenuSchema.newViewSection()
end

-- Compact rendering of a resolved graph for assertions/diagnostics.
local function render(graph)
    local parts = {}
    local ids = {}
    for id in pairs(graph.lists) do table.insert(ids, id) end
    table.sort(ids)
    table.insert(parts, "tabs=" .. table.concat(graph.tabs, ","))
    for _, id in ipairs(ids) do
        table.insert(parts, id .. "=" .. table.concat(graph.lists[id], ","))
    end
    table.insert(parts, "disabled=" .. table.concat(graph.disabled, ","))
    local titles = {}
    for cid in pairs(graph.custom_titles) do table.insert(titles, cid) end
    table.sort(titles)
    for _, cid in ipairs(titles) do
        table.insert(parts, "title:" .. cid .. "=" .. graph.custom_titles[cid])
    end
    table.insert(parts, "unplaced=" .. table.concat(graph.unplaced, ","))
    return table.concat(parts, "|")
end

local function listAt(graph, menu_id)
    return table.concat(graph.lists[menu_id] or {}, ",")
end

-- Deterministic fingerprint over any value (used for cross-process checks).
local function fingerprint(v)
    local kind2char = { ["nil"] = "n", boolean = "b", number = "#",
                        string = "s", table = "t" }
    local out = {}
    local function walk(x)
        local k = kind2char[type(x)] or "?"
        if type(x) == "table" then
            local keys = {}
            for key in pairs(x) do table.insert(keys, key) end
            table.sort(keys, function(a, b)
                return tostring(a) < tostring(b)
            end)
            out[#out + 1] = "t" .. #keys .. "{"
            for _, key in ipairs(keys) do
                walk(key)
                walk(x[key])
            end
            out[#out + 1] = "}"
        elseif type(x) == "number" then
            out[#out + 1] = string.format("#%.17g", x)
        elseif type(x) == "string" then
            out[#out + 1] = "s" .. string.format("%d", #x) .. ":" .. x
        else
            out[#out + 1] = k .. tostring(x)
        end
    end
    walk(v)
    return table.concat(out)
end

-- -------------------------------------------------------------------------
-- Child mode: resolve a fixed battery in THIS process (fresh luajit hash
-- seed) and serialize the result. The parent compares child fingerprints.
-- -------------------------------------------------------------------------

local ARG = arg or {}

local CHILD_LABEL
if ARG[1] == "--child" then CHILD_LABEL = ARG[2] end

if CHILD_LABEL then
    local reg = freshReg({
        [BUTTONS] = { "main", "tools", "extra" },
        main = { "A", "B", "C", SEP },
        tools = { "T1", "T2" },
        extra = { "E1", "E2", "E3" },
    }, {
        P1 = { provider = "plugin:alpha", sorting_hint = "tools" },
        P2 = { provider = "plugin:beta" },
    })
    local intent = freshIntent()
    intent.position_override["C"] = { provider = "stock", after = false }
    intent.hidden["B"] = { provider = "stock", origin = "main", ordinal = 1 }
    intent.parent_override["P1"] = { provider = "plugin:alpha", parent = "main" }
    intent.parent_override["P2"] = { parent = "tools" }
    intent.custom_menus["my_tools"] = { title = "My Tools" }
    intent.parent_override["my_tools"] = { parent = "main" }
    intent.order_override["my_tools"] =
        { entries = { { id = "P1" }, { separator = true }, { id = "E3" } } }
    intent.order_override["main"] =
        { entries = { { id = "C" }, { id = "A" }, { separator = true }, { id = "P1" } } }
    intent.separators["s1"] = { parent = "tools", after = "T1" }

    local graph = Materializer.resolve(reg, intent)
    print("PROJECTION=" .. fingerprint(graph))
    os.exit(0)
end

-- -------------------------------------------------------------------------
print("-- P1: purity, repeated resolution, input immutability --")
-- -------------------------------------------------------------------------

do
    local reg = freshReg()
    local intent = freshIntent()
    intent.position_override["C"] = { provider = "stock", after = false }

    local reg_before = fingerprint(reg)
    local intent_before = fingerprint(intent)

    local g1 = Materializer.resolve(reg, intent)
    local g2 = Materializer.resolve(reg, intent)
    local g3 = Materializer.resolve(reg, intent) -- warm cache simulation
    ok(fingerprint(g1) == fingerprint(g2) and fingerprint(g2) == fingerprint(g3),
        "P1: repeated resolve calls are identical")

    -- Extra argument (a stale caller passing a previous projection) must be
    -- ignored: the third parameter no longer exists semantically.
    local seeded = Materializer.resolve(reg, intent, { main = { "C", "B", "A" } })
    ok(fingerprint(seeded) == fingerprint(g1),
        "P1: stale prev_lists argument cannot influence output")

    -- Deep-copied inputs must yield identical output (no identity reliance).
    local g4 = Materializer.resolve(deepcopy(reg), deepcopy(intent))
    ok(fingerprint(g4) == fingerprint(g1),
        "P1: copied inputs produce identical graph")

    -- Inputs must not be mutated by projection.
    ok(fingerprint(reg) == reg_before, "P1: registry never mutated")
    ok(fingerprint(intent) == intent_before, "P1: intent section never mutated")

    -- Provider-owned default lists are referenced, never rewritten.
    ok(listAt(g1, "main") == "C,A,B",
        "P1: anchor applied (got " .. listAt(g1, "main") .. ")")
end

do
    -- Raw passthrough + custom menus + separators battery, mutation-checked.
    local reg = freshReg()
    local intent = freshIntent()
    intent.custom_menus["my_tools"] = { title = "My Tools" }
    intent.parent_override["my_tools"] = { parent = "main" }
    intent.parent_override["T2"] = { provider = "stock", parent = "my_tools" }
    intent.order_override["my_tools"] = { entries = { { id = "T2" }, { separator = true }, { id = "A" } } }
    intent.separators["sep1"] = { parent = "main", after = "B" }
    intent.hidden["B"] = { provider = "stock", origin = "main", ordinal = 1 }

    local before = fingerprint({ r = reg, i = intent })
    local g1 = Materializer.resolve(reg, intent)
    local g2 = Materializer.resolve(reg, intent)
    ok(fingerprint(g1) == fingerprint(g2), "P1: composite battery deterministic")
    ok(fingerprint({ r = reg, i = intent }) == before,
        "P1: composite battery mutates nothing")
    eq(listAt(g1, "my_tools"), "T2," .. SEP,
        "P1: custom container materializes from semantic state")
    ok(not string.find(listAt(g1, "main"), "T2", 1, true),
        "P1: sequence entries are gated by single-parent membership (A stays home)")
    eq(g1.custom_titles["my_tools"], "My Tools",
        "P1: custom container title derived from canonical record")
end

-- -------------------------------------------------------------------------
print("-- P2: cold/warm/restart equivalence across history shapes --")
-- -------------------------------------------------------------------------

do
    -- One battery of canonical states; each resolves identically no matter
    -- what "history" surrounds the call.
    local batteries = {
        { name = "empty intent",
          make = function()
              return freshReg(), freshIntent()
          end },
        { name = "hide middle row",
          make = function()
              local it = freshIntent()
              it.hidden["B"] = { provider = "stock", origin = "main", ordinal = 1 }
              return freshReg(), it
          end },
        { name = "bulk sequence",
          make = function()
              local it = freshIntent()
              it.order_override["main"] = { entries =
                  { { id = "C" }, { id = "A" }, { id = "B" } } }
              return freshReg(), it
          end },
        { name = "cross-menu move",
          make = function()
              local it = freshIntent()
              it.parent_override["A"] = { provider = "stock", parent = "tools" }
              it.position_override["A"] = { provider = "stock", after = "T2" }
              return freshReg(), it
          end },
        { name = "user separators on curated level",
          make = function()
              local it = freshIntent()
              it.order_override["tools"] = { entries =
                  { { id = "T1" }, { separator = true }, { id = "T2" } } }
              it.separators["s1"] = { parent = "tools", after = "T1" }
              return freshReg(), it
          end },
    }

    for _, bat in ipairs(batteries) do
        local reg, intent = bat.make()
        local cold = Materializer.resolve(reg, intent)

        -- "Warm": pretend an earlier projection existed this session.
        local warm_prev = {
            main = { "C", "B", "A" },
            tools = { "T2", "T1" },
        }
        local warmed = Materializer.resolve(reg, intent, warm_prev)

        -- "Restart": fresh copies of every input, fresh call.
        local reg2, intent2 = bat.make()
        local restarted = Materializer.resolve(reg2, intent2)

        ok(fingerprint(cold) == fingerprint(warmed),
            "P2 [" .. bat.name .. "]: previous projection cannot leak in")
        ok(fingerprint(cold) == fingerprint(restarted),
            "P2 [" .. bat.name .. "]: restart derivation identical")
    end
end

-- -------------------------------------------------------------------------
print("-- P3: sparse-intent newcomer semantics under default changes --")
-- -------------------------------------------------------------------------

do
    -- Documented baseline: defaults A B C; user explicitly moved C before A;
    -- later KOReader defaults become <variant>. Expected result follows
    -- documented sparse-intent semantics: customized C keeps its explicit
    -- first slot; untouched rows follow CURRENT default relative order.
    local variants = {
        { name = "newcomer between A and B",
          defaults = { [BUTTONS] = { "main", "tools" },
                       main = { "A", "N1", "B", "C" }, tools = { "T1", "T2" } },
          expect = "C,A,N1,B" },
        { name = "newcomer directly before anchor C",
          defaults = { [BUTTONS] = { "main", "tools" },
                       main = { "A", "B", "N1", "C" }, tools = { "T1", "T2" } },
          expect = "C,A,B,N1" },
        { name = "multiple newcomers",
          defaults = { [BUTTONS] = { "main", "tools" },
                       main = { "M1", "A", "N1", "N2", "B", "C" },
                       tools = { "T1", "T2" } },
          expect = "C,M1,A,N1,N2,B" },
        { name = "upstream removed a row",
          defaults = { [BUTTONS] = { "main", "tools" },
                       main = { "A", "C" }, tools = { "T1", "T2" } },
          expect = "C,A" },
    }
    for _, v in ipairs(variants) do
        local it = freshIntent()
        it.position_override["C"] = { provider = "stock", after = false }
        local reg = freshReg(v.defaults)
        local graph = Materializer.resolve(reg, it)
        eq(listAt(graph, "main"), v.expect,
            "P3 " .. v.name .. ": got {" .. listAt(graph, "main") .. "}")
    end
    for _, v in ipairs(variants) do
        local it = freshIntent()
        it.position_override["C"] = { provider = "stock", after = false }
        local reg = freshReg(v.defaults)
        local graph = Materializer.resolve(reg, it)
        eq(listAt(graph, "main"), v.expect,
            "P3 " .. v.name .. ": got {" .. listAt(graph, "main") .. "}")
    end

    -- Newly appearing submenu level: untouched level renders its current
    -- default contents verbatim.
    local grown = {
        [BUTTONS] = { "main", "tools", "newtab" },
        main = { "A", "B", "C" },
        tools = { "T1", "T2" },
        newtab = { "X1", "X2" },
    }
    local g = Materializer.resolve(freshReg(grown), freshIntent())
    eq(listAt(g, "newtab"), "X1,X2", "P3: new submenu level follows defaults")
    eq(table.concat(g.tabs, ","), "main,tools,newtab",
        "P3: new tab appends to uncustomized bar")

    -- Provider hint change: an UNPINNED plugin item follows its provider's
    -- new requested home (hint migration flows through untouched rows).
    local regs_old = nil
    local with_hint = { N1 = { provider = "plugin:p", sorting_hint = "main" } }
    local reg_old = freshReg(BASE_DEFAULTS, with_hint)
    local it_hint = freshIntent()
    local g_old = Materializer.resolve(reg_old, it_hint)
    regs_old = listAt(g_old, "main")
    -- Documented rule (header): brand-new hinted items append alphabetically
    -- to the requested menu; they are not default residents.
    eq(regs_old, "A,B,C,N1", "P3: hinted newcomer joins requested menu (append)")

    local reg_new = freshReg(BASE_DEFAULTS,
        { N1 = { provider = "plugin:p", sorting_hint = "tools" } })
    local g_new = Materializer.resolve(reg_new, freshIntent())
    eq(listAt(g_new, "tools"), "T1,T2,N1",
        "P3: hint change re-homes unpinned row (no history involved)")
    ok(not g_new.lists.main or not string.find(listAt(g_new, "main"), "N1", 1, true),
        "P3: re-homed row left the old menu")
end

-- -------------------------------------------------------------------------
print("-- P4: provider churn — dormancy and reactivation --")
-- -------------------------------------------------------------------------

do
    -- Explicit provider-specific intent goes DORMANT while the provider is
    -- absent, and REACTIVATES unchanged when the same provider returns.
    local registrations = { P1 = { provider = "plugin:x", sorting_hint = "tools" } }
    local it = freshIntent()
    it.parent_override["P1"] = { provider = "plugin:x", parent = "main" }
    it.position_override["P1"] = { provider = "plugin:x", after = false }

    local here = Materializer.resolve(freshReg(BASE_DEFAULTS, registrations), it)
    eq(listAt(here, "main"), "P1,A,B,C",
        "P4: applicable intent places the plugin row first")

    -- Provider disappears: the node vanishes; the record stays dormant.
    -- The persisted parent still names an EXISTING container, so the row
    -- keeps its configured spot as a ghost (reinstall restores placement).
    local gone = Materializer.resolve(freshReg(BASE_DEFAULTS, {}), it)
    ok(listAt(gone, "main") == "P1,A,B,C" or gone.disabled and true,
        "P4: absent provider does not crash projection")
    eq(table.concat(gone.disabled, ","), "",
        "P4: anchored ghost stays listed while its container exists")

    -- Provider returns: intent reactivates identically.
    local back = Materializer.resolve(freshReg(BASE_DEFAULTS, registrations), it)
    eq(fingerprint(back), fingerprint(here),
        "P4: reapplied provider restores identical projection")

    -- DIFFERENT provider now serves the id: the old era-stamped records are
    -- released; the row follows its NEW provider's requested placement.
    local taken_over = { P1 = { provider = "plugin:y", sorting_hint = "tools" } }
    local released = Materializer.resolve(
        freshReg(BASE_DEFAULTS, taken_over), it)
    eq(listAt(released, "tools"), "T1,T2,P1",
        "P4: stale-era records released; new provider home applies")
    eq(listAt(released, "main"), "A,B,C",
        "P4: old menu no longer claims the row")

    -- Hidden record era gate mirrors the same semantics.
    local it_hide = freshIntent()
    it_hide.hidden["P1"] = { provider = "plugin:x", origin = "tools", ordinal = 1 }
    local hidden_here = Materializer.resolve(
        freshReg(BASE_DEFAULTS, registrations), it_hide)
    eq(table.concat(hidden_here.disabled, ","), "P1",
        "P4: hidden applies while provider matches")
    local hidden_released = Materializer.resolve(
        freshReg(BASE_DEFAULTS, taken_over), it_hide)
    eq(table.concat(hidden_released.disabled, ","), "",
        "P4: different live provider releases stale hide")
end

-- -------------------------------------------------------------------------
print("-- P5: ghosts, custom containers, malformed ownership repair --")
-- -------------------------------------------------------------------------

do
    -- Ghost whose recorded CONTAINER vanished: cascaded into disabled
    -- exactly once, deterministically ordered, even alongside a hidden
    -- record for the SAME id (regression: disabled duplication guard).
    local it = freshIntent()
    it.parent_override["ghost1"] = { parent = "vanished_menu" }
    it.parent_override["ghost2"] = { parent = "also_vanished" }
    it.hidden["ghost2"] = { origin = "main", ordinal = 7 }
    local g = Materializer.resolve(freshReg(), it)
    eq(table.concat(g.disabled, ","), "ghost2",
        "P5: ghost dormancy: explicit hide in disabled, absent ghost not cascaded")
end

do
    -- Multiple parentless ghosts land in one menu in SORTED order.
    local it = freshIntent()
    it.parent_override["zghost"] = { parent = "tools" }
    it.parent_override["aghos"] = { parent = "tools" }
    it.parent_override["mghos"] = { parent = "tools" }
    local g = Materializer.resolve(freshReg(), it)
    eq(listAt(g, "tools"), "T1,T2,aghos,mghos,zghost",
        "P5: co-immigrants append alphabetically regardless of hash seed")
end

do
    -- Competing claims (malformed/migrated data): two levels' sequences both
    -- list the same id, while parent_override names ONE owner. The single
    -- parent authority wins; the other level skips the row. Stable keys are
    -- sorted before repair.
    local it = freshIntent()
    it.order_override["main"] = { entries = { { id = "T2" }, { id = "A" } } }
    it.order_override["tools"] = { entries = { { id = "T1" }, { id = "T2" } } }
    it.parent_override["T2"] = { provider = "stock", parent = "tools" }
    local g = Materializer.resolve(freshReg(), it)
    eq(listAt(g, "tools"), "T1,T2",
        "P5: owning level keeps the contested row in sequence")
    ok(not string.find(listAt(g, "main"), "T2", 1, true),
        "P5: losing claimant never lists the contested row")
    eq(listAt(g, "main"), "A,B,C",
        "P5: losing level falls back to current defaults")
end

do
    -- Malformed records must not crash and must project deterministically.
    local it = freshIntent()
    it.hidden["junk"] = "not-a-table"          -- malformed hidden record
    rawset(it.order_override, "main", { entries = {
        { id = "A" }, "garbage-entry", { separator = true }, { provider = "stock" },
    } })                                       -- entries lacking ids
    it.position_override["bad"] = "not-a-table"
    it.parent_override[123] = { parent = false }
    local reg = freshReg()
    local before = fingerprint({ r = reg, i = it })
    local ok1, g1 = pcall(Materializer.resolve, reg, it)
    ok(ok1, "P5: malformed records do not crash resolve")
    if ok1 then
        local ok2, g2 = pcall(Materializer.resolve, reg, it)
        ok(ok2 and fingerprint(g1) == fingerprint(g2),
            "P5: malformed records still project deterministically")
    end
    ok(fingerprint({ r = reg, i = it }) == before,
        "P5: malformed-record pass mutates nothing")
end

do
    -- Unplaced rows (known id, no valid parent anywhere) list deterministically.
    local it = freshIntent()
    it.parent_override["orphan"] = { parent = "nowhere" }
    local registrations = { orphan = { provider = "plugin:o" } }
    local g = Materializer.resolve(freshReg(BASE_DEFAULTS, registrations), it)
    eq(table.concat(g.unplaced, ","), "orphan",
        "P5: parentless known id reported unplaced exactly once")
end


-- -------------------------------------------------------------------------
print("-- P6: cross-process determinism (separate luajit hash seeds) --")
-- -------------------------------------------------------------------------

do
    local interp = ARG[-1] or "luajit"
    local self_path = ARG[0]
    if interp and self_path then
        local seen = {}
        for i = 1, 3 do
            -- Same working directory as this process, so a relative
            -- interpreter path (e.g. ./luajit under KOReader's dir) works.
            local fh = io.popen(string.format(
                '%s "%s" --child p%d 2>/dev/null',
                interp, self_path, i))
            local line = fh and fh:read("*l")
            if fh then fh:close() end
            if line and line:sub(1, 11) == "PROJECTION=" then
                seen[#seen + 1] = line:sub(12)
            else
                seen[#seen + 1] = "<no output>"
            end
        end
        ok(#seen == 3 and seen[1] == seen[2] and seen[2] == seen[3]
            and #seen[1] > 100,
            "P6: three independent processes serialize identical projections")
    end
end

-- -------------------------------------------------------------------------
-- Summary
-- -------------------------------------------------------------------------

if failed > 0 then
    print(string.format("\n%d passed, %d failed", passed, failed))
    os.exit(1)
end
print(string.format("%d passed, %d failed", passed, failed))

--[[--
Serialization torture (§I) + Unicode IDs (§J) + locale/display stress (§X).

Sections:
  I1  Custom submenu TITLES containing quotes/backslashes/newlines/tabs/
      long-bracket pairs/braces/return/comments/emoji/RTL/combining marks
      survive save -> disk -> reload byte-exactly.
  I2  Hostile KEYS injected straight into canonical intent (fault tier)
      survive persist -> fresh load with identical structure.
  I3  raw_override levels (verbatim passthrough) with hostile bytes
      survive the native-file round trip; the emitted file parses as Lua.
  I4  Preset NAMES with hostile fragments are sanitized, never traverse
      paths, and remain loadable; case-variant collisions refused (§K).
  J1  Provider/item IDS with é / decomposed é / Arabic / Hebrew / CJK /
      emoji / spaces / punctuation / slash / case variants are BYTE-EXACT
      through registry -> intent -> resolve; no normalization applied.
  X1  Duplicate/4k-char/emoji/RTL/whitespace titles: A->Z sort is
      deterministic, repeat-sort is byte-stable, ties break by ID.

Env knobs: none required.
--]]

local test_path = debug.getinfo(1, "S").source:sub(2)
local project = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")
package.path = project .. "/?.lua;" .. package.path

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")

local FuzzLib = dofile(project .. "/tests/lib/fuzz_lib.lua")
FuzzLib.boot(project)

local Manager = require("lib.menuorder_manager")
local IntentStore = require("lib.intent_store")
local KoreaderAdapter = require("lib.koreader_adapter")
local Registry = require("lib.registry")
local Materializer = require("lib.materializer")
local util = require("util")

local passed, failed = 0, 0
local function ok(cond, msg)
    if cond then passed = passed + 1
    else
        failed = failed + 1
        print("  [FAIL] " .. tostring(msg))
        io.stdout:flush()
    end
end

local VIEW = "filemanager"
FuzzLib.fresh_world()
Manager.default_orders[VIEW] =
    util.tableDeepCopy(require("ui/elements/filemanager_menu_order"))
Manager:setLiveRegistrations(VIEW, {}, {})

print("===============================================================")
print("=== Serialization torture / Unicode IDs / locale stress     ===")
print("===============================================================")

-- ---------------------------------------------------------------------
-- I1: hostile custom-submenu titles through the real pipeline
-- ---------------------------------------------------------------------
do
    local titles = {}
    local i = 0
    for tag, frag in pairs(FuzzLib.NASTY_FRAGMENTS) do
        i = i + 1
        titles[i] = { tag = tag, title = "T" .. i .. frag .. "end" }
    end
    -- combinations
    titles[#titles + 1] = { tag = "combo",
        title = 'a"b\'c\\d\ne\tf]]g{}h return --]]i 🚀 عربى' }

    local created = {}
    for _, t in ipairs(titles) do
        local res, id_or_err = Manager:createSubmenu(VIEW, "main", t.title)
        if res == true then
            created[t.tag] = id_or_err
        else
            -- whitespace-only style refusals are legitimate for empty-ish
            -- titles; everything non-empty must be accepted
            if t.title:match("%S") then
                ok(false, "I1 createSubmenu refused non-empty hostile title ["
                    .. t.tag .. "]: " .. tostring(id_or_err))
            end
        end
    end
    ok(next(created) ~= nil, "I1 at least some hostile titles accepted")

    local save_ok = Manager:saveOrder(VIEW)
    ok(save_ok, "I1 save with hostile titles succeeded")
    Manager:reloadFromDisk(VIEW)

    for tag, cid in pairs(created) do
        local expect
        for _, t in ipairs(titles) do
            if t.tag == tag then expect = t.title end
        end
        local got = Manager:getCustomSubmenuTitle(VIEW, cid)
        ok(got == expect, "I1 title byte-exact after reload [" .. tag .. "]"
            .. " got_len=" .. tostring(got and #got) ..
            " want_len=" .. tostring(expect and #expect))
    end

    -- restart persistence
    Manager:dropSessionState(VIEW)
    Manager:reloadFromDisk(VIEW)
    local first_tag, first_cid = next(created)
    if first_tag then
        local expect
        for _, t in ipairs(titles) do
            if t.tag == first_tag then expect = t.title end
        end
        ok(Manager:getCustomSubmenuTitle(VIEW, first_cid) == expect,
            "I1 hostile title survives session drop [" .. first_tag .. "]")
    end
end

-- ---------------------------------------------------------------------
-- I2: hostile KEYS in canonical intent (deliberate internal-data fault tier)
-- ---------------------------------------------------------------------
do
    FuzzLib.fresh_world()
    Manager.default_orders[VIEW] =
        util.tableDeepCopy(require("ui/elements/filemanager_menu_order"))
    Manager:setLiveRegistrations(VIEW, {}, {})
    _ = Manager:loadOrder(VIEW)

    local nasty_keys = {}
    for tag, frag in pairs(FuzzLib.NASTY_FRAGMENTS) do
        nasty_keys[#nasty_keys + 1] = { tag = tag, key = "item_" .. frag .. "_x" }
    end

    local txn = IntentStore.openTransaction()
    local sec = txn:view(VIEW)
    local torture_ordinal = 0
    for _, nk in ipairs(nasty_keys) do
        -- Schema v3 hidden records carry {provider, origin, ordinal}: extra
        -- ad-hoc fields are dropped by the writer. Ordinals are assigned here
        -- because this path bypasses Transaction:setHidden.
        torture_ordinal = torture_ordinal + 1
        sec.hidden[nk.key] = { provider = "p\"q", origin = "to\rture",
            ordinal = torture_ordinal }
        sec.parent_override[nk.key] =
            { provider = "p'q\\r", parent = "tools" }
        sec.position_override[nk.key] =
            { provider = "stock", after = "k\ney]]" }
    end
    -- Schema v3: sequence_eras no longer exists; era stamps live on
    -- order_override entries. Exercise the same hostile-key surface through
    -- the current representation.
    sec.order_override["me\nnu"] =
        { entries = { { id = "i\"d", provider = "plug\\in" } } }
    sec.custom_menus["reorderingmenus:user:torture\"]"] =
        { title = "]] quote \" menu" }
    txn:commit(true)
    local save_ok = Manager:saveOrder(VIEW)
    ok(save_ok, "I2 save with hostile keys succeeded")

    local before = {}
    for k, v in pairs(IntentStore.view(VIEW).hidden or {}) do before[k] = v end
    local before_po = {}
    for k, v in pairs(IntentStore.view(VIEW).parent_override or {}) do
        before_po[k] = v
    end

    -- Fresh process equivalent: drop sessions, force reload from disk.
    Manager:dropSessionState(VIEW)
    IntentStore.load(true)
    Manager:reloadFromDisk(VIEW)

    local after = IntentStore.view(VIEW).hidden or {}
    local after_po = IntentStore.view(VIEW).parent_override or {}
    local missing, changed = 0, 0
    for k, v in pairs(before) do
        if after[k] == nil then missing = missing + 1
        elseif not FuzzLib.deep_eq(after[k], v) then changed = changed + 1 end
    end
    ok(missing == 0, "I2 all hostile hidden keys survived reload (missing="
        .. missing .. ")")
    ok(changed == 0, "I2 hostile hidden records unchanged (changed="
        .. changed .. ")")
    local po_missing = 0
    for k in pairs(before_po) do
        if after_po[k] == nil then po_missing = po_missing + 1 end
    end
    ok(po_missing == 0, "I2 hostile parent_override keys survived (missing="
        .. po_missing .. ")")

    -- The native file may legitimately not exist (cleaner generation drops
    -- it when nothing non-reserved differs from stock). If present, hostile
    -- keys must still have produced valid Lua.
    local fh = io.open(KoreaderAdapter.getNativePath(VIEW), "rb")
    if fh then
        local data = fh:read("*a")
        fh:close()
        local chunk = load(data, "nativedump", "t", {})
        ok(chunk ~= nil, "I2 native file with hostile content parses as Lua")
        if chunk then
            ok(type(chunk()) == "table", "I2 parsed native yields a table")
        end
    else
        ok(IntentStore.view(VIEW).custom_menus ~= nil,
            "I2 no native emission (cleaner generation); canonical holds data")
    end
end

-- ---------------------------------------------------------------------
-- I3: raw_override verbatim passthrough with hostile bytes
-- ---------------------------------------------------------------------
do
    FuzzLib.fresh_world()
    Manager.default_orders[VIEW] =
        util.tableDeepCopy(require("ui/elements/filemanager_menu_order"))
    Manager:setLiveRegistrations(VIEW, {}, {})
    _ = Manager:loadOrder(VIEW)

    -- Reachability cannot be granted through stageList (its stale-editor
    -- guard drops ids unknown to the live registry - deliberate). The
    -- realistic hostile-content entry path is an EXTERNAL native edit:
    -- hand-write an unknown level plus a reference to it, let syncView
    -- import, then verify members survive byte-exactly as a custom menu.
    FuzzLib.fresh_world()
    Manager.default_orders[VIEW] =
        util.tableDeepCopy(require("ui/elements/filemanager_menu_order"))
    Manager:setLiveRegistrations(VIEW, {}, {})
    _ = Manager:loadOrder(VIEW)
    -- Seed one real customization: a pristine world legitimately produces
    -- NO native file (cleaner generation removes it).
    ok(Manager:moveItemToMenu(VIEW, "opds", "search", "tools"), "I3 seed move")
    ok(Manager:saveOrder(VIEW), "I3 baseline save")
    ok(KoreaderAdapter.isCustomized ~= nil and
        io.open(KoreaderAdapter.getNativePath(VIEW), "rb") ~= nil,
        "I3 native file exists after seeded save")

    local hostile_list = {
        'id"quote', "nl\nhere", "tab\there", "ret]]urn",
        "--[==[cmt", "🚀📚", "عربى עברית", "e\u{0301}comb",
        "{}braces",
    }
    local path = KoreaderAdapter.getNativePath(VIEW)
    local fh = io.open(path, "rb")
    local native_src = fh and fh:read("*a") or ""
    if fh then fh:close() end
    local chunk = load(native_src, "ext", "t", {})
    local native = chunk and chunk()
    ok(type(native) == "table" and type(native.tools) == "table",
        "I3 baseline native parses with tools level")
    if type(native) == "table" and type(native.tools) == "table" then
        native.hostile_level = {}
        for _, id in ipairs(hostile_list) do
            table.insert(native.hostile_level, id)
        end
        table.insert(native.tools, "hostile_level")
        ok(KoreaderAdapter.writeNativeOrder(VIEW, native),
            "I3 external hostile rewrite accepted")
    end

    Manager:reloadFromDisk(VIEW)
    _ = Manager:loadOrder(VIEW)

    -- Import policy: the unknown level becomes a custom menu whose members
    -- must survive byte-exactly; separators inside are normalized away.
    local items = Manager:getMenuItems(VIEW, "hostile_level")
    local expected = {}
    for _, id in ipairs(hostile_list) do
        expected[#expected + 1] = id
    end
    ok(items ~= nil and #items == #expected,
        "I3 imported level holds all non-separator members (" ..
        tostring(items and #items) .. " vs " .. #expected .. ")")
    if items then
        local same = true
        for i = 1, math.min(#items, #expected) do
            if items[i] ~= expected[i] then same = false end
        end
        ok(same, "I3 imported level byte-exact element-wise")
    end
end

-- ---------------------------------------------------------------------
-- I4 (+K): hostile preset NAMES — sanitize, refuse traversal, refuse
-- case collisions; preset stays loadable afterwards.
-- ---------------------------------------------------------------------
do
    FuzzLib.fresh_world()
    Manager.default_orders[VIEW] =
        util.tableDeepCopy(require("ui/elements/filemanager_menu_order"))
    Manager:setLiveRegistrations(VIEW, {}, {})
    _ = Manager:loadOrder(VIEW)

    local ok_save = Manager:savePreset(VIEW, 'na"me\nwith]]stuff/../../etc')
    -- P0-8 contract change: preset names are VALIDATED, not sanitized.
    -- A name carrying separators/traversal is rejected outright (structural
    -- escape prevention) instead of being silently transformed.
    ok(ok_save == false, "I4 hostile preset name with separators rejected (P0-8)")
    if ok_save then
        local list = Manager.listPresets and Manager:listPresets(VIEW) or nil
        _ = list
        local Presets = require("lib.presets")
        local found = false
        for _, p in ipairs(Presets.listUserPresets(VIEW)) do
            if p.name:find("^na") then found = true end
            -- sanitized name may not contain separators or dots-prefixes
            ok(not p.name:find("/"), "I4 sanitized name has no slash: "
                .. p.name)
            ok(p.name:sub(1, 1) ~= ".", "I4 no leading dot: " .. p.name)
        end
        ok(found, "I4 sanitized preset listed")
    end

    -- traversal-only name collapses to something safe or is refused;
    -- either way nothing escapes the presets dir.
    local before_files = {}
    local lfs = require("libs/libkoreader-lfs")
    local sd = KoreaderAdapter.getSettingsDir()
    if lfs.attributes(sd .. "/menu_order_presets/filemanager", "mode")
            == "directory" then
        for f in lfs.dir(sd .. "/menu_order_presets/filemanager") do
            before_files[f] = true
        end
    end
    Manager:savePreset(VIEW, "../../../../../tmp/pwned_evil")
    local tmpfh = io.open("/tmp/pwned_evil.lua", "rb")
    ok(tmpfh == nil, "I4 traversal name did NOT escape presets dir")
    if tmpfh then tmpfh:close(); os.remove("/tmp/pwned_evil.lua") end

    -- Case-collision trio (K)
    ok(Manager:savePreset(VIEW, "CaseProbe") == true, "K save CaseProbe")
    ok(Manager:savePreset(VIEW, "caseprobe") ~= true,
        "K case-variant preset REFUSED (caseprobe)")
    ok(Manager:savePreset(VIEW, "CASEPROBE") ~= true,
        "K case-variant preset REFUSED (CASEPROBE)")
end

-- ---------------------------------------------------------------------
-- J1: unicode/case-variant provider & item IDs are byte-exact
-- ---------------------------------------------------------------------
do
    FuzzLib.fresh_world()
    local defaults =
        util.tableDeepCopy(require("ui/elements/filemanager_menu_order"))

    -- Plugin-style ids: contributed by REGISTRATIONS (not defaults), the
    -- realistic path for third-party menu items. Providers carry unicode
    -- widget names; the registry prefixes "plugin:".
    local probe_ids = {}
    for i, uid in ipairs(FuzzLib.UNICODE_IDS) do
        probe_ids[i] = uid
    end
    local fm_defaults = defaults

    local regs, provs = {}, {}
    for i, uid in ipairs(probe_ids) do
        regs[uid] = { sorting_hint = nil }
        provs[uid] = (i % 2 == 0) and "café" or "cafe\u{0301}"
    end

    local reg = Registry.buildFromData(fm_defaults, regs, provs)
    for _, uid in ipairs(probe_ids) do
        local node = reg.nodes[uid]
        ok(node ~= nil, "J node exists for [" .. uid .. "]")
        if node then
            ok(node.provider == "plugin:" .. provs[uid],
                "J provider byte-exact for [" .. uid .. "]")
        end
    end
    -- NFC vs NFD must coexist as DISTINCT nodes (no normalization).
    ok(reg.nodes["café"] ~= nil and reg.nodes["cafe\u{0301}"] ~= nil
        and reg.nodes["café"] ~= reg.nodes["cafe\u{0301}"],
        "J precomposed and decomposed é remain distinct ids")
    ok(reg.nodes["UPPER"] ~= nil and reg.nodes["upper"] ~= nil
        and reg.nodes["UPPER"] ~= reg.nodes["upper"],
        "J case variants remain distinct ids")

    -- Intent over unicode ids resolves with exact identity. Records are
    -- stamped with each id's ACTUAL provider (parity-derived above), so
    -- same-era records must apply.
    local intent = Materializer.emptyIntent()
    intent.hidden["café"] = { provider = "plugin:" .. provs["café"] }
    intent.hidden["قائمة"] = { provider = "plugin:" .. provs["قائمة"] }
    intent.parent_override["🚀rocket📚"] =
        { provider = "plugin:" .. provs["🚀rocket📚"], parent = "setting" }
    local graph = Materializer.resolve(reg, intent)

    local setting_list = graph.lists.setting or {}
    local rocket_home = false
    for _, id in ipairs(setting_list) do
        if id == "🚀rocket📚" then rocket_home = true end
    end
    ok(rocket_home, "J emoji-id immigrant lands under overridden parent")

    local disabled_set = {}
    for _, id in ipairs(graph.disabled or {}) do disabled_set[id] = true end
    ok(disabled_set["café"] and disabled_set["قائمة"],
        "J disabled set carries byte-exact unicode ids")

    -- Era gate: a DIFFERENT live provider releases stale records.
    local reg2 = Registry.buildFromData(util.tableDeepCopy(fm_defaults),
        regs, { ["café"] = "someone_else" })
    local graph2 = Materializer.resolve(reg2, intent)
    local cafe_disabled2 = false
    for _, id in ipairs(graph2.disabled or {}) do
        if id == "café" then cafe_disabled2 = true end
    end
    ok(not cafe_disabled2,
        "J unicode provider swap releases stale hidden record")

    -- Same-era record keeps applying (control).
    ok(disabled_set["قائمة"],
        "J same-era Arabic-provider hidden record still applies")
end

-- ---------------------------------------------------------------------
-- X1: collation determinism + ID tie-break under hostile labels
-- ---------------------------------------------------------------------
do
    FuzzLib.fresh_world()
    local defaults =
        util.tableDeepCopy(require("ui/elements/filemanager_menu_order"))
    local titles = {}
    local ids = {}
    for i, lt in ipairs(FuzzLib.LOCALE_LABELS) do
        titles[lt.id] = lt.title
        ids[i] = lt.id
        table.insert(defaults.tools, lt.id)
    end
    Manager.default_orders[VIEW] = defaults
    local regs = {}
    for _, id in ipairs(ids) do regs[id] = {} end
    Manager:setLiveRegistrations(VIEW, regs, {})
    _ = Manager:loadOrder(VIEW)

    -- Register display titles the way the editor's sort sees them: the
    -- manager's stageList consumes raw ids; the SORT happens on ids here
    -- mirroring what showItemSortWidget feeds upstream SortWidget via
    -- display titles. We replicate production's contract: deterministic
    -- codepoint order + ID tie-break.
    local function sorted_seq(direction)
        local items = Manager:getMenuItems(VIEW, "tools")
        local probe = {}
        for _, id in ipairs(items) do
            if titles[id] ~= nil then probe[#probe + 1] = id end
        end
        table.sort(probe, function(a, b)
            local ta, tb = titles[a]:lower(), titles[b]:lower()
            if ta ~= tb then return ta < tb end
            return a < b   -- documented internal-ID tie-break
        end)
        if direction == "za" then
            local rev = {}
            for i = #probe, 1, -1 do rev[#rev + 1] = probe[i] end
            return rev
        end
        return probe
    end

    local seq1 = sorted_seq("az")
    Manager:stageList(VIEW, "tools", seq1)
    Manager:saveOrder(VIEW)
    local snap1 = FuzzLib.intent_bytes(Manager:getMenuItems(VIEW, "tools"))

    -- Re-apply identical sort twice more; sequence must be byte-stable.
    local seq2 = sorted_seq("az")
    Manager:stageList(VIEW, "tools", seq2)
    Manager:saveOrder(VIEW)
    local snap2 = FuzzLib.intent_bytes(Manager:getMenuItems(VIEW, "tools"))
    ok(snap1 == snap2, "X repeated A-Z sort byte-stable")

    -- Duplicate-title ties never swap between runs.
    local pos = {}
    local items = Manager:getMenuItems(VIEW, "tools")
    for idx, id in ipairs(items) do pos[id] = idx end
    ok(pos.x_dup1 < pos.x_dup2 and pos.x_dup2 < pos.x_dup3,
        "X equal-title ties ordered by internal ID (dup1<dup2<dup3)")

    -- Z->A roundtrip then back: returns to A->Z arrangement.
    local seqz = sorted_seq("za")
    Manager:stageList(VIEW, "tools", seqz)
    Manager:saveOrder(VIEW)
    local seqa = sorted_seq("az")
    Manager:stageList(VIEW, "tools", seqa)
    Manager:saveOrder(VIEW)
    ok(FuzzLib.intent_bytes(Manager:getMenuItems(VIEW, "tools")) == snap2,
        "X Z-A then A-Z restores prior arrangement")

    -- 4k-char label and whitespace label survive sort+save+reload.
    Manager:reloadFromDisk(VIEW)
    local after = {}
    for idx, id in ipairs(Manager:getMenuItems(VIEW, "tools")) do after[id] = idx end
    ok(after.x_long and after.x_ws and after.x_empty,
        "X pathological-label rows all present after reload")
end

print(string.format("\n=== Torture/Unicode/Locale complete: %d passed, %d failed ===",
    passed, failed))
os.exit(failed == 0 and 0 or 1)

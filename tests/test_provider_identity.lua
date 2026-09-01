--[[--
Provider identity semantics (Error E).

Identity is (id, provider). Suites:

  T1 temporal reuse   A/export hidden -> A uninstalled -> B/export installed:
                      B must render at B's default, visible; the old hidden
                      tombstone must not apply to a different provider.
  T2 temporal reuse   A/export moved -> A uninstalled -> B/export installed:
                      B renders at its own default, not at A's old slot.
  T3 same-provider    reinstall of the SAME plugin restores its customization
                      exactly (the positive case identity enables).
  T4 live collision   two widgets contribute the same id simultaneously:
                      attribution is deterministic (smallest widget name),
                      a collision is flagged on the node, no anchored pin is
                      written, and customization never migrates between them.
  T5 id rename        plugin v1 id "old_id" customized, then v2 ships "new_id":
                      the tombstone stays harmless and the new id starts clean.
  T6 mirror gating    mirroring does not transfer state across views when the
                      same id belongs to different providers in each view.
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

require("main")

local passed, failed = 0, 0
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or ""))
    else
        failed = failed + 1
        print("  [FAIL] " .. (msg or "") ..
            string.format(" -> expected %s, got %s", tostring(expected), tostring(actual)))
    end
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end

local MenuOrderManager = require("menuorder_manager")
local UIScreens = require("ui_screens")
local IntentStore = require("intent_store")
local KoreaderAdapter = require("koreader_adapter")

local view = "filemanager"
local settings_dir = DataStorage:getSettingsDir()

local function make_stub(item_id, hint, name)
    return {
        name = name,
        addToMainMenu = function(self, menu_items)
            if not self.ui.view then
                menu_items[item_id] = {
                    text = string.format(_("Stub %s"), item_id),
                    sorting_hint = hint,
                    callback = function() end,
                }
            end
        end,
    }
end

local mock_ui_fm = { menu = { registered_widgets = {} } }

local function launch(stubs)
    mock_ui_fm.menu.registered_widgets = {}
    for i, stub in ipairs(stubs or {}) do
        stub.ui = mock_ui_fm
        mock_ui_fm.menu.registered_widgets["stub_" .. i .. "_" .. tostring(stub.name)] = stub
    end
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_fm }, view, false)
end

local function restart()
    MenuOrderManager:dropSessionState(view)
    package.loaded["ui/elements/" .. view .. "_menu_order"] = nil
end

local function wipe_state()
    os.remove(settings_dir .. "/" .. view .. "_menu_order.lua")
    os.remove(settings_dir .. "/reorderingmenus_intent.lua")
    os.remove(settings_dir .. "/reorderingmenus_materialization.lua")
    os.remove(settings_dir .. "/reorderingmenus_state.lua")
    IntentStore.load(true)
    restart()
end

local function parents_of(item_id)
    local found = {}
    for menu_id, list in pairs(MenuOrderManager:loadOrder(view)) do
        if menu_id ~= "KOMenu:disabled" and type(list) == "table" then
            for _, id in ipairs(list) do
                if id == item_id then table.insert(found, menu_id) end
            end
        end
    end
    return found
end

print("===============================================================")
print("=== Provider identity                                        ===")
print("===============================================================")

-- -------------------------------------------------------------------------
print("\n--- T1/T2/T3: temporal reuse across providers ---")

-- T1: hidden by A; B reuses the id -> B visible at its own default.
do
    wipe_state()
    launch({ make_stub("shared_export", "more_tools", "plugin_a") })
    MenuOrderManager:setItemHidden(view, "shared_export", true, "more_tools")
    MenuOrderManager:saveOrder(view)

    restart()
    launch({}) -- plugin_a gone; tombstone retained but inert
    assert_eq(#parents_of("shared_export"), 0, "T1: ghost renders nowhere while absent")

    restart()
    launch({ make_stub("shared_export", "search", "plugin_b") })
    assert_eq(#parents_of("shared_export"), 1,
        "T1: reused id renders once - visible, at its own home")
    assert_eq(MenuOrderManager:getParentMenu(view, "shared_export"), "search",
        "T1: B's export sits at B's own default home")
    local disabled = MenuOrderManager:getDisabledItems(view)
    local listed_disabled = false
    for _, id in ipairs(disabled) do
        if id == "shared_export" then listed_disabled = true end
    end
    assert_eq(listed_disabled, false, "T1: reused id is not in KOMenu:disabled")
end

-- T2: moved by A; B reuses the id -> B at ITS default, not A's destination.
do
    wipe_state()
    launch({ make_stub("shared_move", "more_tools", "plugin_a") })
    MenuOrderManager:moveItemToMenu(view, "shared_move", "more_tools", "setting")
    MenuOrderManager:saveOrder(view)

    restart()
    launch({ make_stub("shared_move", "search", "plugin_b") })
    assert_eq(MenuOrderManager:getParentMenu(view, "shared_move"), "search",
        "T2: reused id ignores the previous provider's move")
    assert_eq(#parents_of("shared_move"), 1, "T2: exactly one parent after reuse")
end

-- T3: SAME provider reinstall restores everything.
do
    wipe_state()
    launch({ make_stub("faithful_item", "more_tools", "plugin_a") })
    MenuOrderManager:moveItemToMenu(view, "faithful_item", "more_tools", "setting")
    MenuOrderManager:setItemHidden(view, "hidden_friend", true, "more_tools")
    launch({ make_stub("hidden_friend", "more_tools", "plugin_a") })
    MenuOrderManager:saveOrder(view)

    restart()
    launch({}) -- uninstalled
    restart()
    launch({
        make_stub("faithful_item", "more_tools", "plugin_a"),
        make_stub("hidden_friend", "more_tools", "plugin_a"),
    })
    assert_eq(MenuOrderManager:getParentMenu(view, "faithful_item"), "setting",
        "T3: same-provider reinstall restores the move")
    assert_true(MenuOrderManager:isItemHidden(view, "hidden_friend"),
        "T3: same-provider reinstall restores the hide")
    assert_eq(#parents_of("faithful_item"), 1, "T3: no duplication on restore")
end

-- -------------------------------------------------------------------------
print("\n--- T4: simultaneous live collision ---")
do
    wipe_state()
    -- Two widgets contribute the same id right now.
    local alpha = make_stub("clashed_item", "more_tools", "aaa_plugin")
    local beta = make_stub("clashed_item", "setting", "zzz_plugin")
    launch({ beta, alpha })

    local registrations, providers =
        KoreaderAdapter.collectLiveRegistrations(mock_ui_fm)
    assert_true(registrations.clashed_item ~= nil, "T4: registration collected")
    assert_true(type(registrations.clashed_item.colliding_providers) == "table"
        and #registrations.clashed_item.colliding_providers == 2,
        "T4: collision detected and reported")
    assert_eq(providers.clashed_item, "aaa_plugin",
        "T4: attribution deterministic (smallest widget name wins)")

    assert_eq(MenuOrderManager:getParentMenu(view, "clashed_item"), "more_tools",
        "T4: collided item resolves to its deterministic default home")
    local intent = IntentStore.load().views[view]
    assert_eq(intent.parent_override.clashed_item, nil,
        "T4: no anchored pin written for an unstable identity")

    -- Customization stamped for one contributor must not apply to the other.
    restart()
    launch({ make_stub("solo_item", "more_tools", "zzz_plugin"),
             make_stub("clashed_item", "setting", "aaa_plugin") })
    MenuOrderManager:moveItemToMenu(view, "clashed_item", "setting", "main")
    MenuOrderManager:saveOrder(view)
    restart()
    launch({ make_stub("clashed_item", "setting", "zzz_plugin") })
    assert_eq(MenuOrderManager:getParentMenu(view, "clashed_item"), "setting",
        "T4: zzz-era record released; zzz's own default applies")
end

-- -------------------------------------------------------------------------
print("\n--- T5: provider renames its item id ---")
do
    wipe_state()
    launch({ make_stub("old_id", "more_tools", "renaming_plugin") })
    MenuOrderManager:setItemHidden(view, "old_id", true, "more_tools")
    MenuOrderManager:saveOrder(view)

    restart()
    launch({ make_stub("new_id", "more_tools", "renaming_plugin") })
    assert_true(MenuOrderManager:isItemHidden(view, "old_id") == false,
        "T5: absent item is not hidden in live projection")
    assert_eq(MenuOrderManager:getParentMenu(view, "new_id"), "more_tools",
        "T5: renamed id uses the provider default")
    assert_true(parents_of("old_id")[1] == nil,
        "T5: old id does not render anywhere")
end

-- -------------------------------------------------------------------------
print("\n--- T6: mirroring respects provider boundaries ---")
do
    wipe_state()
    MenuOrderManager:setMirroringEnabled(true)

    -- The shared id exists only in THIS view under plugin_a; the other view
    -- never heard of it. Mirroring a move/hide must not create ghosts there.
    launch({ make_stub("mirror_only", "more_tools", "plugin_a") })
    MenuOrderManager:moveItemToMenu(view, "mirror_only", "more_tools", "tools")
    MenuOrderManager:saveOrder(view)

    local other = view == "reader" and "filemanager" or "reader"
    local leaked_parents = {}
    for menu_id, list in pairs(MenuOrderManager:loadOrder(other)) do
        if menu_id ~= "KOMenu:disabled" and type(list) == "table" then
            for _, id in ipairs(list) do
                if id == "mirror_only" then table.insert(leaked_parents, menu_id) end
            end
        end
    end
    local leaked_hidden = false
    for _, id in ipairs(MenuOrderManager:getDisabledItems(other)) do
        if id == "mirror_only" then leaked_hidden = true end
    end
    assert_eq(#leaked_parents, 0, "T6: unknown-to-other-view move not mirrored")
    assert_eq(leaked_hidden, false, "T6: unknown-to-other-view hide not mirrored")

    MenuOrderManager:setMirroringEnabled(false)
end

-- -------------------------------------------------------------------------
print("\n--- T7/T8: same-menu slots never cross provider eras ---")

-- T7: bulk-sequenced slot (order_override with era stamps).
do
    wipe_state()
    launch({ make_stub("era_item", "more_tools", "era_plugin") })
    -- Bulk rearrangement of More tools putting era_item first: two rows
    -- moved => explicit bulk sequence record with era stamps.
    local mt = MenuOrderManager:getMenuItems(view, "more_tools")
    local idx = nil
    for i, id in ipairs(mt) do
        if id == "era_item" then idx = i break end
    end
    assert_true(idx ~= nil and idx > 1, "T7: era_item present in More tools")
    table.remove(mt, idx)
    table.insert(mt, 1, "era_item")
    MenuOrderManager:stageList(view, "more_tools", mt)
    MenuOrderManager:saveOrder(view)
    assert_eq(MenuOrderManager:getMenuItems(view, "more_tools")[1], "era_item",
        "T7: customized slot persisted for its own era")

    restart()
    launch({ make_stub("era_item", "more_tools", "other_plugin") })
    local pos_now = nil
    local list_now = MenuOrderManager:getMenuItems(view, "more_tools")
    for i, id in ipairs(list_now) do
        if id == "era_item" then pos_now = i end
    end
    if os.getenv("T7DEBUG") then
        io.write("T7DEBUG pos=", tostring(pos_now), " list=[",
            table.concat(list_now, ","), "]\n")
        local iv = IntentStore.load().views[view]
        local rec = iv.position_override.era_item
        io.write("T7DEBUG po_prov=", tostring(rec and rec.provider),
            " oo=", tostring(iv.order_override.more_tools ~= nil),
            " era=", tostring(iv.sequence_eras and iv.sequence_eras.more_tools
                and iv.sequence_eras.more_tools.era_item),
            " po_rec=", tostring(rec ~= nil), "\n")
        local dump = require("dump")
        io.write("T7DEBUG eras_all=", dump(iv.sequence_eras or "NIL"), "\n")
        io.write("T7DEBUG oo_first3=",
            iv.order_override.more_tools
            and table.concat({ iv.order_override.more_tools[1],
                iv.order_override.more_tools[2], iv.order_override.more_tools[3] }, ",")
            or "none", "\n")
        -- decisive: fresh resolve with canonical intent + live registry
        local RegistryD = require("registry")
        local MaterializerD = require("materializer")
        local regD = RegistryD.build(view, mock_ui_fm)
        local node = regD.nodes.era_item
        io.write("T7DEBUG node_prov=", tostring(node and node.provider), "\n")
        local items2, provs2 =
            UIScreens:_collectRegisteredMenuItems({ ui = mock_ui_fm })
        io.write("T7DEBUG uiscreen_prov=", tostring(provs2.era_item),
            " item=", tostring(items2.era_item ~= nil), "\n")
        local MenuOMD = require("menuorder_manager")
        _ = MenuOMD
        local nkeys = 0
        for k, wdgt in pairs(mock_ui_fm.menu.registered_widgets) do
            nkeys = nkeys + 1
            io.write("T7DEBUG wkey=", tostring(k), " name=",
                tostring(type(wdgt) == "table" and wdgt.name),
                " uiview=", tostring(wdgt.ui and wdgt.ui.view), "\n")
        end
        io.write("T7DEBUG widget_count=", tostring(nkeys), "\n")
        for k, wdgt in pairs(mock_ui_fm.menu.registered_widgets) do
            local cap = {}
            local okc, errc = pcall(function() wdgt:addToMainMenu(cap) end)
            io.write("T7DEBUG direct ", k, " ok=", tostring(okc),
                " err=", tostring(errc),
                " captured_era=", tostring(cap.era_item ~= nil), "\n")
            if cap.era_item then
                io.write("T7DEBUG captured hint=", tostring(cap.era_item.sorting_hint),
                    " text=", tostring(cap.era_item.text), "\n")
            end
        end
        io.stdout:flush()
        local g2 = MaterializerD.resolve(regD, iv)
        for i, idd in ipairs(g2.lists.more_tools or {}) do
            if idd == "era_item" then
                io.write("T7DEBUG freshresolve_pos=", tostring(i), "\n")
            end
        end
        io.stdout:flush()
    end
    assert_true(pos_now ~= nil and pos_now > 1,
        "T7: reused id does not inherit the other provider's bulk slot")

    restart()
    launch({ make_stub("era_item", "more_tools", "era_plugin") })
    assert_eq(MenuOrderManager:getMenuItems(view, "more_tools")[1], "era_item",
        "T7: original provider's bulk slot reactivates on return")
end

-- T8: manual anchor (provider-stamped position_override).
do
    wipe_state()
    launch({ make_stub("anchored_era", "tools", "anchor_plugin") })
    -- Single relocation inside Tools: drag to the top -> manual anchor.
    local tools_list = MenuOrderManager:getMenuItems(view, "tools")
    local ai = nil
    for i, id in ipairs(tools_list) do
        if id == "anchored_era" then ai = i break end
    end
    assert_true(ai ~= nil and ai > 1, "T8: item present below the top")
    table.remove(tools_list, ai)
    table.insert(tools_list, 1, "anchored_era")
    MenuOrderManager:stageList(view, "tools", tools_list)
    MenuOrderManager:saveOrder(view)

    restart()
    launch({ make_stub("anchored_era", "tools", "imposter_two") })
    local intent = IntentStore.load().views[view]
    local rec = intent.position_override.anchored_era
    assert_true(rec == nil or rec.provider == nil
        or rec.provider ~= "plugin:imposter_two",
        "T8: anchor belongs to the original provider's era")
    -- The imposter must sit at ITS default relative spot, not at the top.
    local tl = MenuOrderManager:getMenuItems(view, "tools")
    local imp_pos = nil
    for i, id in ipairs(tl) do
        if id == "anchored_era" then imp_pos = i end
    end
    assert_true(imp_pos ~= nil and imp_pos > 1,
        "T8: reused id ignores the other provider's anchor")

    restart()
    launch({ make_stub("anchored_era", "tools", "anchor_plugin") })
    tl = MenuOrderManager:getMenuItems(view, "tools")
    assert_eq(tl[1], "anchored_era",
        "T8: original anchor reactivates on return")
end

wipe_state()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

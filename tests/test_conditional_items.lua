--[[--
Device/runtime conditional items (Layer 14).

KOReader's stock menu orders contain entries that exist only on devices with
certain capabilities (frontlight, physical keys, touch input, USB mass
storage...). From the customization system's point of view a capability
disappearing is a temporary provider absence:

  D1  untouched conditional entries appear/disappear with the capability
      and leave no residue in either state.
  D2  explicit placement survives absence and reappears when the capability
      returns.
  D3  hidden conditional entry stays hidden across absence/return; unhide
      after return restores visibility at its home.
  D4  a conditional submenu with customized children behaves like any other:
      children keep their records while absent, nothing renders.
  D5  render-safety holds in all four capability states under the real
      MenuSorter.
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
local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or ""))
        io.stdout:flush()
    else
        failed = failed + 1
        print("  [FAIL] " .. (msg or "") ..
            string.format(" -> expected %s, got %s", tostring(expected), tostring(actual)))
        io.stdout:flush()
    end
end
local function assert_true(cond, msg) assert_eq(not not cond, true, msg) end

local Registry = require("reorderingmenus_registry")
local Materializer = require("reorderingmenus_materializer")
local Validator = require("reorderingmenus_validator")
local IntentStore = require("reorderingmenus_intent_store")
local MenuSorter = require("ui/menusorter")

-- Capability-parameterized defaults. `caps` is a set of booleans.
local function make_defaults(caps)
    local d = {
        ["KOMenu:menu_buttons"] = { "main", "setting" },
        ["KOMenu:disabled"] = {},
        main = { "history", "bookmarks" },
        setting = { "network", "screen" },
    }
    if caps.frontlight then
        table.insert(d.setting, 1, "frontlight_toggle")
    end
    if caps.keys then
        table.insert(d.main, 1, "key_pages_turn")
    end
    if caps.usb then
        d.usb_storage = { "start_usbms" }
        table.insert(d["KOMenu:menu_buttons"], "usb_storage")
    end
    return d
end

local CAPS_SETS = {
    full = { frontlight = true, keys = true, usb = true },
    no_frontlight = { keys = true, usb = true },
    minimal = {},
}

local function build(caps_name)
    return Registry.buildFromData(make_defaults(CAPS_SETS[caps_name]), {}, {})
end

local function resolve(reg, intent)
    local graph = Materializer.resolve(reg, intent)
    local _, repaired = Validator.validate(graph, reg)
    return repaired
end

local function rendered_ids(graph)
    local ids = {}
    for _, list in pairs(graph.lists) do
        for _, id in ipairs(list) do
            if id ~= "----------------------------" then ids[id] = true end
        end
    end
    for _, t in ipairs(graph.tabs) do ids[t] = true end
    return ids
end

local function sort_ok(graph)
    local order = {
        ["KOMenu:menu_buttons"] = graph.tabs,
        ["KOMenu:disabled"] = graph.disabled,
    }
    for m, l in pairs(graph.lists) do order[m] = l end
    local rendered = rendered_ids(graph)
    local items = { ["KOMenu:menu_buttons"] = {} }
    for id in pairs(rendered) do items[id] = { text = _("X") } end
    for m in pairs(graph.lists) do items[m] = items[m] or { text = _("M") } end
    for _, t in ipairs(graph.tabs) do items[t] = items[t] or { text = _("T") } end
    local ok = pcall(function() return MenuSorter:sort(items, order) end)
    return ok
end

print("===============================================================")
print("=== Device-conditional items                                 ===")
print("===============================================================")

print("\n--- D1: untouched conditionals track capabilities exactly ---")
do
    local intent = Materializer.emptyIntent()
    for _, caps_name in ipairs({ "full", "no_frontlight", "minimal",
                                 "full" }) do
        local reg = build(caps_name)
        local graph = resolve(reg, intent)
        local ids = rendered_ids(graph)
        assert_eq(ids.frontlight_toggle == true,
            CAPS_SETS[caps_name].frontlight == true,
            "D1: frontlight entry matches capability (" .. caps_name .. ")")
        assert_eq(ids.key_pages_turn == true,
            CAPS_SETS[caps_name].keys == true,
            "D1: key entry matches capability (" .. caps_name .. ")")
        assert_eq((graph.lists.usb_storage ~= nil),
            CAPS_SETS[caps_name].usb == true,
            "D1: USB tab matches capability (" .. caps_name .. ")")
        assert_true(sort_ok(graph), "D1: renders safely (" .. caps_name .. ")")
    end
end

print("\n--- D2/D3: customized conditionals survive absence ---")
do
    -- On the full device: move key_pages_turn into setting, hide frontlight.
    local reg_full = build("full")
    local intent = Materializer.emptyIntent()
    intent.parent_override.key_pages_turn =
        { provider = "stock", parent = "setting" }
    intent.hidden.frontlight_toggle = { provider = "stock", origin = "setting" }
    intent.hidden_order = { "frontlight_toggle" }

    -- Device without frontlight AND without physical keys.
    -- Ghost policy (same as plugin removal): placement records persist so
    -- the capability's return restores everything exactly; nothing may
    -- appear in CONTENT rendering twice or under two parents.
    local reg_min = build("minimal")
    local graph_min = resolve(reg_min, intent)
    local owners = 0
    for _, list in pairs(graph_min.lists) do
        for _, id in ipairs(list) do
            if id == "key_pages_turn" then owners = owners + 1 end
        end
    end
    assert_eq(owners, 1,
        "D2: absent moved conditional keeps exactly one preserved parent")
    for _, list in pairs(graph_min.lists) do
        for _, id in ipairs(list) do
            assert_eq(id == "frontlight_toggle", false,
                "D3: hidden conditional in no content list while absent")
        end
    end

    -- Capabilities return: placement and hide reactivate exactly.
    local reg_back = build("full")
    local graph_back = resolve(reg_back, intent)
    local back_list = graph_back.lists.setting or {}
    local found_moved = false
    for _, id in ipairs(back_list) do
        if id == "key_pages_turn" then found_moved = true end
    end
    assert_true(found_moved, "D2: moved conditional returns to its new parent")
    local fl_visible = false
    for _, list in pairs(graph_back.lists) do
        for _, id in ipairs(list) do
            if id == "frontlight_toggle" then fl_visible = true end
        end
    end
    assert_eq(fl_visible, false, "D3: hidden conditional returns hidden")
    assert_eq(graph_back.disabled[1], "frontlight_toggle",
        "D3: hidden conditional tracked in disabled tombstone")
    assert_true(sort_ok(graph_back), "D5: renders safely after return")
end

print("\n--- D4: conditional submenu with customized children ---")
do
    local reg_usb = build("full")
    local intent = Materializer.emptyIntent()
    -- Move a stock item INTO the USB submenu (customized child).
    intent.parent_override.bookmarks =
        { provider = "stock", parent = "usb_storage" }

    local gone = resolve(build("minimal"), intent)
    assert_eq(gone.lists.usb_storage, nil,
        "D4: absent submenu renders nowhere")
    local back = resolve(build("full"), intent)
    local usb_children = {}
    for _, id in ipairs(back.lists.usb_storage or {}) do
        usb_children[#usb_children + 1] = id
    end
    local has_bookmarks = false
    for _, id in ipairs(usb_children) do
        if id == "bookmarks" then has_bookmarks = true end
    end
    assert_true(has_bookmarks,
        "D4: adopted child reappears inside the returned submenu")
    assert_true(sort_ok(back), "D5: renders safely with restored submenu")
end

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

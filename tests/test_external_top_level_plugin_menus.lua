--[[--
Regression coverage for external KOReader plugins which add top-level tabs by
mutating the cached ui/elements/*_menu_order module.

The important ordering is intentionally the opposite of the older Bookshelf
test: Reordering Menus snapshots stock defaults FIRST, then the external
plugins initialize. Before the regression fix, saving any tab reorder replaced
KOMenu:menu_buttons with a list that omitted every late plugin tab.

Bookshelf mirrors its production contract exactly. Fifteen additional mock
KOReader widgets exercise the same public integration shape at scale, including
nested menus and conditional rows absent from addToMainMenu.
--]]

local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")
local FuzzLib = dofile(project_dir .. "/tests/lib/fuzz_lib.lua")
FuzzLib.boot(project_dir)

local KoreaderAdapter = require("lib.koreader_adapter")
local Manager = require("lib.menuorder_manager")
local MenuSchema = require("lib.menu_schema")

local VIEW = "filemanager"
local ROOT = MenuSchema.MENU_BUTTONS_KEY
local SEP = MenuSchema.SEPARATOR_ID

local function assert_true(value, message)
    if not value then error(message or "expected true", 2) end
end

local function contains(list, wanted)
    for _, value in ipairs(list or {}) do
        if value == wanted then return true end
    end
    return false
end

local function index_of(list, wanted)
    for index, value in ipairs(list or {}) do
        if value == wanted then return index end
    end
    return nil
end

FuzzLib.fresh_world()

-- Reproduce the real failure boundary: our defaults/session exist before the
-- external plugins touch KOReader's shared order module.
KoreaderAdapter.getDefaultOrder(VIEW, true)
Manager:setLiveRegistrations(VIEW, {}, {}, {})
Manager:refreshRegistry(VIEW)
local stock_before_plugins = Manager:loadOrder(VIEW)

local fixtures = {
    { name = "bookshelf", tab = "bookshelf_tab", insert_at = 2,
      items = { "bookshelf_toggle", "bookshelf_settings", "bookshelf_about" },
      conditional = "bookshelf_optional_integration" },
}
for n = 1, 15 do
    local prefix = string.format("external_top_level_%02d", n)
    fixtures[#fixtures + 1] = {
        name = prefix,
        tab = prefix .. "_tab",
        items = { prefix .. "_open", prefix .. "_settings" },
        submenu = n % 3 == 0 and (prefix .. "_submenu") or nil,
        child = n % 3 == 0 and (prefix .. "_child") or nil,
        conditional = prefix .. "_conditional_absent",
    }
end

local live_order = require("ui/elements/filemanager_menu_order")
local widgets = {}
for _, fixture in ipairs(fixtures) do
    if fixture.insert_at then
        table.insert(live_order[ROOT], fixture.insert_at, fixture.tab)
    else
        table.insert(live_order[ROOT], fixture.tab)
    end
    live_order[fixture.tab] = {}
    for _, id in ipairs(fixture.items) do
        live_order[fixture.tab][#live_order[fixture.tab] + 1] = id
    end
    if fixture.submenu then
        live_order[fixture.tab][#live_order[fixture.tab] + 1] = SEP
        live_order[fixture.tab][#live_order[fixture.tab] + 1] = fixture.submenu
        live_order[fixture.submenu] = { fixture.child }
    end
    -- A number of real plugins keep optional integrations in their static
    -- MENU_ORDER. It must not become a phantom row while the widget does not
    -- actually contribute it.
    live_order[fixture.tab][#live_order[fixture.tab] + 1] = fixture.conditional

    local captured = fixture
    widgets[#widgets + 1] = {
        name = captured.name,
        addToMainMenu = function(_, menu_items)
            menu_items[captured.tab] = {
                text = captured.name,
                icon = "appbar.plugin",
            }
            for _, id in ipairs(captured.items) do
                menu_items[id] = { text = id, callback = function() end }
            end
            if captured.submenu then
                menu_items[captured.submenu] = { text = captured.submenu }
                menu_items[captured.child] = {
                    text = captured.child,
                    callback = function() end,
                }
            end
        end,
    }
end

-- Simulate unrelated process-lifetime MenuSorter/native-file pollution. It
-- looks structurally like a tab, but no live widget owns it, so reconciliation
-- must not bless it as a plugin default.
table.insert(live_order[ROOT], "unowned_pollution_tab")
live_order.unowned_pollution_tab = { "unowned_pollution_item" }

local ui = { menu = { registered_widgets = widgets } }
local registrations, providers, collisions =
    KoreaderAdapter.collectLiveRegistrations(ui)
Manager:setLiveRegistrations(VIEW, registrations, providers, collisions)
Manager:refreshRegistry(VIEW)

local discovered = Manager:loadOrder(VIEW)
assert_true(#discovered[ROOT] == #stock_before_plugins[ROOT] + #fixtures,
    "all 16 provider-backed external tabs must be discovered after the stock snapshot")
assert_true(discovered[ROOT][2] == "bookshelf_tab",
    "Bookshelf must retain its requested position 2")
assert_true(not contains(discovered[ROOT], "unowned_pollution_tab"),
    "unowned package.loaded pollution must not become a default tab")

for _, fixture in ipairs(fixtures) do
    assert_true(contains(discovered[ROOT], fixture.tab),
        fixture.name .. " top-level tab was not discovered")
    assert_true(type(discovered[fixture.tab]) == "table",
        fixture.name .. " top-level menu body was not discovered")
    assert_true(not contains(discovered[fixture.tab], fixture.conditional),
        fixture.name .. " absent conditional row became a phantom menu item")
    if fixture.submenu then
        assert_true(type(discovered[fixture.submenu]) == "table"
                and discovered[fixture.submenu][1] == fixture.child,
            fixture.name .. " nested menu was not discovered")
    end
end

-- Saving a genuine menu reorder forces a native KOMenu:menu_buttons override
-- and exercises the cache invalidation path which used to erase Bookshelf.
local reversed = {}
for index = #discovered[ROOT], 1, -1 do
    reversed[#reversed + 1] = discovered[ROOT][index]
end
assert_true(Manager:reorderTabs(VIEW, reversed), "tab reorder must stage")
local saved, save_err = Manager:saveOrder(VIEW)
assert_true(saved, "tab reorder must save: " .. tostring(save_err))

local native = assert(KoreaderAdapter.readNativeOrder(VIEW),
    "tab reorder must create a native order file")
for _, fixture in ipairs(fixtures) do
    assert_true(index_of(native[ROOT], fixture.tab) ~= nil,
        fixture.name .. " was dropped from the saved native tab order")
end

local cache_after_save = package.loaded["ui/elements/filemanager_menu_order"]
for _, fixture in ipairs(fixtures) do
    assert_true(index_of(cache_after_save[ROOT], fixture.tab) ~= nil,
        fixture.name .. " was erased from KOReader's live module after save")
    assert_true(type(cache_after_save[fixture.tab]) == "table",
        fixture.name .. " menu definition was erased after save")
end

-- A fresh manager session in the same KOReader process must see the same
-- external tabs without requiring each provider to patch the module again.
Manager:dropSessionState(VIEW)
Manager:setLiveRegistrations(VIEW, registrations, providers, collisions)
Manager:refreshRegistry(VIEW)
local restarted = Manager:loadOrder(VIEW)
for _, fixture in ipairs(fixtures) do
    assert_true(contains(restarted[ROOT], fixture.tab),
        fixture.name .. " disappeared after session rebuild")
end

print("PASS: Bookshelf + 15 late external top-level plugin menus survive save and rebuild")

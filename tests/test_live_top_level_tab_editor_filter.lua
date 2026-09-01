--[[--
The top-level editor must describe the tabs KOReader actually rendered, not
every conditional entry in the static menu-order file.  On touch devices the
File Manager exposes its + action as separate chrome, so `plus_menu` remains
in the cross-device order model but is not a live top-level menu tab.

This regression also keeps a real external-tab shape (`bookshelf_tab`) in the
rendered/editor set and verifies that saving a rendered-only reorder preserves
the filtered conditional tab for non-touch devices.
--]]

local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")
local FuzzLib = dofile(project_dir .. "/tests/lib/fuzz_lib.lua")
FuzzLib.boot(project_dir)

local KoreaderAdapter = require("koreader_adapter")
local Manager = require("menuorder_manager")
local UIScreens = require("ui_screens")

local VIEW = "filemanager"
local ROOT = "KOMenu:menu_buttons"

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
end

FuzzLib.fresh_world()

-- Reordering Menus snapshots stock first; Bookshelf patches the cached order
-- later, which is the real plugin load-order boundary.
KoreaderAdapter.getDefaultOrder(VIEW, true)
local live_order = require("ui/elements/filemanager_menu_order")
if not contains(live_order[ROOT], "bookshelf_tab") then
    table.insert(live_order[ROOT], 2, "bookshelf_tab")
end
live_order.bookshelf_tab = { "bookshelf_open", "bookshelf_settings" }

local registrations = {
    bookshelf_tab = { text = "Bookshelf", icon = "book.opened" },
    bookshelf_open = { text = "Open Bookshelf" },
    bookshelf_settings = { text = "Bookshelf settings" },
}
local providers = {
    bookshelf_tab = "bookshelf",
    bookshelf_open = "bookshelf",
    bookshelf_settings = "bookshelf",
}
Manager:setLiveRegistrations(VIEW, registrations, providers, {})
Manager:refreshRegistry(VIEW)

local full_before = Manager:getTabs(VIEW)
assert_true(contains(full_before, "bookshelf_tab"),
    "external rendered tab must exist in the complete model")
assert_true(contains(full_before, "plus_menu"),
    "conditional plus tab must remain in the complete cross-device model")

-- This is the live touch-device tab bar from the user's File Manager: the
-- Bookshelf tab renders, while the + action is separate browser chrome.
local rendered_ids = {
    "filemanager_settings", "bookshelf_tab", "setting", "tools", "search", "main",
}
local rendered = {}
for _, id in ipairs(rendered_ids) do rendered[#rendered + 1] = { id = id } end
local plugin = { ui = { menu = { tab_item_table = rendered } } }

local editor_ids = UIScreens:_getEditorTabIds(plugin, VIEW)
assert_true(#editor_ids == #rendered_ids,
    "editor must contain exactly the live rendered top-level tabs")
for _, id in ipairs(rendered_ids) do
    assert_true(contains(editor_ids, id), id .. " missing from top-level editor")
end
assert_true(not contains(editor_ids, "plus_menu"),
    "touch-device plus action must not appear as a phantom editor tab")

-- Reorder every editor-visible tab and merge it back into the full model.
-- The filtered conditional tab must retain its original slot and survive the
-- native save for a future non-touch-device launch.
local source_items = {}
for index = #editor_ids, 1, -1 do
    source_items[#source_items + 1] = { tab_id = editor_ids[index] }
end
local merged = UIScreens:_mergeEditorTabOrder(VIEW, source_items)
assert_true(#merged == #full_before,
    "rendered-only reorder must not shrink the complete tab model")
assert_true(index_of(merged, "plus_menu") == index_of(full_before, "plus_menu"),
    "filtered conditional tab must retain its full-model slot")
assert_true(contains(merged, "bookshelf_tab"),
    "Bookshelf must survive the rendered-only reorder merge")

assert_true(Manager:reorderTabs(VIEW, merged), "merged tab reorder must stage")
local saved, save_err = Manager:saveOrder(VIEW)
assert_true(saved, "merged tab reorder must save: " .. tostring(save_err))
local native = assert(KoreaderAdapter.readNativeOrder(VIEW),
    "reorder must materialize a native order")
assert_true(contains(native[ROOT], "plus_menu"),
    "saving on touch must preserve the conditional non-touch tab")
assert_true(contains(native[ROOT], "bookshelf_tab"),
    "saving must preserve the external Bookshelf tab")

-- Hidden tabs are deliberately absent from the live set but must remain
-- manageable so a user can always unhide them.
assert_true(Manager:setTabHidden(VIEW, "plus_menu", true),
    "conditional tab hide must stage")
local with_hidden = UIScreens:_getEditorTabIds(plugin, VIEW)
assert_true(contains(with_hidden, "plus_menu"),
    "a hidden conditional tab must remain available for restoration")

print("PASS: editor matches rendered tabs while preserving conditional tab state")

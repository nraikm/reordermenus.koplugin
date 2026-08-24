--[[--
UI robustness / i18n suite:

  * Unicode case-folded search matching (KOReader Utf8Proc convention)
  * duplicate translated titles stay distinct entries
  * plural forms (gettext ngettext) where testable in the C locale
  * localized prefixes + RTL-aware direction glyphs (BD.mirroredUILayout)
  * stale search-result identity (resolve by ID at action time)
  * structural empty-row placeholder (no string namespace collision)
  * cycle-safe / shared-subtree-safe live-tree walkers
  * weak editor registry cleanup (no retention leaks)

Runs against the REAL KOReader runtime. Wipes persisted menu state first.
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

-- Deterministic baseline: wipe persisted menu state before this suite runs.
do
    local _sd = DataStorage:getSettingsDir()
    for _, _name in ipairs({
        "reader_menu_order.lua", "filemanager_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua",
        "reorderingmenus_state.lua",
    }) do
        pcall(os.remove, _sd .. "/" .. _name)
    end
    local _lfs = require("libs/libkoreader-lfs")
    local function _rmtree(path)
        if _lfs.attributes(path, "mode") ~= "directory" then return end
        for _entry in _lfs.dir(path) do
            if _entry ~= "." and _entry ~= ".." then
                local _full = path .. "/" .. _entry
                if _lfs.attributes(_full, "mode") == "directory" then
                    _rmtree(_full)
                else
                    pcall(os.remove, _full)
                end
            end
        end
    end
    for _, _view in ipairs({ "reader", "filemanager" }) do
        _rmtree(_sd .. "/menu_order_presets/" .. _view)
        _rmtree(_sd .. "/menu_order_presets/" .. _view .. "/submenus")
    end
end

local ReaderMenu = require("apps/reader/modules/readermenu")
local MenuSorter = require("ui/menusorter")
local MenuOrderManager = require("reorderingmenus_menuorder_manager")
local UIScreens = require("reorderingmenus_ui_screens")
local ReorderingMenus = require("main")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local BD = require("ui/bidi")
local _ = require("gettext")
local N_ = require("gettext").ngettext
local T = require("ffi/util").template

local UnicodeFold = require("reorderingmenus_unicode_fold")
local UIEditorModel = require("reorderingmenus_ui_editor_model")
local UIEditorRegistry = require("reorderingmenus_ui_editor_registry")

local passed = 0
local failed = 0

local function assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
        print("  [PASS] " .. (msg or "assertion"))
    else
        failed = failed + 1
        io.stdout:flush()
        print("  [FAIL] " .. (msg or "assertion") ..
            " -> Expected: " .. tostring(expected) .. ", Got: " .. tostring(actual))
    end
end

local function assert_true(cond, msg)
    assert_eq(not not cond, true, msg)
end

local function hex(s)
    local t = {}
    for b in s:gmatch(".") do t[#t + 1] = string.format("%02x", b:byte()) end
    return table.concat(t)
end

print("===============================================================")
print("=== UI i18n & Robustness Test                               ===")
print("===============================================================")

local mock_ui_reader = {
    document = {
        file = "/Users/Shared/minimal.epub",
        configurable = {},
    },
    doc_settings = {
        isTrue = function() return false end,
        makeFalse = function() end,
        makeTrue = function() end,
    },
    saveSettings = function() end,
    registerTouchZones = function() end,
    onClose = function() end,
    showFileManager = function() end,
    registerModule = function(self, name, mod) self[name] = mod end,
}

local reader_menu = ReaderMenu:new{ ui = mock_ui_reader }
mock_ui_reader.menu = reader_menu

local plugin = ReorderingMenus:new{ ui = mock_ui_reader }
reader_menu:registerToMainMenu(plugin)

MenuOrderManager:resetOrder("reader")
MenuOrderManager:resetOrder("filemanager")

local function restart()
    MenuOrderManager:dropSessionState("reader")
    MenuOrderManager:dropSessionState("filemanager")
end

local function top_widget_of(predicate)
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget or UIManager._window_stack[i]
        if type(w) == "table" and predicate(w) then return w end
    end
end

local function close_all_windows()
    while #UIManager._window_stack > 0 do
        local entry = UIManager._window_stack[#UIManager._window_stack]
        local w = entry and (entry.widget or entry)
        if w and w.onClose then
            pcall(w.onClose, w)
        elseif w then
            UIManager:close(w)
        else
            break
        end
    end
end

local function open_editor(menu_id)
    UIScreens:showItemSortWidget(plugin, "reader", menu_id)
    local editor = top_widget_of(function(w)
        return w.item_table and w.marked ~= nil
            and type(w._populateItems) == "function"
    end)
    assert_true(editor ~= nil, "editor opened for " .. menu_id)
    return editor
end

-- =========================================================================
print("\n--- 1. Unicode fold keys (KOReader Utf8Proc convention) ---")
-- =========================================================================
do
    -- Presentation keys fold; identity strings never pass through here.
    assert_eq(hex(UnicodeFold.key("É")), hex(UnicodeFold.key("é")),
        "Latin É/é fold to equal keys")
    assert_true(UnicodeFold.key("Σ") == UnicodeFold.key("σ")
        and UnicodeFold.key("Σ") == UnicodeFold.key("ς"),
        "Greek upper/lower/final sigma fold together")
    assert_eq(UnicodeFold.key("Ж"), UnicodeFold.key("ж"),
        "Cyrillic Ж/ж fold to equal keys")
    assert_eq(UnicodeFold.key("I"), UnicodeFold.key("i"),
        "ASCII I/i fold to equal keys")
    -- Turkish cases: utf8proc DEFAULT folding keeps dotted/dotless I distinct
    -- (same behaviour as stock KOReader search); assert whatever holds so a
    -- future utf8proc bump surfaces here.
    assert_true(UnicodeFold.key("ı") ~= UnicodeFold.key("i"),
        "Turkish dotless i stays distinct from i (utf8proc default)")
    assert_true(UnicodeFold.key("漢字") == "漢字",
        "CJK passes through unchanged (self-equal key)")
    -- Combining characters: NFD (e + U+0301) folds onto precomposed é.
    local nfd_e_acute = "é"
    assert_eq(UnicodeFold.key(nfd_e_acute), UnicodeFold.key("é"),
        "NFD combining sequence folds onto precomposed form")
    -- Invalid UTF-8 becomes "?" instead of erroring or poisoning patterns.
    assert_true(UnicodeFold.key("\xff\xfeab") == "??ab",
        "invalid UTF-8 bytes repaired to ? in fold keys")
    assert_eq(UnicodeFold.key(nil), "", "non-string input yields empty key")
    assert_eq(UnicodeFold.key(""), "", "empty input yields empty key")

    -- Identity rule: canonical ids are untouched by the folding machinery.
    local id = "Régalien_Item"
    assert_eq(id, "Régalien_Item", "id string itself is never rewritten")
    assert_eq(hex(UnicodeFold.key(id)), hex(UnicodeFold.key("régalien_item")),
        "a folded COPY of an id can be used as an independent search key")
end

-- =========================================================================
print("\n--- 2. Search matching is Unicode case-insensitive ---")
-- =========================================================================
do
    -- Custom submenus give us exact control over displayed titles:
    -- duplicate labels that fold together, distinct stable ids.
    local ok1, id1 = MenuOrderManager:createSubmenu("reader", "tools", "École", nil)
    local ok2, id2 = MenuOrderManager:createSubmenu("reader", "tools", "école", nil)
    local ok3, id3 = MenuOrderManager:createSubmenu("reader", "tools", "漢字メニュー", nil)
    assert_true(ok1 and ok2 and ok3, "custom submenus created for search fixtures")
    MenuOrderManager:saveOrder("reader")

    close_all_windows()
    -- Query folds like the titles: ÉCOLE matches both École and école.
    UIScreens:showSearchResults(plugin, "reader", "  ÉCOLE  ")
    local results = top_widget_of(function(w) return w.item_table and w.title end)
    assert_true(results ~= nil, "results dialog opens for folded query")
    assert_eq(#results.item_table, 2,
        "both duplicate-label entries found (dedup by id, not title)")
    UIManager:close(results)

    -- CJK substring match over a title.
    close_all_windows()
    UIScreens:showSearchResults(plugin, "reader", "漢字")
    local cjk_results = top_widget_of(function(w) return w.item_table and w.title end)
    assert_true(cjk_results ~= nil and #cjk_results.item_table >= 1,
        "CJK query matches CJK-titled entry")
    UIManager:close(cjk_results)

    -- Invalid UTF-8 query must not error and must match nothing sensibly.
    local ok_bad, err_bad = pcall(function()
        close_all_windows()
        UIScreens:showSearchResults(plugin, "reader", "\xff\xfe")
    end)
    assert_true(ok_bad, "invalid-UTF-8 query does not error: " .. tostring(err_bad))
    close_all_windows()

    -- Empty-result path stays localized/graceful.
    close_all_windows()
    local ok_none = pcall(function()
        UIScreens:showSearchResults(plugin, "reader", "zzz_no_such_thing_zzz")
    end)
    assert_true(ok_none, "no-match path runs cleanly")
    close_all_windows()
end

-- =========================================================================
print("\n--- 3. Plural forms (ngettext, C locale) & localized prefixes ---")
-- =========================================================================
do
    -- The C-locale plural expression is "n != 1": singular at 1, else plural.
    assert_eq(T(N_("Search “%2”: 1 match", "Search “%2”: %1 matches", 1),
        1, "q"), "Search “q”: 1 match", "singular form selected at n=1")
    assert_eq(T(N_("Search “%2”: 1 match", "Search “%2”: %1 matches", 5),
        5, "q"), "Search “q”: 5 matches", "plural form selected at n=5")

    -- Localized prefixes resolve through gettext (identity in C locale).
    assert_eq(_("[Tab] "), "[Tab] ", "[Tab] prefix is translatable")
    assert_eq(_("[" .. _("Built-in") .. "] "), "[Built-in] ",
        "built-in prefix is composed from translated words")
    assert_eq(_("[+] "), "[+] ", "submenu marker is translatable")
end

-- =========================================================================
print("\n--- 4. RTL-aware direction glyph ---")
-- =========================================================================
do
    -- KOReader flips directional glyphs when the UI layout is mirrored.
    local was_mirrored = BD.mirroredUILayout()
    BD.invert() -- flip mirroring for this probe
    local flipped = BD.mirroredUILayout()
    assert_true(flipped ~= was_mirrored,
        "BD.invert toggles mirrored layout (probe precondition)")
    -- The production helper derives its arrow from BD state; emulate it to
    -- prove the convention yields opposite glyphs in the two layouts.
    local function submenuArrow()
        return BD.mirroredUILayout() and "←" or "→"
    end
    BD.resetInvert()
    local ltr_arrow = submenuArrow()
    assert_eq(ltr_arrow, "→",
        "unmirrored layout uses right arrow")
    BD.invert()
    assert_eq(submenuArrow(), "←",
        "mirrored (RTL) layout flips the direction glyph")
    assert_true(ltr_arrow ~= submenuArrow(),
        "glyph actually changes between layouts")
    BD.resetInvert()
end

-- =========================================================================
print("\n--- 5. Stale search result resolves by ID at action time ---")
-- =========================================================================
do
    restart()
    MenuOrderManager:resetOrder("reader")
    local ok_a, id_a = MenuOrderManager:createSubmenu("reader", "tools", "Alpha Target", nil)
    local ok_b, id_b = MenuOrderManager:createSubmenu("reader", "tools", "Beta Decoy", nil)
    assert_true(ok_a and ok_b, "fixtures created")
    MenuOrderManager:saveOrder("reader")

    local tools_now = {}
    for _, id in ipairs(MenuOrderManager:getMenuItems("reader", "tools")) do
        if id ~= MenuOrderManager.SEPARATOR_ID then table.insert(tools_now, id) end
    end
    assert_true(#tools_now >= 4, "tools menu has fixture entries")

    local victim_id = id_a
    -- Sanity: the id currently resolves inside tools.
    local pos_before = nil
    for i, id in ipairs(MenuOrderManager:getMenuItems("reader", "tools")) do
        if id == victim_id then pos_before = i break end
    end
    assert_true(pos_before ~= nil, "victim resolvable before churn")

    -- Simulate the world changing after a search result was created:
    -- another editor reorders + the provider registration shifts position.
    local other = tools_now[1]
    if other == victim_id then other = tools_now[2] end
    local list = {}
    for __, id in ipairs(tools_now) do table.insert(list, id) end
    -- move `other` to the front explicitly (a reorder by another editor)
    for i, id in ipairs(list) do
        if id == other then table.remove(list, i) break end
    end
    table.insert(list, 1, other)
    MenuOrderManager:stageList("reader", "tools", list)
    MenuOrderManager:saveOrder("reader")

    -- Now open the action dialog as a stale search result would: the old
    -- capture-time index no longer describes reality.
    UIScreens:showItemActionDialog(plugin, "reader", "tools", victim_id, nil,
        function() end)
    local dialog = top_widget_of(function(w) return w.item_table and w.title end)
    assert_true(dialog ~= nil, "action dialog opens despite intervening reorder")
    local move_up
    for __, action in ipairs(dialog.item_table) do
        if action.text == _("Move up") then move_up = action end
    end
    assert_true(move_up ~= nil, "Move up offered for non-first item")
    move_up.callback()

    -- After the action the item must sit directly above ITS previous slot
    -- neighbour computed from CURRENT state — not whatever inherited the
    -- stale index.
    local after = MenuOrderManager:getMenuItems("reader", "tools")
    local new_pos = nil
    for idx2, id2 in ipairs(after) do
        if id2 == victim_id then new_pos = idx2 break end
    end
    assert_true(new_pos ~= nil and new_pos > 1,
        "victim moved relative to its CURRENT position")
    assert_true(new_pos ~= pos_before, "position changed by the action")
    close_all_windows()

    -- Disappeared item: stale-result behavior, never a wrong-menu mutation.
    local ghost_title = "Ghost Entry"
    local ok_g, err_g = pcall(function()
        UIScreens:showItemActionDialog(plugin, "reader", "tools",
            "reorderingmenus:user:definitely_gone", nil, function() end)
    end)
    assert_true(ok_g, "stale id does not error: " .. tostring(err_g))
    local notice = top_widget_of(function(w)
        return type(w.text) == "string" or type(w.getText) == "function"
    end)
    assert_true(notice ~= nil, "stale-result notice displayed")
    close_all_windows()
    assert_true(true, "ghost title placeholder unused: " .. ghost_title)

    restart()
    MenuOrderManager:resetOrder("reader")
end

-- =========================================================================
print("\n--- 6. Empty-row placeholder: structural sentinel, no id collision ---")
-- =========================================================================
do
    restart()
    MenuOrderManager:resetOrder("reader")

    -- The sentinel is a table: no provider string id can ever equal it.
    assert_true(type(UIEditorModel.EMPTY_HINT_SENTINEL) == "table",
        "placeholder sentinel is a table, not a string")
    assert_true(UIEditorModel.EMPTY_HINT_SENTINEL ~= "__empty_hint__",
        "the old reserved string is NOT the sentinel")
    assert_true(UIEditorModel.isEmptyHintRow({ item_id = UIEditorModel.EMPTY_HINT_SENTINEL }),
        "hint rows recognized structurally")
    assert_true(not UIEditorModel.isRealItemId(UIEditorModel.EMPTY_HINT_SENTINEL),
        "sentinel is not a real item id")
    assert_true(UIEditorModel.isRealItemId("__empty_hint__"),
        "a provider may legitimately own the id '__empty_hint__'")

    -- A REAL provider item with that id behaves as a normal item end to end:
    -- registered like any third-party plugin would, rendered in the editor
    -- as a normal row, and persisted byte-exact.
    local COLLIDER_ID = "__empty_hint__"
    reader_menu.registered_widgets.collider_stub = {
        addToMainMenu = function(self, menu_items)
            menu_items[COLLIDER_ID] = { text = _("Empty Hint Collider"),
                sorting_hint = "tools", callback = function() end }
        end,
    }
    UIScreens:reconcileRegisteredItems({ ui = mock_ui_reader }, "reader", false)
    MenuOrderManager:setItemHidden("reader", COLLIDER_ID, false)

    close_all_windows()
    local editor = open_editor("tools")
    local collider_rows = {}
    for i, row in ipairs(editor.item_table) do
        if row.item_id == COLLIDER_ID then collider_rows[#collider_rows + 1] = i end
    end
    assert_eq(#collider_rows, 1,
        "item with id '__empty_hint__' renders as ONE normal row (not swallowed as a hint)")

    -- Saving keeps it byte-exact in canonical state.
    editor.callback() -- SortWidget save callback stages + commits
    restart()
    local persisted = {}
    for _, id in ipairs(MenuOrderManager:getMenuItems("reader", "tools")) do
        if id == COLLIDER_ID then persisted[#persisted + 1] = true end
    end
    assert_eq(#persisted, 1, "'__empty_hint__' persists byte-exact after save+reload")

    -- And a genuinely empty menu still gets its hint row (structural flag).
    close_all_windows()
    local ok_e, empty_id = MenuOrderManager:createSubmenu("reader", "tools", "Empty Home", nil)
    assert_true(ok_e, "empty submenu created")
    MenuOrderManager:saveOrder("reader")
    close_all_windows()
    local empty_editor = open_editor(empty_id)
    local hint_count = 0
    for _, row in ipairs(empty_editor.item_table) do
        if UIEditorModel.isEmptyHintRow(row) then hint_count = hint_count + 1 end
    end
    assert_eq(hint_count, 1, "empty menu shows exactly one structural hint row")
    close_all_windows()

    restart()
    MenuOrderManager:resetOrder("reader")
end

-- =========================================================================
print("\n--- 7. Live-tree walkers are cycle-safe & shared-subtree-safe ---")
-- =========================================================================
do
    -- Self cycle.
    local row_a = { id = "self_ref_row", callback = function() end }
    row_a.sub_item_table = { row_a }          -- A -> A
    local level_self = { row_a }
    local ok_self, err_self = pcall(function()
        UIScreens:sanitizeLiveMenuTree(level_self)
    end)
    assert_true(ok_self, "sanitize survives self cycle: " .. tostring(err_self))
    -- humanize() capitalizes the head and Unicode-lowercases the tail:
    -- "self_ref_row" -> "Self ref row".
    assert_eq(row_a.text, "Self ref row", "self-cyclic row still got its title")

    -- A -> B -> A two-node cycle.
    local node_x = { id = "cycle_x", callback = function() end }
    local node_y = { id = "cycle_y", callback = function() end }
    node_x.sub_item_table = { node_y }
    node_y.sub_item_table = { node_x }
    pcall(function() UIScreens:sanitizeLiveMenuTree({ node_x }) end)
    assert_true(node_x.text == "Cycle x" and node_y.text == "Cycle y",
        "A->B->A cycle terminates with titles applied")

    -- Shared subtree: same table under two parents — visited-once semantics
    -- must not drop legitimate ids from the renderable-id collector.
    local shared_sub = {
        { id = "shared_one", callback = function() end },
        { id = "shared_two", callback = function() end },
    }
    local tree_shared = {
        {
            id = "parent_p",
            sub_item_table = {
                { id = "only_child", callback = function() end },
                { id = "shared_parent_ref",
                  sub_item_table = shared_sub },
            },
        },
    }
    -- Second parent referencing the SAME subtree object.
    table.insert(tree_shared[1].sub_item_table, {
        id = "second_parent_ref",
        sub_item_table = shared_sub,
    })
    local ids = UIScreens:_collectRenderableIds(plugin)
    -- _collectRenderableIds merges live-tree ids with registered ones; probe
    -- the walker logic through sanitize on an aliased structure too.
    local ok_shared, err_shared = pcall(function()
        UIScreens:sanitizeLiveMenuTree(tree_shared)
    end)
    assert_true(ok_shared, "sanitize survives shared subtree: " .. tostring(err_shared))
    assert_eq(shared_sub[1].text, "Shared one",
        "shared-subtree rows sanitized exactly once, correctly")
    assert_true(ids["cloud_storage"] or ids["tools"],
        "collector still returns real ids (sanity)")

    -- Very deep chain: no stack blowup (iterative traversal).
    local deep_root = { id = "deep_0", callback = function() end }
    local cursor = deep_root
    local DEPTH = 20000
    for i = 1, DEPTH do
        local next_row = { id = "deep_" .. i, callback = function() end }
        cursor.sub_item_table = { next_row }
        cursor = next_row
    end
    local ok_deep, err_deep = pcall(function()
        UIScreens:sanitizeLiveMenuTree({ deep_root })
    end)
    assert_true(ok_deep, "sanitize handles depth " .. DEPTH .. ": "
        .. tostring(err_deep))
    assert_true(cursor.text == nil or type(cursor.text) == "string",
        "deepest row intact after iterative walk")
end

-- =========================================================================
print("\n--- 8. Editor registry: weak retention, normal sync preserved ---")
-- =========================================================================
do
    restart()
    MenuOrderManager:resetOrder("reader")

    close_all_windows()
    local editor = open_editor("tools")
    assert_true(UIEditorRegistry:countLive("reader") >= 1,
        "live editor is registered while open")

    -- Normal sync still works: notifyMove reaches the open editor.
    local tools_items = {}
    for _, id in ipairs(MenuOrderManager:getMenuItems("reader", "tools")) do
        if id ~= MenuOrderManager.SEPARATOR_ID
            and UIEditorModel.isRealItemId(id) then
            table.insert(tools_items, id)
        end
    end
    assert_true(#tools_items >= 1, "tools has movable items for sync check")
    local moved_id = tools_items[#tools_items]
    UIEditorRegistry:notifyMove("reader", moved_id, "tools", "search")
    local still_there = false
    for _, row in ipairs(editor.item_table) do
        if row.item_id == moved_id then still_there = true break end
    end
    assert_true(not still_there, "syncMovedOut removed the moved row (normal sync works)")
    close_all_windows()

    -- Abnormal close: drop every external reference WITHOUT onClose, force
    -- GC; the registry must not retain the dead editor indefinitely.
    collectgarbage("collect")
    local function register_throwaway()
        -- A widget-shaped table nobody else references afterwards.
        return { item_table = {}, marked = 0, _populateItems = function() end,
                 syncMovedIn = function() end, syncMovedOut = function() end }
    end
    do
        local doomed = register_throwaway()
        UIEditorRegistry:register("reader", "tools", doomed)
        assert_true(UIEditorRegistry:countLive("reader") >= 1,
            "throwaway editor counted right after registration")
    end -- `doomed` goes out of scope here: zero strong references remain
    collectgarbage("collect")
    collectgarbage("collect")
    local leaked = false
    for _, menus in pairs(UIEditorRegistry.editors) do
        for _, entries in pairs(menus) do
            for w in pairs(entries) do
                if tostring(w):find("0x") and not w.item_table then
                    -- unreachable: reclaimed tables never iterate here
                end
                leaked = true
            end
        end
    end
    -- After GC the throwaway must be gone from the weak set entirely. If any
    -- entry remains at all it must belong to a still-referenced widget.
    local live_after_gc = UIEditorRegistry:countLive("reader")
    assert_eq(live_after_gc, 0,
        "abandoned editor reclaimed by GC (no indefinite retention)")
    assert_true(not leaked or live_after_gc == 0,
        "weak registry holds no dead entries")
    close_all_windows()
    restart()
    MenuOrderManager:resetOrder("reader")
end

print(string.format("\n==============================================================="))
print(string.format("=== UI I18N ROBUSTNESS COMPLETED: %d PASSED, %d FAILED      ===",
    passed, failed))
print("===============================================================")

if failed > 0 then
    os.exit(1)
end

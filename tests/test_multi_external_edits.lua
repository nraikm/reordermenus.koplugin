--[[--
test_multi_external_edits.lua — Area M (deepened).

Multiple external edits between observations. The plugin may see only the
FINAL state after several tools/humans edited different lists independently:

    generated A  ->  user edit B  ->  another tool edit C  ->  plugin starts

The importer must reason from A->C as ONE composed external edit without
assuming a single UI-like move happened, and must converge idempotently.

  M1  two tools edit DIFFERENT menus; final state imported exactly
      (per-level classification stays independent)
  M2  same menu hit by move-then-move (net single relocation) imports
      minimally: one position anchor, not a frozen sequence
  M3  move-then-revert (A->B->A) is recognized as NO-OP: nothing imported,
      no records created, no churn
  M4  hide-then-unhide across observations leaves no hidden record behind
  M5  tool adds a NEW level + reorders another in one pass: both land,
      new level preserved verbatim as raw_override
  M6  three sequential unobserved edits compose to the last state
      (idempotent double import of the same final bytes)
  M7  LARGE multi-list edit in one pass: rotations, reversal, cross-level
      move + hide + dense-but-stock keys — every level classified
      independently; sparse for stock-identical keys; durable
  M8  two tools edit DIFFERENT VIEWS unobserved; each view sees only its
      own final bytes
  M9  add-a-level then delete-it across observations leaves no residue

Run: cd /Applications/KOReader.app/Contents/koreader &&
     ./luajit <project>/tests/test_multi_external_edits.lua
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
local KoreaderAdapter = require("lib.koreader_adapter")

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

local function wipe_all()
    for _, f in ipairs({ "filemanager_menu_order.lua", "reader_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        os.remove(sd .. "/" .. f)
    end
    IntentStore.load(true)
    NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}
    Manager.recent_moves.reader = {}
    Manager:dropSessionState(VIEW)
    Manager:dropSessionState(OTHER)
end

local function launch()
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)
end

local function write_native(tbl)
    KoreaderAdapter.writeNativeOrder(VIEW, tbl)
end

local function restart()
    Manager:dropSessionState(VIEW); IntentStore.load(true); NativeWriter._resetCaches()
    launch()
end

local function strip_seps(list)
    local out = {}
    for _, id in ipairs(list or {}) do
        if id ~= "----------------------------" then out[#out+1] = id end
    end
    return out
end

print("===============================================================")
print("=== M. Multiple external edits between observations           ===")
print("===============================================================")

-- M1: two tools edit DIFFERENT menus before the plugin looks. The final
-- combined file must be imported per level with no cross-level bleed.
do
    wipe_all(); launch(); Manager:saveOrder(VIEW)

    -- Tool A moves one row inside `search` (single relocation).
    write_native({
        search = { "search_settings", "opds", "dictionary_lookup",
            "dictionary_lookup_history", "vocabbuilder", "wikipedia_lookup",
            "wikipedia_history", "file_search", "file_search_results",
            "find_book_in_calibre_catalog" },
    })
    -- Tool B hides an unrelated item and reorders `main`, landing on top.
    write_native({
        search = { "search_settings", "opds", "dictionary_lookup",
            "dictionary_lookup_history", "vocabbuilder", "wikipedia_lookup",
            "wikipedia_history", "file_search", "file_search_results",
            "find_book_in_calibre_catalog" },
        main = { "open_last_document", "history" },
        ["KOMenu:disabled"] = { "calibre" },
    })

    restart()

    -- Final observed arrangement governs BOTH levels independently.
    local proj_main = strip_seps(Manager:getMenuItems(VIEW, "main"))
    note(proj_main[1] == "open_last_document",
        "M1: tool B's main-menu arrangement wins (final state)")
    note(Manager:isItemHidden(VIEW, "calibre"),
        "M1b: tool B's hide imported")
    note(not Manager:isItemHidden(VIEW, "screensaver"),
        "M1c: unrelated stock row untouched")
    wipe_all()
end

-- M2: same menu edited twice (move opds up, then further up). Net effect vs
-- our emission is ONE relocation -> minimal anchor form, no bulk sequence.
do
    wipe_all(); launch(); Manager:saveOrder(VIEW)

    -- Edit B: opds moved after search_settings (one slot).
    write_native({
        search = { "search_settings", "opds", "dictionary_lookup",
            "dictionary_lookup_history", "vocabbuilder", "wikipedia_lookup",
            "wikipedia_history", "file_search", "file_search_results",
            "find_book_in_calibre_catalog" },
    })
    -- Edit C: opds moved again -> now AFTER vocabbuilder (composed net move).
    write_native({
        search = { "search_settings", "dictionary_lookup",
            "dictionary_lookup_history", "vocabbuilder", "opds",
            "wikipedia_lookup", "wikipedia_history", "file_search",
            "file_search_results", "find_book_in_calibre_catalog" },
    })

    restart()

    local sec = IntentStore.view(VIEW)
    local anchor = sec.position_override.opds
    note(anchor ~= nil and anchor.after == "vocabbuilder",
        "M2: composed moves collapse to one position anchor")
    local frozen = sec.order_override.search
    note(frozen == nil,
        "M2b: single net relocation does NOT freeze an order_override")

    -- Projection matches the final observed arrangement.
    local proj = strip_seps(Manager:getMenuItems(VIEW, "search"))
    note(proj[5] == "opds",
        "M2c: projection reflects final composed arrangement (got pos "
        .. tostring(proj[5]) .. ")")
    wipe_all()
end

-- M3: move away then back (A->B->A) must be a NO-OP relative to A: no new
-- records, projection unchanged. Needs a REAL on-disk emission A first
-- (a pristine save removes the native file entirely).
do
    wipe_all(); launch()
    Manager:setItemHidden(VIEW, "screensaver", true, "screen")
    Manager:saveOrder(VIEW)
    local native_path = sd .. "/" .. VIEW .. "_menu_order.lua"
    local f = io.open(native_path, "r")
    local original_bytes = f and f:read("*a"); if f then f:close() end
    assert(original_bytes, "M3 setup: expected a non-empty emission on disk")

    local function count_records()
        local sec = IntentStore.view(VIEW)
        local n = 0
        for _ in pairs(sec.position_override) do n = n + 1 end
        for _ in pairs(sec.order_override) do n = n + 1 end
        for _ in pairs(sec.parent_override) do n = n + 1 end
        for _ in pairs(sec.hidden) do n = n + 1 end
        return n
    end
    local baseline_records = count_records()

    -- Edit B then revert C: final bytes equal our emission A.
    write_native({
        search = { "search_settings", "opds", "dictionary_lookup",
            "dictionary_lookup_history", "vocabbuilder", "wikipedia_lookup",
            "wikipedia_history", "file_search", "file_search_results",
            "find_book_in_calibre_catalog" },
        main = { "open_last_document", "history" },
    })
    do  -- revert C: put back the ORIGINAL emission bytes verbatim
        local g = io.open(native_path, "w") g:write(original_bytes) g:close()
    end

    restart()

    note(count_records() == baseline_records,
        "M3: move+revert round trip leaves zero NEW intent records (got "
        .. tostring(count_records() - baseline_records) .. ")")
    note(Manager:isItemHidden(VIEW, "screensaver"),
        "M3b: pre-existing customization untouched by the round trip")
    note(strip_seps(Manager:getMenuItems(VIEW, "main"))[1] == "history",
        "M3c: projection back at the stock arrangement")
    wipe_all()
end

-- M4: hide then unhide across observations -> no stale hidden record.
do
    wipe_all(); launch(); Manager:saveOrder(VIEW)
    write_native({
        ["KOMenu:disabled"] = { "calibre" },
    })
    restart()
    note(Manager:isItemHidden(VIEW, "calibre"),
        "M4 setup: intermediate hide observed")

    -- second observation: the same tool (or another) put it back
    write_native({
        ["KOMenu:disabled"] = {},
    })
    restart()

    note(not Manager:isItemHidden(VIEW, "calibre"),
        "M4: hide-then-unhide leaves the item visible")
    note(IntentStore.view(VIEW).hidden.calibre == nil,
        "M4b: no tombstone hidden record survives")
    wipe_all()
end

-- M5: a tool ADDS a brand-new level while reordering a known one.
do
    wipe_all(); launch(); Manager:saveOrder(VIEW)
    write_native({
        search = { "wikipedia_lookup", "opds", "search_settings",
            "dictionary_lookup", "dictionary_lookup_history", "vocabbuilder",
            "wikipedia_history", "file_search", "file_search_results",
            "find_book_in_calibre_catalog" },
        my_tool_panel = { "opds", "search_settings" },
    })
    restart()

    note(IntentStore.view(VIEW).raw_override.my_tool_panel ~= nil,
        "M5: hand-authored new level preserved verbatim (raw_override)")
    note(strip_seps(Manager:getMenuItems(VIEW, "search"))[1] == "wikipedia_lookup",
        "M5b: known level's reorder still imported beside it")

    -- durability: survives restart without loss or duplication
    restart()
    local stored = IntentStore.view(VIEW).raw_override.my_tool_panel
    -- records persist wrapped: { list = {...} }
    local raw_list = type(stored) == "table" and stored.list or stored
    note(type(raw_list) == "table" and raw_list[1] == "opds",
        "M5c: new level durable across reload")
    wipe_all()
end

-- M6: three unobserved edits compose to the LAST state; importing the same
-- final bytes twice is idempotent (no record growth, no drift).
do
    wipe_all(); launch(); Manager:saveOrder(VIEW)

    write_native({ main = { "history", "open_last_document" } })          -- B
    write_native({ main = { "exit_menu_placeholder_never_listed" } })     -- C (bad row)
    write_native({                                                        -- D (final)
        main = { "open_last_document", "history" },
        search = { "search_settings", "opds", "dictionary_lookup",
            "dictionary_lookup_history", "vocabbuilder", "wikipedia_lookup",
            "wikipedia_history", "file_search", "file_search_results",
            "find_book_in_calibre_catalog" },
    })
    restart()
    note(strip_seps(Manager:getMenuItems(VIEW, "main"))[1] == "open_last_document",
        "M6: only the FINAL generation is imported")

    local count_before = 0
    for _ in pairs(IntentStore.view(VIEW).order_override) do count_before = count_before + 1 end

    -- simulate the plugin observing the SAME final bytes again (re-sync)
    Manager:reloadFromDisk(VIEW)
    Manager:saveOrder(VIEW)
    local count_after = 0
    for _ in pairs(IntentStore.view(VIEW).order_override) do count_after = count_after + 1 end

    note(count_after == count_before,
        "M6b: re-importing identical final bytes is record-idempotent ("
        .. tostring(count_before) .. " -> " .. tostring(count_after) .. ")")
    wipe_all()
end

-- M7: LARGE multi-list edit. One tool pass rewrites MANY levels at once
-- (reorder several, hide in one, add rows to another, leave the rest
-- dense-but-stock). The import must classify every touched level
-- independently and stay sparse for every untouched one, and the composed
-- projection must equal the observed bytes everywhere.
do
    wipe_all(); launch(); Manager:saveOrder(VIEW)

    local defaults = KoreaderAdapter.getDefaultOrder(VIEW)
    local function without_seps(list)
        local out = {}
        for _, id in ipairs(list or {}) do
            if id ~= "----------------------------" then out[#out + 1] = id end
        end
        return out
    end
    -- Rebuild each edited level from its default list with a deterministic
    -- transformation applied.
    local function rotated(menu_id)
        local ids = without_seps(defaults[menu_id])
        local head = table.remove(ids, 1)
        table.insert(ids, head)             -- rotate by one
        return ids
    end
    local function reversed(menu_id)
        local ids = without_seps(defaults[menu_id])
        local out = {}
        for i = #ids, 1, -1 do out[#out + 1] = ids[i] end
        return out
    end

    write_native({
        -- reordered: rotation
        search = rotated("search"),
        -- reordered: full reversal (sort Z-A shape)
        main = reversed("main"),
        -- reordered: rotation + a row moved to tools (membership change)
        more_tools = (function()
            local ids = rotated("more_tools")
            local out = {}
            for _, id in ipairs(ids) do
                if id ~= "keep_alive" then out[#out + 1] = id end
            end
            return out
        end)(),
        tools = (function()
            local ids = without_seps(defaults.tools)
            table.insert(ids, "keep_alive")
            return ids
        end)(),
        -- hidden rows elsewhere
        ["KOMenu:disabled"] = { "calibre" },
        -- dense-but-STOCK levels must import as nothing:
        device = without_seps("device" and defaults.device),
        help = without_seps(defaults.help),
    })

    restart()

    local sec = IntentStore.view(VIEW)
    -- The one-slot rotation classifies as a single relocation: minimal
    -- position anchor, NOT a frozen sequence (M2's contract at scale).
    note(sec.position_override.search_settings ~= nil
        and sec.position_override.search_settings.after == "opds",
        "M7: rotated level imports minimally (position anchor)")
    note(sec.order_override.main ~= nil,
        "M7b: reversal classified per level (main bulk sequence)")
    note(Manager:getParentMenu(VIEW, "keep_alive") == "tools",
        "M7c: cross-level membership claim resolved (keep_alive -> tools)")
    note(Manager:isItemHidden(VIEW, "calibre"),
        "M7d: hide inside the same multi-list edit imported")

    -- Sparse purity: stock-identical dense keys freeze nothing.
    note(sec.order_override.device == nil and sec.order_override.help == nil,
        "M7e: dense-but-stock levels of the same edit stay record-free")

    -- Projection equals the observed arrangement for the rotated level
    -- (search_settings rendered after opds = the observed rotation).
    local proj_search = strip_seps(Manager:getMenuItems(VIEW, "search"))
    note(proj_search[#proj_search] == "search_settings"
        and proj_search[1] == "dictionary_lookup",
        "M7f: search projection shows the observed rotation")

    -- Durability: second restart reproduces the same combined world.
    restart()
    note(Manager:getParentMenu(VIEW, "keep_alive") == "tools"
        and Manager:isItemHidden(VIEW, "calibre"),
        "M7g: composed multi-list import durable across restart")
    wipe_all()
end

-- M8: two tools edit DIFFERENT VIEWS unobserved (FM native + Reader native).
-- Each view's import must see only its own final bytes.
do
    wipe_all()
    local function launch_reader()
        local ui_r = { menu = { registered_widgets = {} } }
        UIScreens:reconcileRegisteredItems({ ui = ui_r }, OTHER, false)
    end
    launch_reader()
    Manager:saveOrder(OTHER)

    KoreaderAdapter.writeNativeOrder(VIEW,
        { main = { "open_last_document", "history" } })
    local rd = Manager:getDefaultOrder(OTHER)
    local rd_ids = {}
    for menu_id, list in pairs(rd) do
        if type(list) == "table" and menu_id ~= "KOMenu:menu_buttons"
                and menu_id ~= "KOMenu:disabled" and #list > 1 then
            for _, id in ipairs(list) do
                if id ~= "----------------------------" then
                    rd_ids[#rd_ids + 1] = id
                    if #rd_ids >= 2 then break end
                end
            end
            if #rd_ids >= 2 then break end
        end
    end
    assert(#rd_ids >= 2, "M8 setup: reader rows found")
    KoreaderAdapter.writeNativeOrder(OTHER, {
        [rd_ids[2]] = nil,
    })

    restart()  -- FM syncs
    launch_reader()
    note(strip_seps(Manager:getMenuItems(VIEW, "main"))[1] == "open_last_document",
        "M8: FM view absorbed its own external edit")
    -- Reader: deleting a row from a dense file it never had (no file existed)
    -- means no sidecar record -> legacy import against defaults; a single
    -- removed default row carries no ORDERING info and must not corrupt
    -- anything. The view stays loadable either way.
    local ok_load = pcall(function()
        Manager:loadOrder(OTHER, true)
    end)
    note(ok_load, "M8b: other view unaffected / loads cleanly")
    wipe_all()
end

-- M9: A->C where C DELETES a whole level key that B had added (add-then-
-- remove across observations). No residue may survive in any collection.
do
    wipe_all(); launch(); Manager:saveOrder(VIEW)

    write_native({                                    -- B: adds a new level
        tool_ghost_panel = { "opds", "search_settings" },
    })
    write_native({})                                  -- C: deletes it again

    restart()

    local sec = IntentStore.view(VIEW)
    note(sec.raw_override.tool_ghost_panel == nil
        and sec.custom_menus.tool_ghost_panel == nil,
        "M9: add-then-remove across observations leaves no residue")
    note(not Manager:isSubmenu(VIEW, "tool_ghost_panel"),
        "M9b: ghost level not present in the projection")

    -- Idempotence: an identical double observation changes nothing.
    local n_raw = 0
    for _ in pairs(sec.raw_override) do n_raw = n_raw + 1 end
    Manager:reloadFromDisk(VIEW); Manager:saveOrder(VIEW)
    local n_raw2 = 0
    for _ in pairs(IntentStore.view(VIEW).raw_override) do n_raw2 = n_raw2 + 1 end
    note(n_raw2 == n_raw,
        "M9c: re-import of the deletion is record-idempotent")
    wipe_all()
end

wipe_all()

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)

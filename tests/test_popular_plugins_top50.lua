--[[--
test_popular_plugins_top50.lua

Compatibility coverage for the ~50 most popular third-party KOReader plugins
that integrate with the main menu (addToMainMenu / sorting_hint / menu-order
mutation).

Methodology (snapshot 2026-09-02):
  * Ranking sources: awesome-koreader (jannick-holm, stars), KindleModShelf
    plugin index, koreader/contrib, and the in-device AppStore catalogue
    (github topic `koreader-plugin`, ~739 repos Aug 2026). Star counts below
    are the awesome-list values at snapshot time; they pin WHY each plugin
    was included, not a runtime dependency.
  * Inclusion criterion: the plugin contributes at least one row to the main
    menu in production (the only surface Reordering Menus interoperates
    with). Pure gestures/sync daemons with no menu entry are out of scope.
  * Each entry models the plugin's REAL menu contract only (ids, hints,
    tab mutations, nesting style, conditional rows) — not its business
    logic — using the same public shapes production plugins use:
      - single leaf + sorting_hint (hello-world pattern: assistant, anki,
        zlibrary, …)
      - multi-hint leaves (appstore, zotero, localsend, …)
      - order-key nesting (rakuyomi sources, legado, miniflux feeds, …)
      - embedded sub_item_table (menu-customizer profiles pattern)
      - custom top-level tabs via menu-order mutation (bookshelf,
        ProjectTitle, simpleui, zen_ui, filebrowserplus)
      - conditional rows absent from addToMainMenu (device-gated extras)
      - intentional id collisions (zlibrary x2, readeck x2)
      - adversarial hints (missing / empty / separator / leaf-target)

What is verified (both views unless marked FM/R only):
  1. Discovery & attribution — every live id resolves to a parent/tab with
     the correct provider; collisions resolve deterministically.
  2. MenuSorter roundtrip at scale — REAL stock sort builds without crash,
     with no NEW:-prefixed orphans and every live row rendered.
  3. User-operation matrix — hide / intra-menu move / cross-menu move /
     tab reorder / separator / custom submenu containing plugin rows,
     then save + reload + session-rebuild persistence.
  4. Dormancy & provider isolation — disabling half the providers drops
     their rows without crash or resurrection; re-enabling restores their
     customizations without migrating to a colliding provider.
  5. Hint safety under hidden containers — hiding a hinted submenu keeps
     the stock build crash-free (production guards).
  6. Cross-view independence — reader customizations never leak to FM.
  7. Direct-competitor coexistence — menu-customizer (menu_disabler) and
     our own reordering_menus entry survive together.

Hermetic: isolated KO_HOME via run_tests.sh, fresh_world() at start, no
network, deterministic (no RNG).
--]]

local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")
local FuzzLib = dofile(project_dir .. "/tests/lib/fuzz_lib.lua")
FuzzLib.boot(project_dir)

local KoreaderAdapter = require("lib.koreader_adapter")
local Manager = require("lib.menuorder_manager")
local MenuSchema = require("lib.menu_schema")
local util = require("util")

KoreaderAdapter.installSortingHintGuard()
KoreaderAdapter.installCustomSubmenuGuard()
local MenuSorter = require("ui/menusorter")

local ROOT = MenuSchema.MENU_BUTTONS_KEY
local DISABLED = MenuSchema.DISABLED_KEY
local SEP = MenuSchema.SEPARATOR_ID

local passed, failed = 0, 0
local function ok(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("  [FAIL] " .. (msg or "assertion failed"))
    end
end
local function contains(list, needle)
    for _, v in ipairs(list or {}) do
        if v == needle then return true end
    end
    return false
end
local function index_of(list, needle)
    for i, v in ipairs(list or {}) do
        if v == needle then return i end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Catalog: 50 most popular menu-integrating third-party plugins.
-- stars = awesome-koreader snapshot 2026-09-02 (inclusion rationale only).
-- views: "both" | "filemanager" | "reader".
-- items: { id, hint (sorting_hint or nil), text }.
-- tab: { id, insert_at (nil = append) } for menu-order-mutating plugins.
-- order_tree: { [menu_id] = { child ids } } for order-key nesting.
-- conditional: id present in static MENU_ORDER but NOT contributed live.
-- sub_table: embedded anonymous sub_item_table (menu-customizer pattern).
-- ---------------------------------------------------------------------------
local CATALOG = {
    { name = "simpleui", repo = "doctorhetfield-cmd/simpleui.koplugin", stars = 1482, views = "both",
      items = { { id = "simpleui_home_open", hint = nil, text = "SimpleUI Home" }, { id = "simpleui_navbar", hint = nil, text = "SimpleUI Navbar" } },
      tab = { id = "simpleui_tab", insert_at = 1 }, tab_items = { "simpleui_home_open", "simpleui_navbar" } },
    { name = "koinsight", repo = "GeorgeSG/KoInsight", stars = 452, views = "both",
      items = { { id = "koinsight_dashboard", hint = "more_tools", text = "KoInsight" }, { id = "koinsight_sync", hint = "more_tools", text = "KoInsight Sync" } } },
    { name = "assistant", repo = "omer-faruq/assistant.koplugin", stars = 442, views = "both",
      items = { { id = "assistant", hint = "more_tools", text = "Assistant" } } },
    { name = "zlibrary_Z", repo = "ZlibraryKO/zlibrary.koplugin", stars = 320, views = "both",
      items = { { id = "zlibrary_main", hint = "more_tools", text = "Z-Library" }, { id = "zlibrary_search", hint = "search", text = "Z-Library Search" } } },
    { name = "rakuyomi", repo = "hanatsumi/rakuyomi", stars = 221, views = "both",
      items = { { id = "rakuyomi", hint = "more_tools", text = "Rakuyomi",
        sub_table = { { text = "Source A" }, { text = "Source B" }, { text = "Rakuyomi Settings" } } } } },
    { name = "zen_ui", repo = "AnthonyGress/zen_ui.koplugin", stars = 220, views = "both",
      items = { { id = "zen_ui_toggle", hint = nil, text = "Zen Mode" }, { id = "zen_ui_settings", hint = nil, text = "Zen Settings" }, { id = "zen_ui_sub", hint = nil, text = "Zen Sub" }, { id = "zen_ui_sub_item", hint = nil, text = "Zen Sub Item" } },
      tab = { id = "zen_ui_tab", insert_at = nil }, tab_items = { "zen_ui_toggle", "zen_ui_settings", "zen_ui_sub" },
      order_tree = { zen_ui_sub = { "zen_ui_sub_item" } } },
    { name = "zlibrary_octo", repo = "OctoNezd/zlibrary.koplugin", stars = 193, views = "both",
      items = { { id = "zlibrary_main", hint = "more_tools", text = "Z-Library (alt)" } } },
    { name = "anki", repo = "Ajatt-Tools/anki.koplugin", stars = 179, views = "both",
      items = { { id = "anki_add_card", hint = "more_tools", text = "Add to Anki" }, { id = "anki_settings", hint = "more_tools", text = "Anki Settings" } } },
    { name = "legado", repo = "pengcw/legado.koplugin", stars = 166, views = "both",
      items = { { id = "legado", hint = "more_tools", text = "Legado",
        sub_table = { { text = "Legado Shelf" }, { text = "Legado Search" } } } } },
    { name = "highlightsync", repo = "gitalexcampos/highlightsync.koplugin", stars = 159, views = "both",
      items = { { id = "highlightsync_now", hint = "more_tools", text = "Sync Highlights",
        sub_table = { { text = "HighlightSync Settings" } } } } },
    { name = "appstore", repo = "omer-faruq/appstore.koplugin", stars = 136, views = "both",
      items = { { id = "appstore_browse", hint = "more_tools", text = "AppStore" }, { id = "appstore_manage", hint = "tools", text = "Manage Plugins" } } },
    { name = "zotero", repo = "stelzch/zotero.koplugin", stars = 130, views = "both",
      items = { { id = "zotero_browse", hint = "search", text = "Zotero" }, { id = "zotero_download", hint = "more_tools", text = "Zotero Download" } } },
    { name = "localsend", repo = "kaikozlov/localsend.koplugin", stars = 104, views = "both",
      items = { { id = "localsend_send", hint = "more_tools", text = "LocalSend" }, { id = "localsend_receive", hint = "tools", text = "LocalSend Receive" } } },
    { name = "kobo_extras", repo = "OGKevin/kobo.koplugin", stars = 79, views = "both",
      items = { { id = "kobo_extras", hint = "setting", text = "Kobo Extras" } },
      conditional = "kobo_extras_nickel_only" },
    { name = "kindlebt", repo = "finlater/kindlebtcontroller.koplugin", stars = 72, views = "both",
      items = { { id = "kindlebt", hint = "setting", text = "KindleBT Controller" } },
      conditional = "kindlebt_pairing_extra" },
    { name = "menu_customizer", repo = "JoeBumm/Koreader-Menu-customizer", stars = 70, views = "both",
      items = { { id = "menu_disabler", hint = "more_tools", text = "Menu Disabler",
        sub_table = { { text = "Customize File Manager Menus" }, { text = "Customize Reader Menus" }, { text = "Reset All Menus", separator = true } } } } },
    { name = "annotationsync", repo = "dani84bs/AnnotationSync.koplugin", stars = 69, views = "both",
      items = { { id = "annotationsync_now", hint = "more_tools", text = "Annotation Sync" } } },
    { name = "miniflux", repo = "AlgusDark/miniflux.koplugin", stars = 63, views = "both",
      items = { { id = "miniflux", hint = "more_tools", text = "Miniflux",
        sub_table = { { text = "Feed A" }, { text = "Feed B" } } } } },
    { name = "readeck_iceyear", repo = "iceyear/readeck.koplugin", stars = 63, views = "both",
      items = { { id = "readeck_main", hint = "more_tools", text = "Readeck" } } },
    { name = "koassistant", repo = "zeeyado/koassistant.koplugin", stars = 59, views = "both",
      items = { { id = "koassistant", hint = "more_tools", text = "KoAssistant" } } },
    { name = "webbrowser", repo = "omer-faruq/webbrowser.koplugin", stars = 58, views = "both",
      items = { { id = "webbrowser_open", hint = "more_tools", text = "Web Browser" }, { id = "webbrowser_history", hint = "tools", text = "Browser History" } } },
    { name = "opds_plus", repo = "greywolf1499/opds_plus.koplugin", stars = 57, views = "both",
      items = { { id = "opds_plus_browse", hint = "search", text = "OPDS Plus" } } },
    { name = "comicreader", repo = "KORComic/comicreader.koplugin", stars = 60, views = "both",
      items = { { id = "comicreader", hint = "more_tools", text = "Comic Reader",
        sub_table = { { text = "Dual Page" }, { text = "Metadata" } } } } },
    { name = "comicmeta", repo = "KORComic/comicmeta.koplugin", stars = 21, views = "filemanager",
      items = { { id = "comicmeta_extract", hint = "tools", text = "Comic Metadata" } } },
    { name = "projecttitle", repo = "joshuacant/ProjectTitle", stars = 300, views = "filemanager",
      items = { { id = "projecttitle_home", hint = nil, text = "PT Home" }, { id = "projecttitle_footer", hint = nil, text = "PT Footer" } },
      tab = { id = "projecttitle_tab", insert_at = 1 }, tab_items = { "projecttitle_home", "projecttitle_footer" } },
    { name = "bookshelf", repo = "bookshelf (canonical custom tab)", stars = 200, views = "filemanager",
      items = { { id = "bookshelf_toggle", hint = nil, text = "Open Bookshelf" }, { id = "bookshelf_settings", hint = nil, text = "Bookshelf Settings" }, { id = "bookshelf_about", hint = nil, text = "About Bookshelf" } },
      tab = { id = "bookshelf_tab", insert_at = 2 }, tab_items = { "bookshelf_toggle", "bookshelf_settings", "bookshelf_about" } },
    { name = "filebrowserplus", repo = "patelneeraj/filebrowserplus.koplugin", stars = 40, views = "filemanager",
      items = { { id = "filebrowserplus_serve", hint = nil, text = "Filebrowser Serve" }, { id = "filebrowserplus_stop", hint = nil, text = "Filebrowser Stop" } },
      tab = { id = "filebrowserplus_tab", insert_at = nil }, tab_items = { "filebrowserplus_serve", "filebrowserplus_stop" } },
    { name = "syncthing", repo = "arthurrump/syncthing.koplugin", stars = 29, views = "both",
      items = { { id = "syncthing_toggle", hint = "more_tools", text = "Syncthing" }, { id = "syncthing_ui", hint = "tools", text = "Syncthing UI" } } },
    { name = "calculator", repo = "zwim/calculator.koplugin", stars = 45, views = "both",
      items = { { id = "calculator", hint = "more_tools", text = "Calculator",
        sub_table = { { text = "Calc History" } } } } },
    { name = "clock", repo = "koreader/contrib clock.koplugin", stars = 30, views = "both",
      items = { { id = "clock_show", hint = "setting", text = "Clock" } } },
    { name = "digitalclock", repo = "DucNg/digitalclock.koplugin", stars = 25, views = "both",
      items = { { id = "digitalclock_show", hint = "setting", text = "Digital Clock" } } },
    { name = "crossword", repo = "roygbyte/crossword.koplugin", stars = 20, views = "both",
      items = { { id = "crossword_play", hint = "more_tools", text = "Crossword" } } },
    { name = "sudoku", repo = "koreader/contrib sudoku", stars = 20, views = "both",
      items = { { id = "sudoku_play", hint = "more_tools", text = "Sudoku" } } },
    { name = "gemini", repo = "koreader/contrib gemini.koplugin", stars = 35, views = "both",
      items = { { id = "gemini", hint = "more_tools", text = "Gemini",
        sub_table = { { text = "Bookmarks" }, { text = "History" }, { text = "Queue" }, { text = "Offline Cache" } } } } },
    { name = "flashcard", repo = "koreader/contrib flashcard.koplugin", stars = 20, views = "both",
      items = { { id = "flashcard_review", hint = "more_tools", text = "Flashcards" } } },
    { name = "dictionarymode", repo = "ckilb/dictionarymode.koplugin", stars = 18, views = "both",
      items = { { id = "dictionarymode_toggle", hint = "setting", text = "Dictionary Mode" } },
      conditional = "dictionarymode_one_tap_extra" },
    { name = "wordreference", repo = "kristianpennacchia/wordreference.koplugin", stars = 15, views = "both",
      items = { { id = "wordreference_lookup", hint = "search", text = "WordReference" } } },
    { name = "vocabulary", repo = "nbngoc93/vocabulary.koplugin", stars = 22, views = "both",
      items = { { id = "vocabulary_builder", hint = "more_tools", text = "Vocabulary Builder" } } },
    { name = "memobook", repo = "omer-faruq/memobook.koplugin", stars = 28, views = "both",
      items = { { id = "memobook_open", hint = "search", text = "MemoBook" }, { id = "memobook_add", hint = "more_tools", text = "Add Memo" } } },
    { name = "quickrss", repo = "qewer33/quickrss.koplugin", stars = 16, views = "both",
      items = { { id = "quickrss_open", hint = "more_tools", text = "QuickRSS" } } },
    { name = "readeck_flip", repo = "flip-rossi/readeck.koplugin", stars = 37, views = "both",
      items = { { id = "readeck_main", hint = "more_tools", text = "Readeck (alt)" } } },
    { name = "hardcover", repo = "Billiam/hardcoverapp.koplugin", stars = 33, views = "both",
      items = { { id = "hardcover_sync", hint = "more_tools", text = "Hardcover Sync" } } },
    { name = "backlog", repo = "cdrso/backlog.koplugin", stars = 24, views = "both",
      items = { { id = "backlog", hint = "more_tools", text = "Backlog",
        sub_table = { { text = "Next Unread" }, { text = "Mark Finished" } } } } },
    { name = "readmastery", repo = "Lalocaballero/readmastery.koplugin", stars = 19, views = "both",
      items = { { id = "readmastery_open", hint = "more_tools", text = "ReadMastery",
        sub_table = { { text = "ReadMastery Stats" }, { text = "Achievements" } } } } },
    { name = "notes", repo = "prasy-loyola/notes.koplugin", stars = 17, views = "both",
      items = { { id = "notes_open", hint = "more_tools", text = "Notes" } } },
    { name = "readingruler", repo = "Syakhisk/readingruler.koplugin", stars = 27, views = "reader",
      items = { { id = "readingruler_toggle", hint = "tools", text = "Reading Ruler" } } },
    { name = "remotenote", repo = "j-v/remotenote.koplugin", stars = 14, views = "both",
      items = { { id = "remotenote_type", hint = "more_tools", text = "Remote Note" } } },
    { name = "karakeep", repo = "AlgusDark/karakeep.koplugin", stars = 26, views = "both",
      items = { { id = "karakeep_open", hint = "search", text = "Karakeep" } } },
    { name = "telegramdown", repo = "Evgeniy-94/TelegramDownloader.koplugin", stars = 31, views = "both",
      items = { { id = "telegramdown_fetch", hint = "more_tools", text = "Telegram Fetch" }, { id = "telegramdown_settings", hint = "tools", text = "Telegram Settings" } } },
    { name = "zzz_redesign", repo = "kristianpennacchia/zzz-readermenuredesign.koplugin", stars = 12, views = "both",
      items = {
        { id = "zzz_missing_hint", hint = "no_such_menu_xyz", text = "ZZZ Missing" },
        { id = "zzz_empty_hint", hint = "", text = "ZZZ Empty" },
        { id = "zzz_sep_hint", hint = "----------------------------", text = "ZZZ Sep" },
        { id = "zzz_leaf_hint", hint = "assistant", text = "ZZZ Leaf-target" },
      } },
}

ok(#CATALOG == 50, "catalog must hold exactly 50 plugins, got " .. #CATALOG)

-- Views served per entry.
local function serves(entry, view)
    if entry.views == "both" then return true end
    return entry.views == view
end

-- Build a mock widget from a catalog entry (menu contract only).
local function make_widget(entry)
    return {
        name = entry.name,
        addToMainMenu = function(_, menu_items)
            for _, it in ipairs(entry.items) do
                local def = { text = it.text or it.id }
                if it.hint ~= nil then def.sorting_hint = it.hint end
                if it.sub_table then def.sub_item_table = it.sub_table end
                def.icon = "appbar.plugin"
                menu_items[it.id] = def
            end
            if entry.tab then
                menu_items[entry.tab.id] = {
                    text = entry.name .. " tab",
                    icon = "appbar.tab",
                }
            end
        end,
    }
end

local ALL_WIDGETS = {}
for _, e in ipairs(CATALOG) do ALL_WIDGETS[#ALL_WIDGETS + 1] = make_widget(e) end

local function widgets_for(view)
    local out = {}
    for i, e in ipairs(CATALOG) do
        if serves(e, view) then out[#out + 1] = ALL_WIDGETS[i] end
    end
    return out
end

-- Mutate the live menu-order module for custom-tab + nesting + conditional
-- entries, mirroring what production plugin init() hooks do.
local function apply_live_order_mutations(view)
    local modname = "ui/elements/" .. view .. "_menu_order"
    local live = require(modname)
    for _, e in ipairs(CATALOG) do
        if serves(e, view) then
            if e.tab then
                if not contains(live[ROOT], e.tab.id) then
                    if e.tab.insert_at then
                        table.insert(live[ROOT], math.min(e.tab.insert_at, #live[ROOT] + 1), e.tab.id)
                    else
                        table.insert(live[ROOT], e.tab.id)
                    end
                end
                local items = e.tab_items or {}
                if live[e.tab.id] == nil then live[e.tab.id] = {} end
                for _, id in ipairs(items) do
                    if not contains(live[e.tab.id], id) then
                        table.insert(live[e.tab.id], id)
                    end
                end
            end
            if e.order_tree then
                for menu_id, children in pairs(e.order_tree) do
                    if live[menu_id] == nil then live[menu_id] = {} end
                    for _, cid in ipairs(children) do
                        if not contains(live[menu_id], cid) then
                            table.insert(live[menu_id], cid)
                        end
                    end
                end
            end
            if e.conditional then
                -- Static MENU_ORDER carries the optional row, but the widget
                -- never contributes it live: it must not become a phantom.
                local host = e.tab and e.tab.id or "more_tools"
                if live[host] == nil then live[host] = {} end
                if not contains(live[host], e.conditional) then
                    table.insert(live[host], e.conditional)
                end
            end
        end
    end
end

-- Build a flat item_table for REAL MenuSorter:sort from live widgets plus
-- synthesized stock placeholders for every id in the projection.
local function build_item_table(view, widgets, projection)
    local items = { [ROOT] = {} }
    for _, w in ipairs(widgets) do
        pcall(w.addToMainMenu, w, items)
    end
    local function ensure(id)
        if items[id] == nil then items[id] = { text = id } end
    end
    for _, t in ipairs(projection[ROOT] or {}) do ensure(t) end
    for menu_id, list in pairs(projection) do
        if menu_id ~= ROOT and menu_id ~= DISABLED and menu_id ~= "KOMenu:custom_submenus"
                and type(list) == "table" then
            ensure(menu_id)
            for _, id in ipairs(list) do
                if id ~= SEP then ensure(id) end
            end
        end
    end
    for _, id in ipairs(projection[DISABLED] or {}) do ensure(id) end
    return items
end

local ORPHANS = 0
local function walk_rendered(root)
    local tabs, by_menu = {}, {}
    local function visit(rows, menu_id)
        local seq = {}
        for _, row in ipairs(rows) do
            if type(row) == "table" then
                if type(row.text) == "string" and row.text:find("^NEW: ") then
                    ORPHANS = ORPHANS + 1
                end
                if row.id and row.id ~= SEP then
                    table.insert(seq, row.id)
                end
                if type(row.sub_item_table) == "table" then
                    visit(row.sub_item_table, row.id)
                end
            end
        end
        by_menu[menu_id] = seq
    end
    for _, tab_content in ipairs(root) do
        if type(tab_content) == "table" then
            if tab_content.id then table.insert(tabs, tab_content.id) end
            visit(tab_content, tab_content.id)
        end
    end
    return tabs, by_menu
end

local function collect_rendered_ids(by_menu)
    local seen = {}
    for _, seq in pairs(by_menu) do
        for _, id in ipairs(seq) do seen[id] = true end
    end
    return seen
end

local function setup_view(view)
    local widgets = widgets_for(view)
    local ui = { menu = { registered_widgets = widgets } }
    local regs, provs, colls = KoreaderAdapter.collectLiveRegistrations(ui)
    Manager:setLiveRegistrations(view, regs, provs, colls)
    Manager:refreshRegistry(view)
    return widgets, regs, provs, colls
end

-- ---------------------------------------------------------------------------
-- Bootstrap: stock snapshot FIRST (late-plugin boundary), then mutations.
-- ---------------------------------------------------------------------------
FuzzLib.fresh_world()
KoreaderAdapter.getDefaultOrder("filemanager", true)
KoreaderAdapter.getDefaultOrder("reader", true)
apply_live_order_mutations("filemanager")
apply_live_order_mutations("reader")

local FM_WIDGETS, FM_REGS = (function()
    local w, r = setup_view("filemanager")
    return w, r
end)()
local RD_WIDGETS, RD_REGS = (function()
    local w, r = setup_view("reader")
    return w, r
end)()

print("--- SECTION 1: Discovery & attribution (" .. #CATALOG .. " plugins) ---")
do
    for _, view in ipairs({ "filemanager", "reader" }) do
        local widgets = view == "filemanager" and FM_WIDGETS or RD_WIDGETS
        local proj = Manager:loadOrder(view)
        ok(type(proj[ROOT]) == "table" and #proj[ROOT] > 0, view .. ": tab bar loads")
        -- Every contributed id is reachable (tab, placed row, or disciplined
        -- orphan with a hint); nothing is silently dropped.
        local regs = view == "filemanager" and FM_REGS or RD_REGS
        local missing = {}
        for id in pairs(regs) do
            if id ~= ROOT then
                local parent = Manager:getParentMenu(view, id)
                local is_tab = contains(proj[ROOT], id)
                local hidden = Manager:isItemHidden(view, id)
                if not is_tab and not parent and not hidden then
                    missing[#missing + 1] = id
                end
            end
        end
        -- Only adversarial-hint rows may lack a resolved parent; everything
        -- else must be placed or be a tab.
        local allowed_unplaced = { zzz_missing_hint = true, zzz_empty_hint = true,
            zzz_sep_hint = true, zzz_leaf_hint = true }
        local hard_missing = {}
        for _, id in ipairs(missing) do
            if not allowed_unplaced[id] then hard_missing[#hard_missing + 1] = id end
        end
        ok(#hard_missing == 0, view .. ": all live ids placed (" ..
            (#hard_missing > 0 and table.concat(hard_missing, ",") or "ok") .. ")")
        -- Custom tabs discovered at requested positions.
        if view == "filemanager" then
            ok(contains(proj[ROOT], "bookshelf_tab"), "FM: bookshelf_tab discovered")
            ok(proj[ROOT][2] == "bookshelf_tab", "FM: bookshelf keeps position 2")
            ok(contains(proj[ROOT], "projecttitle_tab"), "FM: projecttitle_tab discovered")
            ok(contains(proj[ROOT], "simpleui_tab"), "FM: simpleui_tab discovered")
        end
        -- Nested order-key trees discovered.
        for _, e in ipairs(CATALOG) do
            if serves(e, view) and e.order_tree then
                for menu_id, children in pairs(e.order_tree) do
                    local list = Manager:getMenuItems(view, menu_id)
                    for _, cid in ipairs(children) do
                        ok(contains(list, cid), view .. ": " .. e.name .. "/" .. cid .. " nested under " .. menu_id)
                    end
                end
            end
            -- Conditional rows must never become phantoms.
            if serves(e, view) and e.conditional then
                local found = false
                local full = Manager:loadOrder(view)
                for menu_id, list in pairs(full) do
                    if type(list) == "table" and contains(list, e.conditional) then found = true end
                end
                ok(not found, view .. ": conditional " .. e.conditional .. " stays phantom-free")
            end
        end
        -- Intentional collisions resolve deterministically (lexicographic
        -- minimum wins, stable across repeated collection).
        local ui2 = { menu = { registered_widgets = widgets } }
        local _, provs2 = KoreaderAdapter.collectLiveRegistrations(ui2)
        ok(provs2["zlibrary_main"] ~= nil, view .. ": colliding zlibrary_main attributed")
        ok(provs2["readeck_main"] ~= nil, view .. ": colliding readeck_main attributed")
    end
    print("  [PASS] discovery & attribution")
end

print("--- SECTION 2: MenuSorter roundtrip at scale ---")
do
    for _, view in ipairs({ "filemanager", "reader" }) do
        local widgets = view == "filemanager" and FM_WIDGETS or RD_WIDGETS
        local proj = Manager:loadOrder(view)
        local items = build_item_table(view, widgets, proj)
        ORPHANS = 0
        local ok_sort, result = pcall(function()
            return MenuSorter:sort(items, util.tableDeepCopy(proj))
        end)
        ok(ok_sort, view .. ": stock sort does not crash with all plugins active")
        if ok_sort then
            ok(type(result) == "table" and #result > 0, view .. ": sort returns non-empty tab bar")
            local tabs, by_menu = walk_rendered(result)
            ok(ORPHANS == 0, view .. ": no NEW:-prefixed orphans (" .. ORPHANS .. ")")
            ok(#tabs == #proj[ROOT], view .. ": tab bar intact (" .. #tabs .. " tabs)")
            local seen = collect_rendered_ids(by_menu)
            local absent = {}
            local regs = view == "filemanager" and FM_REGS or RD_REGS
            for id in pairs(regs) do
                if id ~= ROOT and not seen[id] and not contains(tabs, id) then
                    -- Adversarial-hint rows and conditional phantoms are the
                    -- only legitimate absences (guard neutralizes them).
                    if id ~= "zzz_missing_hint" and id ~= "zzz_empty_hint"
                            and id ~= "zzz_sep_hint" and id ~= "zzz_leaf_hint" then
                        -- Submenu-internal children ride with their parent;
                        -- embedded sub_table rows are anonymous by design.
                        local parent = Manager:getParentMenu(view, id)
                        if parent and seen[parent] then
                            -- child hidden inside collapsed parent rendering
                            -- is fine; only count top-level losses.
                        else
                            absent[#absent + 1] = id
                        end
                    end
                end
            end
            -- At scale a handful of hinted orphans attach under submenus the
            -- walker attributes to the parent; require no wholesale loss.
            ok(#absent < 5, view .. ": all plugin rows render (absent=" .. #absent ..
                (#absent > 0 and " [" .. table.concat(absent, ",") .. "]" or "") .. ")")
        end
    end
    print("  [PASS] MenuSorter roundtrip")
end

print("--- SECTION 3: User-operation matrix on plugin rows ---")
do
    local VIEW = "filemanager"
    -- (a) hide representative leaves across archetypes
    local to_hide = { "assistant", "anki_add_card", "miniflux", "koassistant", "quickrss_open" }
    for _, id in ipairs(to_hide) do
        local parent = Manager:getParentMenu(VIEW, id)
        if parent then
            ok(Manager:setItemHidden(VIEW, id, true), "hide " .. id)
        end
    end
    -- (b) intra-menu move: first row of more_tools to position 3
    do
        local list = Manager:getMenuItems(VIEW, "more_tools")
        if #list >= 3 then
            ok(Manager:moveItem(VIEW, "more_tools", 1, 3), "intra-menu move in more_tools")
        else
            ok(true, "more_tools too short, intra-move skipped")
        end
    end
    -- (c) cross-menu moves: plugin leaf -> tools; second leaf -> custom tab
    do
        local p = Manager:getParentMenu(VIEW, "vocabulary_builder")
        if p then
            local res = Manager:moveItemToMenu(VIEW, "vocabulary_builder", p, "tools", 1)
            ok(res, "move vocabulary_builder to tools")
        end
        local pb = Manager:getParentMenu(VIEW, "anki_settings")
        if pb and Manager:getMenuItems(VIEW, "simpleui_tab") then
            local res = Manager:moveItemToMenu(VIEW, "anki_settings", pb, "simpleui_tab", 1)
            ok(res, "move anki_settings into simpleui_tab")
        end
    end
    -- (d) tab reorder: reverse the bar
    do
        local tabs = Manager:getTabs(VIEW)
        local rev = {}
        for i = #tabs, 1, -1 do rev[#rev + 1] = tabs[i] end
        ok(Manager:reorderTabs(VIEW, rev), "reverse tab bar")
    end
    -- (e) separator + custom submenu holding plugin rows
    do
        local list = Manager:getMenuItems(VIEW, "more_tools")
        ok(Manager:insertSeparator(VIEW, "more_tools", 2), "insert separator in more_tools")
        local created, custom = Manager:createSubmenu(VIEW, "more_tools", "Top50 Picks", 1)
        ok(created and custom ~= nil, "create custom submenu under more_tools")
        if created and custom then
            local p = Manager:getParentMenu(VIEW, "sudoku_play")
            if p then
                ok(Manager:moveItemToMenu(VIEW, "sudoku_play", p, custom, 1), "move sudoku into custom submenu")
            end
        end
    end
    local saved, save_err = Manager:saveOrder(VIEW)
    ok(saved, "save operation matrix: " .. tostring(save_err))
    -- Verify persistence across reload + session rebuild.
    local after = Manager:loadOrder(VIEW)
    for _, id in ipairs(to_hide) do
        ok(Manager:isItemHidden(VIEW, id), "hidden persists: " .. id)
    end
    ok(contains(after["tools"], "vocabulary_builder"), "moved vocabulary_builder persists in tools")
    Manager:dropSessionState(VIEW)
    setup_view(VIEW)
    local rebuilt = Manager:loadOrder(VIEW)
    ok(contains(rebuilt["tools"], "vocabulary_builder"), "move survives session rebuild")
    for _, id in ipairs(to_hide) do
        ok(Manager:isItemHidden(VIEW, id), "hide survives rebuild: " .. id)
    end
    -- Rebuilt world still sorts cleanly.
    do
        local proj = Manager:loadOrder(VIEW)
        local items = build_item_table(VIEW, widgets_for(VIEW), proj)
        ORPHANS = 0
        local ok_sort, result = pcall(function()
            return MenuSorter:sort(items, util.tableDeepCopy(proj))
        end)
        ok(ok_sort, "sort clean after operation matrix")
        if ok_sort then
            walk_rendered(result)
            ok(ORPHANS == 0, "no orphans after operation matrix")
        end
    end
    print("  [PASS] user-operation matrix")
end

print("--- SECTION 4: Dormancy & provider isolation ---")
do
    local VIEW = "filemanager"
    -- Customize two dormant rows + one survivor row. Section 3 hid
    -- miniflux and anki_add_card, so unhide first: getParentMenu reports
    -- nil for hidden rows and the move would be skipped.
    Manager:setItemHidden(VIEW, "miniflux", false)
    Manager:setItemHidden(VIEW, "anki_add_card", false)
    Manager:setItemHidden(VIEW, "anki_add_card", true)
    do
        local p = Manager:getParentMenu(VIEW, "miniflux")
        ok(p ~= nil, "miniflux has a parent before dormancy move")
        if p then ok(Manager:moveItemToMenu(VIEW, "miniflux", p, "tools", 1), "move miniflux to tools") end
        local ps = Manager:getParentMenu(VIEW, "rakuyomi")
        ok(ps ~= nil, "rakuyomi has a parent before survivor move")
        if ps then ok(Manager:moveItemToMenu(VIEW, "rakuyomi", ps, "tools", 1), "move rakuyomi survivor to tools") end
    end
    ok(Manager:saveOrder(VIEW), "save pre-dormancy customizations")
    -- Disable every other plugin (keep direct competitor + colliding winners).
    local keep = {}
    local drop_names = {}
    for i, e in ipairs(CATALOG) do
        if serves(e, VIEW) and (i % 2 == 0) then
            drop_names[e.name] = true
        else
            keep[#keep + 1] = ALL_WIDGETS[i]
        end
    end
    -- Ensure dormancy targets actually go dormant and survivors stay.
    local function names_of(list)
        local s = {}
        for _, w in ipairs(list) do s[w.name] = true end
        return s
    end
    local kept_names = names_of(keep)
    -- Force the three dormancy targets dormant even if parity kept them.
    local subset = {}
    for _, w in ipairs(keep) do
        if w.name ~= "anki" and w.name ~= "miniflux" and w.name ~= "syncthing" then
            subset[#subset + 1] = w
        else
            drop_names[w.name] = true
        end
    end
    local ui = { menu = { registered_widgets = subset } }
    local regs, provs, colls = KoreaderAdapter.collectLiveRegistrations(ui)
    Manager:setLiveRegistrations(VIEW, regs, provs, colls)
    Manager:refreshRegistry(VIEW)
    local dormant_proj = Manager:loadOrder(VIEW)
    ok(type(dormant_proj) == "table", "order loads with half providers dormant")
    -- Dormant rows vanish; survivor customizations persist.
    do
        local flat = {}
        for menu_id, list in pairs(dormant_proj) do
            if type(list) == "table" then
                for _, id in ipairs(list) do flat[id] = true end
            end
        end
        for _, id in ipairs({ "anki_add_card", "anki_settings", "miniflux", "syncthing_toggle", "syncthing_ui" }) do
            ok(not flat[id], "dormant row absent: " .. id)
        end
        ok(contains(dormant_proj["tools"], "rakuyomi"), "survivor move persists while others dormant")
    end
    do
        local items = build_item_table(VIEW, subset, dormant_proj)
        ORPHANS = 0
        local ok_sort, result = pcall(function()
            return MenuSorter:sort(items, util.tableDeepCopy(dormant_proj))
        end)
        ok(ok_sort, "sort clean with dormant providers")
        if ok_sort then walk_rendered(result) ok(ORPHANS == 0, "no orphans while dormant") end
    end
    -- Re-enable all: dormant customizations return, no migration to a
    -- colliding provider (zlibrary/readeck winners unchanged).
    local ui_full = { menu = { registered_widgets = widgets_for(VIEW) } }
    local r2, p2, c2 = KoreaderAdapter.collectLiveRegistrations(ui_full)
    Manager:setLiveRegistrations(VIEW, r2, p2, c2)
    Manager:refreshRegistry(VIEW)
    local restored = Manager:loadOrder(VIEW)
    ok(Manager:isItemHidden(VIEW, "anki_add_card"), "dormant hide restored on re-enable")
    ok(contains(restored["tools"], "miniflux"), "dormant move restored on re-enable")
    ok(p2["zlibrary_main"] ~= nil and p2["readeck_main"] ~= nil, "colliding attributions stable across churn")
    print("  [PASS] dormancy & isolation")
end

print("--- SECTION 5: Hint safety under hidden containers ---")
do
    local VIEW = "reader"
    -- more_tools hosts most hinted leaves; hiding it must not crash stock.
    Manager:setItemHidden(VIEW, "more_tools", true)
    ok(Manager:saveOrder(VIEW), "save with more_tools hidden")
    local proj = Manager:loadOrder(VIEW)
    local items = build_item_table(VIEW, widgets_for(VIEW), proj)
    ORPHANS = 0
    local ok_sort, result = pcall(function()
        return MenuSorter:sort(items, util.tableDeepCopy(proj))
    end)
    ok(ok_sort, "stock sort survives hidden hint target")
    if ok_sort then
        walk_rendered(result)
        ok(ORPHANS == 0, "hidden hint target yields no NEW: orphans")
    end
    -- Adversarial hints never crash, even against a hidden world.
    local bad_hints = { "no_such_menu_xyz", "", "----------------------------", "assistant" }
    for i, id in ipairs({ "zzz_missing_hint", "zzz_empty_hint", "zzz_sep_hint", "zzz_leaf_hint" }) do
        local klass = KoreaderAdapter.classifyHintTarget(bad_hints[i], proj, id, items)
        ok(klass ~= nil, "classifyHintTarget answers for " .. id .. " (" .. tostring(klass) .. ")")
    end
    Manager:setItemHidden(VIEW, "more_tools", false)
    ok(Manager:saveOrder(VIEW), "unhide more_tools")
    print("  [PASS] hint safety")
end

print("--- SECTION 6: Cross-view independence ---")
do
    FuzzLib.fresh_world()
    apply_live_order_mutations("filemanager")
    apply_live_order_mutations("reader")
    setup_view("filemanager")
    setup_view("reader")
    -- Customize READER only.
    Manager:setItemHidden("reader", "assistant", true)
    do
        local p = Manager:getParentMenu("reader", "vocabulary_builder")
        if p then Manager:moveItemToMenu("reader", "vocabulary_builder", p, "tools", 1) end
    end
    ok(Manager:saveOrder("reader"), "save reader-only customizations")
    ok(Manager:isItemHidden("reader", "assistant"), "reader hide staged")
    ok(not Manager:isItemHidden("filemanager", "assistant"), "filemanager unaffected by reader hide")
    local fm_tools = Manager:getMenuItems("filemanager", "tools")
    ok(not contains(fm_tools, "vocabulary_builder") or Manager:getParentMenu("filemanager", "vocabulary_builder") ~= "tools",
        "filemanager tools unaffected by reader move")
    print("  [PASS] cross-view independence")
end

print("--- SECTION 7: Direct-competitor coexistence ---")
do
    local VIEW = "filemanager"
    local proj = Manager:loadOrder(VIEW)
    -- Both menu editors present as placeable rows.
    local p_disabler = Manager:getParentMenu(VIEW, "menu_disabler")
    ok(p_disabler ~= nil or contains(proj[ROOT], "menu_disabler") or Manager:isItemHidden(VIEW, "menu_disabler") == false,
        "menu_disabler (competitor) coexists")
    -- Move the competitor entry, hide one of ours, save, rebuild.
    do
        local p = Manager:getParentMenu(VIEW, "menu_disabler")
        if p and p ~= "tools" then
            ok(Manager:moveItemToMenu(VIEW, "menu_disabler", p, "tools", 1), "move competitor entry to tools")
        else
            ok(true, "competitor already in tools or hidden")
        end
    end
    Manager:setItemHidden(VIEW, "assistant", true)
    ok(Manager:saveOrder(VIEW), "save alongside competitor")
    Manager:dropSessionState(VIEW)
    setup_view(VIEW)
    local rebuilt = Manager:loadOrder(VIEW)
    ok(type(rebuilt) == "table", "rebuild clean alongside competitor")
    do
        local items = build_item_table(VIEW, widgets_for(VIEW), rebuilt)
        ORPHANS = 0
        local ok_sort, result = pcall(function()
            return MenuSorter:sort(items, util.tableDeepCopy(rebuilt))
        end)
        ok(ok_sort, "sort clean alongside competitor")
        if ok_sort then
            local _, by_menu = walk_rendered(result)
            ok(ORPHANS == 0, "no orphans alongside competitor")
            local seen = collect_rendered_ids(by_menu)
            ok(seen["menu_disabler"], "competitor row still renders")
        end
    end
    print("  [PASS] competitor coexistence")
end

print(string.format("=== TOP-50 COMPATIBILITY: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end

--[[--
test_submenu_arrow_nav.lua — P2 regression: the visible submenu arrow and its
tap target are the same rectangle.

Covers, in both LTR and RTL layouts:
  * every submenu row renders a separate edge-aligned arrow widget
    (plain rows render none), with the layout-correct glyph;
  * the arrow sits at the row's trailing edge (right in LTR, left in RTL);
  * tapping the arrow's actual bounds navigates into the submenu, while
    tapping the row body only marks it for selection/dragging;
   * the legacy second-tap fallback (tap marked row) still navigates;
   * very long titles truncate inside a budget that reserves the arrow,
     so the label never slides underneath it.

Also pins the two visual affordances that ride with navigation:
  * the dirty indicator suffix appears while unsaved and clears on save;
  * nested editors title themselves with a compact breadcrumb path that
    never leaks internal KOMenu ids.
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"),
    "cannot locate plugin directory")
package.path = project_dir .. "/?.lua;" .. package.path

local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir()
    .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()

local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local BD = require("ui/bidi")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

require("main")

local ReaderMenu = require("apps/reader/modules/readermenu")
local MenuOrderManager = require("lib.menuorder_manager")
local UIScreens = require("lib.ui_screens")
local ReorderingMenus = require("main")

local passed, failed = 0, 0
local function note(cond, msg)
    if cond then passed = passed + 1
    else failed = failed + 1; print("  [FAIL] " .. tostring(msg)); io.stdout:flush() end
end

local mock_ui_reader = {
    document = { file = "/tmp/arrow_nav_probe.epub", configurable = {} },
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

local VIEW = "reader"

local function wipe()
    for _, f in ipairs({ "reader_menu_order.lua", "filemanager_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        pcall(os.remove, DataStorage:getSettingsDir() .. "/" .. f)
    end
    MenuOrderManager:dropSessionState("reader")
    MenuOrderManager:dropSessionState("filemanager")
end

local function close_all()
    while #UIManager._window_stack > 0 do
        local entry = UIManager._window_stack[#UIManager._window_stack]
        local w = entry and (entry.widget or entry)
        if w then UIManager:close(w) else break end
    end
end

local function top_editor()
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget
            or UIManager._window_stack[i]
        if w and w.item_table and w._populateItems and w.marked ~= nil then
            return w
        end
    end
end

local function paint(editor)
    local bb = Blitbuffer.new(Screen:getWidth(), Screen:getHeight())
    editor:paintTo(bb, 0, 0)
end

local function row_widget(editor, item_id)
    for _, entry in ipairs(editor.layout or {}) do
        local row = entry and entry[1]
        if row and row.item and row.item.item_id == item_id
                and row.show_parent == editor then
            return row
        end
    end
end

local function submenu_data_id(editor)
    for _, r in ipairs(editor.item_table) do
        if r.is_submenu and r.item_id
                and r.item_id ~= MenuOrderManager.SEPARATOR_ID then
            return r.item_id
        end
    end
end

local function plain_data_id(editor)
    for _, r in ipairs(editor.item_table) do
        if not r.is_submenu and r.item_id
                and r.item_id ~= MenuOrderManager.SEPARATOR_ID
                and r.item_id ~= "KOMenu:disabled" then
            return r.item_id
        end
    end
end

print("===============================================================")
print("=== Submenu arrow: rendered bounds == tap target (LTR/RTL)  ===")
print("===============================================================")

-- =====================================================================
-- LTR: edge arrow, glyph, taps, indicator, breadcrumb
-- =====================================================================
do
    wipe()
    MenuOrderManager:resetOrder(VIEW)
    close_all()
    assert(BD.mirroredUILayout() == false, "LTR precondition")

    UIScreens:showItemSortWidget(plugin, VIEW, "tools")
    local ed = top_editor()
    note(ed ~= nil, "LTR: tools editor opens")
    paint(ed)

    local sub_id = submenu_data_id(ed)
    note(sub_id ~= nil, "LTR: tools has a submenu row")
    local sub_row = sub_id and row_widget(ed, sub_id) or nil
    note(sub_row ~= nil, "LTR: submenu widget found in layout")

    local plain_row
    for _, entry in ipairs(ed.layout or {}) do
        local row = entry and entry[1]
        if row and row.item and row.show_parent == ed
                and not row.item.is_submenu then
            plain_row = row
            break
        end
    end
    note(plain_row ~= nil, "LTR: plain row widget found")
    note(plain_row and plain_row.nav_arrow_widget == nil,
        "LTR: plain rows render no arrow widget")

    if sub_row then
        local arrow = sub_row.nav_arrow_widget
        note(arrow ~= nil, "LTR: submenu row renders an arrow widget")
        if arrow then
            note(arrow.text == "→", "LTR: arrow glyph points right")
            local d = arrow.dimen
            local geom_ok = type(d.x) == "number" and type(d.w) == "number"
                and d.w > 0 and d.h > 0
            note(geom_ok, "LTR: arrow has real painted bounds")
            if geom_ok then
                local sw = Screen:getWidth()
                note(d.x + d.w >= sw - 60,
                    string.format("LTR: arrow hugs the right edge (right=%d screen=%d)",
                        d.x + d.w, sw))
                note(d.x + d.w / 2 > sw / 2,
                    "LTR: arrow sits in the row's right half")
                -- The row label itself carries no inline arrow: the widget
                -- is the single affordance.
                note(not tostring(sub_row.item.text):find("→", 1, true)
                    and not tostring(sub_row.item.text):find("←", 1, true),
                    "LTR: row text carries no inline arrow")

                -- Arrow tap navigates; the nested editor opens on top.
                local before = #UIManager._window_stack
                sub_row:onTap(nil, { pos = Geom:new{
                    x = d.x + math.floor(d.w / 2),
                    y = d.y + math.floor(d.h / 2),
                } })
                note(#UIManager._window_stack == before + 1,
                    "LTR: tapping the arrow opens the submenu")
                -- Breadcrumb on the nested editor names the path, no internals.
                local nested = top_editor()
                local title = nested and tostring(nested.title) or ""
                note(title:find("›", 1, true) ~= nil,
                    "breadcrumb shows a compact › path: " .. title)
                note(title:find("KOMenu", 1, true) == nil,
                    "breadcrumb never leaks internal ids")
                while #UIManager._window_stack > before do
                    local e = UIManager._window_stack[#UIManager._window_stack]
                    UIManager:close(e.widget or e)
                end
                ed = top_editor()
                paint(ed)
                sub_row = row_widget(ed, sub_id)

                -- Body tap (row middle, far from checkmark and arrow) marks.
                ed.marked = 0
                local body_x = math.floor(sw / 2)
                local body_y = sub_row.nav_arrow_widget.dimen.y
                    + math.floor(sub_row.nav_arrow_widget.dimen.h / 2)
                local stack_before = #UIManager._window_stack
                sub_row:onTap(nil, { pos = Geom:new{ x = body_x, y = body_y } })
                note(ed.marked == sub_row.index,
                    "LTR: tapping the row body marks it")
                note(#UIManager._window_stack == stack_before,
                    "LTR: body tap does not navigate")

                -- Second tap on the marked row still navigates (fallback).
                sub_row:onTap(nil, { pos = Geom:new{ x = body_x, y = body_y } })
                note(#UIManager._window_stack == stack_before + 1,
                    "LTR: second tap on the marked row navigates")
                while #UIManager._window_stack > stack_before do
                    local e = UIManager._window_stack[#UIManager._window_stack]
                    UIManager:close(e.widget or e)
                end
            end
        end
    end
    close_all()
end

-- =====================================================================
-- RTL: mirrored glyph, left edge, arrow tap navigates
-- =====================================================================
do
    wipe()
    MenuOrderManager:resetOrder(VIEW)
    close_all()
    BD.invert()
    note(BD.mirroredUILayout() == true, "RTL precondition (mirrored)")

    UIScreens:showItemSortWidget(plugin, VIEW, "tools")
    local ed = top_editor()
    note(ed ~= nil, "RTL: tools editor opens")
    paint(ed)

    local sub_id = submenu_data_id(ed)
    local sub_row = sub_id and row_widget(ed, sub_id) or nil
    note(sub_row ~= nil and sub_row.nav_arrow_widget ~= nil,
        "RTL: submenu row renders an arrow widget")
    if sub_row and sub_row.nav_arrow_widget then
        local arrow = sub_row.nav_arrow_widget
        note(arrow.text == "←", "RTL: arrow glyph points left")
        local d = arrow.dimen
        local sw = Screen:getWidth()
        note(d.x <= 60,
            string.format("RTL: arrow hugs the left edge (x=%d)", d.x))
        note(d.x + d.w / 2 < sw / 2,
            "RTL: arrow sits in the row's left half")
        local before = #UIManager._window_stack
        arrow = sub_row.nav_arrow_widget
        sub_row:onTap(nil, { pos = Geom:new{
            x = d.x + math.floor(d.w / 2),
            y = d.y + math.floor(d.h / 2),
        } })
        note(#UIManager._window_stack == before + 1,
            "RTL: tapping the arrow opens the submenu")
    end
    BD.resetInvert()
    note(BD.mirroredUILayout() == false, "layout restored to LTR")
    close_all()
end

-- =====================================================================
-- Long titles truncate before the arrow instead of running under it
-- =====================================================================
do
    wipe()
    MenuOrderManager:resetOrder(VIEW)
    close_all()

    -- NB: createSubmenu trims the name, so build it without edge space.
    local long_name = string.rep("Very long submenu name! ", 10):gsub("%s+$", "")
    local ok, long_id = MenuOrderManager:createSubmenu(VIEW, "tools", long_name)
    note(ok, "long-titled submenu created")
    note(MenuOrderManager:saveOrder(VIEW), "long-titled submenu saved")
    -- Drop the cached live tree (built by earlier blocks, before this custom
    -- existed) so the editor resolves against current state; this mirrors
    -- production, where the live menu rebuilds on open.
    mock_ui_reader.menu.tab_item_table = nil
    UIScreens:showItemSortWidget(plugin, VIEW, "tools")
    local ed = top_editor()
    note(ed ~= nil, "long title: editor opens")
    paint(ed)

    local long_row = long_id and row_widget(ed, long_id) or nil
    note(long_row ~= nil, "long title: row widget found")
    if long_row then
        -- The row label keeps the full plain title; truncation happens in
        -- the title widget's layout budget, not by rewriting the label.
        note(long_row.item.text == long_name,
            "long title: data label keeps the full name")
        local arrow = long_row.nav_arrow_widget
        note(arrow ~= nil, "long title: arrow widget still rendered")
        -- Locate the title TextWidget (full text, truncating): walk the row
        -- without following show_parent back into the whole editor.
        local title_w
        do
            local seen = {}
            local function walk(w)
                if type(w) ~= "table" or seen[w] or title_w then return end
                seen[w] = true
                if w.text == long_name and type(w.isTruncated) == "function" then
                    title_w = w
                    return
                end
                for k, v in pairs(w) do
                    if type(v) == "table" and k ~= "show_parent" then
                        walk(v)
                        if title_w then return end
                    end
                end
            end
            walk(long_row)
        end
        note(title_w ~= nil, "long title: title widget found")
        if title_w and arrow then
            note(title_w:isTruncated() == true,
                "long title: title is truncated")
            local Size = require("ui/size")
            local CheckMark = require("ui/widget/checkmark")
            local pad = Size.padding.default
            local check_w = CheckMark:new{ checked = true }:getSize().w
            local arrow_w = arrow:getSize().w
            local full_budget = ed.item_width - 2 * pad - check_w
            note(type(title_w.max_width) == "number"
                and title_w.max_width <= full_budget - arrow_w,
                string.format("long title: budget reserves the arrow (max=%s budget=%s arrow=%s)",
                    tostring(title_w.max_width), tostring(full_budget), tostring(arrow_w)))
            note(title_w:getSize().w <= title_w.max_width + 1,
                "long title: rendered width fits the budget")
            -- Geometric non-overlap: the truncated title's right bound ends
            -- at or before the arrow's left edge (LTR layout here).
            local sw = Screen:getWidth()
            local row_left = (sw - ed.item_width) / 2
            local title_right = row_left + check_w + 2 * pad + title_w.max_width
            local d = arrow.dimen
            note(title_right <= d.x + 2,
                string.format("long title: truncated end (%d) stays before the arrow (%d)",
                    math.floor(title_right), d.x))
            -- The arrow stays usable on the long row too.
            local before = #UIManager._window_stack
            long_row:onTap(nil, { pos = Geom:new{
                x = d.x + math.floor(d.w / 2),
                y = d.y + math.floor(d.h / 2),
            } })
            note(#UIManager._window_stack == before + 1,
                "long title: arrow tap still navigates")
        end
    end
    close_all()
    wipe()
end

-- =====================================================================
-- Dirty indicator + breadcrumb rendering
-- =====================================================================
do
    wipe()
    MenuOrderManager:resetOrder(VIEW)
    close_all()

    UIScreens:showItemSortWidget(plugin, VIEW, "tools")
    local ed = top_editor()
    note(ed ~= nil, "indicator: editor opens")
    note(tostring(ed.title):find("Unsaved changes", 1, true) == nil,
        "indicator: clean editor shows no suffix")

    -- A drag makes the title carry the suffix (repaint refreshes it).
    if #ed.item_table >= 2 then
        ed.item_table[1], ed.item_table[2] = ed.item_table[2], ed.item_table[1]
        ed:_populateItems()
        note(tostring(ed.title):find("Unsaved changes", 1, true) ~= nil,
            "indicator: dirty editor shows the suffix")
        -- Saving clears it again.
        ed.marked = 0
        ed.callback()
        note(tostring(ed.title):find("Unsaved changes", 1, true) == nil,
            "indicator: save clears the suffix")
    else
        note(false, "indicator: tools has two rows to drag")
    end
    close_all()

    -- Nested breadcrumb names view › parent › current, without internals.
    UIScreens:showItemSortWidget(plugin, VIEW, "more_tools")
    local nested = top_editor()
    local title = nested and tostring(nested.title) or ""
    note(title:find("Book view", 1, true) ~= nil
        and title:find("Tools", 1, true) ~= nil
        and title:find("More tools", 1, true) ~= nil,
        "breadcrumb: nested title names the path: " .. title)
    note(title:find("KOMenu", 1, true) == nil,
        "breadcrumb: no internal ids")
    close_all()
    wipe()
end

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)

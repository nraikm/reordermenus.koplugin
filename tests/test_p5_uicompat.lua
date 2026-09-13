--[[--
test_p5_uicompat.lua — Prompt 5 §4: private-widget compatibility isolation.

UICompat.install/releaseSortWidgetSubmenuTap borrows KOReader's private
SortItemWidget via debug.getupvalue. This suite pins the isolation contract
with FAKE widgets (no KOReader UI needed):

  install/release pairing .... wrap on install, byte-exact restore on last
                               release, over-release is a safe no-op
  nesting (refcount) .......... double install stays patched until the second
                               release (drill-down editors)
  another patch owner ......... a pre-set reordering_menus_submenu_tap flag is
                               adopted, never double-wrapped; release hands
                               back the adopted originals
  fail-safe ................... a SortWidget without the upvalue refuses
                               (false) without touching anything
--]]

dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))
package.path = project_dir .. "/?.lua;" .. package.path

local passed, failed = 0, 0
local function ok(c, msg)
    if c then passed = passed + 1
    else failed = failed + 1; print("  [FAIL] " .. tostring(msg)); io.stdout:flush() end
end

local UICompat = require("lib.ui_compat")

-- Fake SortWidget whose _populateItems closes over a fake SortItemWidget
-- under the exact upvalue name the adapter looks for.
local function make_widgets()
    local SortItemWidget = {
        init = function(self) self.inited = true end,
        onTap = function(self) self.tapped = true end,
    }
    local function _populateItems() return SortItemWidget end
    return { _populateItems = _populateItems, __row = SortItemWidget }
end

print("=== P5 uicompat isolation ===")

do
    local W = make_widgets()
    local orig_init, orig_tap = W.__row.init, W.__row.onTap
    ok(UICompat.installSortWidgetSubmenuTap(W) == true, "install wraps")
    ok(W.__row.init ~= orig_init and W.__row.onTap ~= orig_tap, "methods swapped")
    ok(W.__row.reordering_menus_submenu_tap == true, "ownership flag set")
    UICompat.releaseSortWidgetSubmenuTap(W)
    ok(W.__row.init == orig_init and W.__row.onTap == orig_tap,
        "last release restores byte-exact originals")
    ok(W.__row.reordering_menus_submenu_tap == nil, "flag cleared")
    UICompat.releaseSortWidgetSubmenuTap(W) -- over-release
    ok(W.__row.init == orig_init and W.__row.onTap == orig_tap,
        "over-release is a safe no-op")
end

do
    local W = make_widgets()
    local orig_init, orig_tap = W.__row.init, W.__row.onTap
    ok(UICompat.installSortWidgetSubmenuTap(W) == true, "first install")
    ok(UICompat.installSortWidgetSubmenuTap(W) == true, "nested install")
    UICompat.releaseSortWidgetSubmenuTap(W)
    ok(W.__row.onTap ~= orig_tap, "one release keeps the patch (refcount)")
    UICompat.releaseSortWidgetSubmenuTap(W)
    ok(W.__row.init == orig_init and W.__row.onTap == orig_tap,
        "second release restores")
end

do
    local W = make_widgets()
    local foreign_tap = function(self) self.foreign = true end
    W.__row.onTap = foreign_tap
    W.__row.reordering_menus_submenu_tap = true -- another owner was here
    ok(UICompat.installSortWidgetSubmenuTap(W) == true, "adopt foreign patch")
    ok(W.__row.onTap == foreign_tap, "adopted, never double-wrapped")
    UICompat.releaseSortWidgetSubmenuTap(W)
    ok(W.__row.onTap == foreign_tap, "release hands back adopted original")
    ok(W.__row.reordering_menus_submenu_tap == nil, "adopted flag cleared")
end

do
    local W = { _populateItems = function() end } -- no upvalue at all
    ok(UICompat.installSortWidgetSubmenuTap(W) == false, "refuses safely")
    UICompat.releaseSortWidgetSubmenuTap(W) -- must not error
    ok(true, "release after refusal is safe")
end

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed == 0 and 0 or 1)

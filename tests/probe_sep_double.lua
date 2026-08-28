-- Minimal repro attempt: double stock separator in help after round trip.
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
local Manager = require("reorderingmenus_menuorder_manager")
local IntentStore = require("reorderingmenus_intent_store")
local KoreaderAdapter = require("reorderingmenus_koreader_adapter")

-- Build a native file whose help list carries a DOUBLED stock separator
-- (search_menu, ----, ----, report_bug, ...). Simulate: this is what the
-- BEFORE projection showed. Import it as external, then materialize.
local view = "filemanager"
Manager:saveOrder(view)

local path = KoreaderAdapter.getNativePath(view)
-- Seed real intent first (sparse purity: pristine world writes no file),
-- then save so the derived native file exists on disk.
Manager:setItemHidden(view, "opds", true, "search")
Manager:saveOrder(view)
print("exists after save:", io.open(path, "r") ~= nil)
local f = assert(io.open(path, "r"))
local content = f:read("*a")
f:close()

local chunk = load or loadstring
local fn = chunk(content:gsub('^%-%-[^\n]*\n', ''))
local native = fn()
print("stock help:", table.concat(native.help or {"<nil>"}, ","))
if native.help == nil then
    print("NOTE: sparse emission has no help key (help == stock). Injecting full list with doubled separator.")
    native.help = {
        "quickstart_guide", "----------------------------", "search_menu",
        "----------------------------", "----------------------------",
        "report_bug", "----------------------------", "system_statistics",
        "version", "about",
    }
end
-- inject the doubled separator AFTER position of first divider pair
local h = {}
for i, x in ipairs(native.help) do
    table.insert(h, x)
    if x == "----------------------------" and i == 2 then
        table.insert(h, "----------------------------")
    end
end
native.help = h
print("edited help:", table.concat(h, ","))

KoreaderAdapter.writeNativeOrder(view, native)
-- drop sidecar to force external classification? No - keep baseline; importExternalChanges path
Manager:reloadFromDisk(view)
Manager:saveOrder(view)
local out = Manager:loadOrder(view)
print("after save help:", table.concat(out.help or {}, ","))

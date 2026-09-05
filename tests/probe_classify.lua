-- Probe: what does classify_permutation say for the custom submenu case?
dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))
package.path = project_dir .. "/?.lua;" .. package.path
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
local _sd = DataStorage:getSettingsDir()
pcall(os.remove, _sd .. "/reorderingmenus_intent.lua")
pcall(os.remove, _sd .. "/reorderingmenus_materialization.lua")

package.path = "/Users/nr/Development/ReorderingMenus/?.lua;" .. package.path
local SD = require("lib.semantic_diff")

-- Simulated: baseline empty (new custom menu), proposed {"go_to"}
local kind, err = SD.classify_permutation({}, { "go_to" },
    { separator_aware = false })
print("empty->go_to kind:", kind and kind.kind or tostring(err))
if kind then print("  sequence:", table.concat(kind.sequence or {}, ",")) end

-- And the reverse (removal back to empty):
local kind2, err2 = SD.classify_permutation({ "go_to" }, {},
    { separator_aware = false })
print("go_to->empty kind:", kind2 and kind2.kind or tostring(err2))

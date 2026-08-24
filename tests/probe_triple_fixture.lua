-- Replay the promoted triple fixture step by step, dumping state.
package.path = "/Users/nr/Development/ReorderingMenus/?.lua;" .. package.path
dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
_ = require("gettext")
require("main")
local World = require("tests.lib.sm_world")

local w = World:new(375757)
local function dump(tag)
    local order = w:projection("reader")
    io.stderr:write(tag .. ": search_settings=[" ..
        table.concat(order.search_settings or {}, ",") .. "]\n")
    local IntentStore = require("reorderingmenus_intent_store")
    local sec = IntentStore.view("reader")
    local oo = sec.order_override and sec.order_override.search_settings
    io.stderr:write(tag .. ": order_override=" ..
        (oo and table.concat(oo, ",") or "nil") .. "\n")
end

dump("initial")
for i, entry in ipairs({
    { op = "reader_fm_switch", args = { view = "reader" } },
    { op = "stage_list_permutation", args = { menu = "search_settings",
        seq = { "fulltext_search_settings", "translation_settings",
            "dictionary_settings", "wikipedia_settings" } } },
    { op = "stage_list_permutation", args = { menu = "search_settings",
        seq = { "dictionary_settings", "wikipedia_settings",
            "translation_settings", "fulltext_search_settings" } } },
}) do
    local desc = w:replay(entry)
    io.stderr:write(string.format("step %d (%s): %s\n", i, entry.op,
        tostring(desc)))
    dump("  after" .. i)
end
io.stderr:write("check:\n")
local ok, failures = w:check()
if not ok then
    for _, f in ipairs(failures) do io.stderr:write("  FAIL " .. f .. "\n") end
else
    io.stderr:write("  clean\n")
end
os.exit(0)

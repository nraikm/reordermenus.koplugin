--[[--
probe_p4_migration.lua — why does the v0 fixture get quarantined?
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

local IntentStore = require("lib.intent_store")

-- Exactly the P4 v0 payload.
local v0 = {
    views = {
        filemanager = {
            hidden = { history = { origin = "main" } },
            hidden_order = { "history" },
            parent_override = { opds = { parent = "tools" } },
            order_override = { search =
                { "opds", "search_settings", "dictionary_lookup" } },
        },
        reader = {},
    },
    meta = { mirror_changes = false },
}

local problems = IntentStore.validateIntentState(v0)
print("PROBLEMS on raw v0 table:")
for _, p in ipairs(problems) do
    print(string.format("  kind=%s view=%s coll=%s key=%s detail=%s",
        tostring(p.kind), tostring(p.view), tostring(p.collection),
        tostring(p.key), tostring(p.detail)))
end
print("(end problems)")

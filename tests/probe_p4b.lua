--[[--
probe_p4b.lua — run the v0 load path directly and print problems.
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

local AtomicWriter = require("atomic_writer")
local IntentStore = require("intent_store")

local sd = DataStorage:getSettingsDir()
os.remove(sd .. "/reorderingmenus_intent.lua")

AtomicWriter.writeTable(sd .. "/reorderingmenus_intent.lua", {
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
})

-- validate the RAW table first (what collectShapeProblems sees pre-fill)
local raw_ok, raw = pcall(dofile, sd .. "/reorderingmenus_intent.lua")
print("loaded ok=" .. tostring(raw_ok) .. " type=" .. tostring(type(raw)))
if type(raw) == "table" then
    local problems = IntentStore.validateIntentState(raw)
    print("validateIntentState on RAW v0 table:")
    for _, p in ipairs(problems) do
        print(string.format("  kind=%s view=%s coll=%s key=%s detail=%s",
            tostring(p.kind), tostring(p.view), tostring(p.collection),
            tostring(p.key), tostring(p.detail)))
    end
end

local state, problems, backup = IntentStore.load(true)
print("load(): #problems=" .. #problems)
for _, p in ipairs(problems) do
    print(string.format("  kind=%s view=%s coll=%s key=%s detail=%s",
        tostring(p.kind), tostring(p.view), tostring(p.collection),
        tostring(p.key), tostring(p.detail)))
end
print("backup=" .. tostring(backup))

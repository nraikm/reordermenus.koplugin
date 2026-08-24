--[[--
probe_p4e.lua — which problem does the v0 file trigger at load time?
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

local AtomicWriter = require("reorderingmenus_atomic_writer")
local IntentStore = require("reorderingmenus_intent_store")
local lfs = require("libs/libkoreader-lfs")

local sd = DataStorage:getSettingsDir()
for entry in lfs.dir(sd) do
    if entry:find("^reorderingmenus") then os.remove(sd .. "/" .. entry) end
end
os.remove(sd .. "/filemanager_menu_order.lua")
os.remove(sd .. "/reader_menu_order.lua")

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

-- validate the RAW parsed table exactly as load() does pre-normalization
local raw = dofile(sd .. "/reorderingmenus_intent.lua")
local problems = IntentStore.validateIntentState(raw)
print("#problems on RAW v0 table = " .. #problems)
for _, p in ipairs(problems) do
    print(string.format("  kind=%s view=%s coll=%s key=%s detail=%s",
        tostring(p.kind), tostring(p.view), tostring(p.collection),
        tostring(p.key), tostring(p.detail)))
end

local state, problems2, backup = IntentStore.load(true)
print("#problems from load() = " .. #problems2)
for _, p in ipairs(problems2) do
    print(string.format("  kind=%s view=%s coll=%s key=%s detail=%s",
        tostring(p.kind), tostring(p.view), tostring(p.collection),
        tostring(p.key), tostring(p.detail)))
end
print("backup=" .. tostring(backup))
print("order_override.search[1]=" ..
    tostring(state.views.filemanager.order_override.search[1]))

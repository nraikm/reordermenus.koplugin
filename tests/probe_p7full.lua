--[[--
probe_p7full.lua — full projections for the partial-legacy-sequence cases.
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

local Manager = require("reorderingmenus_menuorder_manager")
local IntentStore = require("reorderingmenus_intent_store")
local NativeWriter = require("reorderingmenus_native_writer")
local UIScreens = require("reorderingmenus_ui_screens")

local sd = DataStorage:getSettingsDir()
local VIEW = "filemanager"
local AtomicWriter = require("reorderingmenus_atomic_writer")
local lfs = require("libs/libkoreader-lfs")

local function wipe()
    for _, f in ipairs({ VIEW .. "_menu_order.lua", "reader_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua",
        "reorderingmenus_state.lua" }) do os.remove(sd .. "/" .. f) end
    for entry in lfs.dir(sd) do
        if entry:find("^reorderingmenus_intent%.lua%.corrupt") then
            os.remove(sd .. "/" .. entry)
        end
    end
    Manager:dropSessionState(VIEW); Manager:dropSessionState("reader")
    IntentStore.load(true); NativeWriter._resetCaches()
end

local function launch()
    local ui = { menu = { registered_widgets = {} } }
    UIScreens:reconcileRegisteredItems({ ui = ui }, VIEW, false)
end

local function dump(tag)
    local out = {}
    for _, id in ipairs(Manager:getMenuItems(VIEW, "search")) do
        out[#out + 1] = id == "----------------------------" and "--" or id
    end
    print(tag .. ": " .. table.concat(out, " | "))
end

-- case A: P4-style 3-row override
wipe()
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
Manager:dropSessionState(VIEW); IntentStore.load(true); launch()
dump("A-proj")
-- note: opds has parent_override -> tools, so it leaves 'search' entirely.

-- case B: P7-style 5-row override, no parent overrides
wipe()
AtomicWriter.writeTable(sd .. "/reorderingmenus_intent.lua", {
    version = 2,
    views = {
        filemanager = {
            hidden = {}, hidden_order = {},
            parent_override = {}, position_override = {},
            order_override = { search =
                { "wikipedia_lookup", "opds", "search_settings",
                  "dictionary_lookup", "dictionary_lookup_history" } },
            custom_menus = {}, separators = {}, raw_override = {},
        },
        reader = {},
    },
    meta = { mirror_changes = false, hidden_in_place = true,
             generation = 0, view_generations = {} },
})
Manager:dropSessionState(VIEW); IntentStore.load(true); launch()
dump("B-proj")
Manager:dropSessionState(VIEW); IntentStore.load(true)
NativeWriter._resetCaches(); launch()
dump("B-restart")

-- case C: FULL override (what the importer/presets actually write today)
wipe()
local defaults = KoreaderAdapter_getDefaultOrder and nil
local full = {}
do
    local d = require("reorderingmenus_koreader_adapter").getDefaultOrder(VIEW)
    for _, id in ipairs(d.search or {}) do
        if id ~= "----------------------------" then full[#full + 1] = id end
    end
    -- curate: move wikipedia_lookup to front, opds second
    for i, id in ipairs(full) do
        if id == "wikipedia_lookup" then table.remove(full, i) break end
    end
    for i, id in ipairs(full) do
        if id == "opds" then table.remove(full, i) break end
    end
    table.insert(full, 1, "opds")
    table.insert(full, 2, "wikipedia_lookup")
end
AtomicWriter.writeTable(sd .. "/reorderingmenus_intent.lua", {
    version = 2,
    views = {
        filemanager = {
            hidden = {}, hidden_order = {},
            parent_override = {}, position_override = {},
            order_override = { search = full },
            custom_menus = {}, separators = {}, raw_override = {},
        },
        reader = {},
    },
    meta = { mirror_changes = false, hidden_in_place = true,
             generation = 0, view_generations = {} },
})
Manager:dropSessionState(VIEW); IntentStore.load(true); launch()
dump("C-proj")

wipe()
print("done")

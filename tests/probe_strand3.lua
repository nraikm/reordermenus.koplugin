-- Add the missing ingredient: an upstream_remove that deletes frontlight
-- from DEFAULTS while night_mode is hidden, then unhide (fuzzer's exact
-- step-42 shape: delete_native_file + plugin_install + hide_item).
dofile("/Applications/KOReader.app/Contents/koreader/setupkoenv.lua")
local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))
package.path = project_dir .. "/?.lua;" .. project_dir .. "/tests/?.lua;" .. package.path
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
G_reader_settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/settings.reader.lua")
G_defaults = require("luadefaults"):open()
local Device = require("device")
CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
local _ = require("gettext")
require("main")
local Manager = require("lib.menuorder_manager")
local IntentStore = require("lib.intent_store")
local KoreaderAdapter = require("lib.koreader_adapter")

local view = "filemanager"
local function fp(menu)
    local o = Manager:loadOrder(view)
    return table.concat(o[menu] or {}, ",")
end
local function restart()
    Manager:dropSessionState(view)
    IntentStore.load(true)
    require("lib.native_writer")._resetCaches()
end

print("baseline:", fp("setting"))

-- 1. remove frontlight from the DEFAULTS (upstream change; Device conditional)
local defaults = Manager:getDefaultOrder(view)
local dl = defaults.setting
for i, id in ipairs(dl) do
    if id == "frontlight" then table.remove(dl, i) break end
end
Manager.default_orders[view] = defaults

-- 2. delete native file + drop sessions (delete_native_file op)
os.remove(KoreaderAdapter.getNativePath(view))
restart()

-- 3. install a plugin item at setting tail, then hide it (hide_item)
Manager:setLiveRegistrations(view, {}, {})
Manager:setItemHidden(view, "night_mode", true, "setting")
Manager:saveOrder(view)
print("after hide:", fp("setting"))
for k, v in pairs(IntentStore.view(view).separators or {}) do
    print("  sep:", k, v.parent, tostring(v.after))
end

-- 4. UNHIDE in-session then round trip
Manager:setItemHidden(view, "night_mode", false)
Manager:saveOrder(view)
local before = fp("setting")
restart()
Manager:saveOrder(view)
Manager:reloadFromDisk(view)
local after = fp("setting")
print("B:", before)
print("A:", after)
print("STABLE:", before == after)

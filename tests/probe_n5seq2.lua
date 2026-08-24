-- probe_n5seq2.lua: faithful N5 reproduction with byte restoration
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
local VIEW, OTHER = "filemanager", "reader"
local function wipe_all()
    for _, f in ipairs({ VIEW.."_menu_order.lua", OTHER.."_menu_order.lua",
        "reorderingmenus_intent.lua", "reorderingmenus_materialization.lua" }) do
        os.remove(sd .. "/" .. f)
    end
    IntentStore.load(true); NativeWriter._resetCaches()
    Manager.recent_moves.filemanager = {}; Manager.recent_moves.reader = {}
    Manager:dropSessionState(VIEW); Manager:dropSessionState(OTHER)
end
local function launch(v)
    UIScreens:reconcileRegisteredItems({ ui = { menu = { registered_widgets = {} } } }, v, false)
end
local function read_f(name)
    local h = io.open(sd .. "/" .. name, "r")
    local b = h and h:read("*a"); if h then h:close() end
    return b
end
local function write_bytes(name, body)
    local h = io.open(sd .. "/" .. name, "w") h:write(body) h:close()
end
local function state(tag)
    local m = IntentStore.meta()
    print(("[%s] gen=%d fm=%s rd=%s"):format(tag, m.generation or -1,
        tostring(m.view_generations and m.view_generations.filemanager),
        tostring(m.view_generations and m.view_generations.reader)))
end

wipe_all(); launch(VIEW); launch(OTHER)

-- MONDAY: reader hide
Manager:setItemHidden(OTHER, "screensaver", true, "screen")
Manager:saveOrder(OTHER)
local rd_mon = read_f(OTHER .. "_menu_order.lua")
-- TUESDAY: FM hide -> capture intent
Manager:setItemHidden(VIEW, "screensaver", true, "screen")
Manager:saveOrder(VIEW)
local intent_tue = read_f("reorderingmenus_intent.lua")
-- WEDNESDAY: another FM hide -> capture sidecar
Manager:setItemHidden(VIEW, "calibre", true, "more_tools")
Manager:saveOrder(VIEW)
local side_wed = read_f("reorderingmenus_materialization.lua")
-- FRIDAY: FM move -> capture FM native
launch(VIEW)
Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
Manager:saveOrder(VIEW)
local fm_fri = read_f(VIEW .. "_menu_order.lua")
state("all eras saved")

print("==== assemble ====")
write_bytes("reorderingmenus_intent.lua", intent_tue)
write_bytes("reorderingmenus_materialization.lua", side_wed)
write_bytes(VIEW .. "_menu_order.lua", fm_fri)
write_bytes(OTHER .. "_menu_order.lua", rd_mon)

Manager:dropSessionState(VIEW); Manager:dropSessionState(OTHER)
IntentStore.load(true); NativeWriter._resetCaches()
state("restored")
launch(VIEW)
state("fm synced")
launch(OTHER)
state("rd synced")
print("FM opds:", Manager:getParentMenu(VIEW, "opds"))
print("FM screensaver hidden:", Manager:isItemHidden(VIEW, "screensaver"))
print("FM calibre hidden:", Manager:isItemHidden(VIEW, "calibre"))
print("RD screensaver hidden:", Manager:isItemHidden(OTHER, "screensaver"))
os.exit(0)

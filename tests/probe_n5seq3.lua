-- probe_n5seq3.lua: dump captured era bytes + post-sync intent detail
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
local function brief(body)
    return body and body:gsub("%s+", " "):gsub("%-%-[^\n]*", ""):sub(1, 400) or "(nil)"
end

wipe_all(); launch(VIEW); launch(OTHER)

-- pick reader item like the suite does: first of help/main/setting/screen
local reader_menu, reader_item
do
    local d = Manager:getDefaultOrder(OTHER)
    for _, menu_id in ipairs({ "help", "main", "setting", "screen" }) do
        local list = d[menu_id]
        if type(list) == "table" and #list > 0 then
            reader_menu, reader_item = menu_id, list[1]
            break
        end
    end
end
print("reader item:", reader_menu, reader_item)

Manager:setItemHidden(OTHER, reader_item, true, reader_menu)
Manager:saveOrder(OTHER)
local rd_mon = read_f(OTHER .. "_menu_order.lua")
Manager:setItemHidden(VIEW, "screensaver", true, "screen")
Manager:saveOrder(VIEW)
local intent_tue = read_f("reorderingmenus_intent.lua")
Manager:setItemHidden(VIEW, "calibre", true, "more_tools")
Manager:saveOrder(VIEW)
local side_wed = read_f("reorderingmenus_materialization.lua")
Manager:moveItemToMenu(VIEW, "opds", "search", "tools")
Manager:saveOrder(VIEW)
local fm_fri = read_f(VIEW .. "_menu_order.lua")

print("FRIDAY bytes:", brief(fm_fri))
print("WED sidecar has calibre:", side_wed:find("calibre") ~= nil)

write_bytes("reorderingmenus_intent.lua", intent_tue)
write_bytes("reorderingmenus_materialization.lua", side_wed)
write_bytes(VIEW .. "_menu_order.lua", fm_fri)
write_bytes(OTHER .. "_menu_order.lua", rd_mon)

Manager:dropSessionState(VIEW); Manager:dropSessionState(OTHER)
IntentStore.load(true); NativeWriter._resetCaches()
launch(VIEW)
local sec = IntentStore.view(VIEW)
print("POST-SYNC FM hidden:")
for k, v in pairs(sec.hidden) do print("   ", k, v.provider, v.origin) end
print("POST po.opds:", sec.parent_override.opds and sec.parent_override.opds.parent or "-")
launch(OTHER)
print("RD item hidden:", Manager:isItemHidden(OTHER, reader_item))
os.exit(0)

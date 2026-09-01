-- Reproduce seed 733103's exact taps_and_gestures divergence:
-- B (in-session): gm, go, menu_activate, [d], gesture_intervals, [d], ihc, sddt
-- A (fresh):      gm, go, menu_activate, gesture_intervals, [d], ihc, sddt, [d]
-- The in-session build has an EXTRA divider after menu_activate and misses
-- the trailing one. Defaults: ...,gesture_intervals,[d],ignore_hold_corners,
-- screen_disable_double_tap,[d] (trailing divider!). Note the stock list ends
-- with a divider.
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
local Manager = require("menuorder_manager")
local IntentStore = require("intent_store")

local view = "filemanager"
print("defaults taps:", table.concat(Manager:getDefaultOrder(view).taps_and_gestures or {}, ","))

-- Shape the world: hide gesture_manager+gesture_overview? No - replicate:
-- user moved menu_activate to position 3 (before gesture_intervals), and
-- everything after screen_disable_double_tap was hidden upstream, leaving a
-- TRAILING default divider. Hide nothing; just move one item then round-trip
-- with a trailing divider present in defaults.
local defaults = Manager:getDefaultOrder(view)
local dl = defaults.taps_and_gestures
-- remove trailing divider to emulate "menu continues past visible items"?
-- Actually keep it: simulate by hiding nothing but moving menu_activate up.
Manager:moveItem(view, "taps_and_gestures", 5, 3)   -- menu_activate to slot 3
Manager:saveOrder(view)
local o = Manager:loadOrder(view)
print("after move:", table.concat(o.taps_and_gestures or {}, ","))

--[[--
Helper module for mapping KOReader menu IDs, tab IDs, and submenu IDs
to user-friendly, localized display names and icons.
--]]

local _ = require("gettext")
local MenuSchema = require("reorderingmenus_menu_schema")

local MenuTitles = {}

MenuTitles.tab_info = {
    -- Reader view tabs
    navi = {
        title = _("Navigation"),
        icon = "appbar.navigation",
        description = _("Table of contents, bookmarks, skimming, page jumping"),
    },
    typeset = {
        title = _("Typeset"),
        icon = "appbar.typeset",
        description = _("Fonts, margins, typography, style tweaks, document settings"),
    },
    setting = {
        title = _("Settings"),
        icon = "appbar.settings",
        description = _("Device, network, screen, gestures, navigation settings"),
    },
    tools = {
        title = _("Tools"),
        icon = "appbar.tools",
        description = _("Reading statistics, export, calibre, plugins, more tools"),
    },
    search = {
        title = _("Search"),
        icon = "appbar.search",
        description = _("Dictionary lookup, Wikipedia, translation, fulltext search"),
    },
    filemanager = {
        title = _("File manager"),
        icon = "appbar.filebrowser",
        description = _("Return to file manager"),
    },
    main = {
        title = _("Main menu"),
        icon = "appbar.menu",
        description = _("History, favorites, help, updates, exit & power"),
    },

    -- File manager view tabs
    filemanager_settings = {
        title = _("File browser"),
        icon = "appbar.filebrowser",
        description = _("Display mode, sorting, filter, classic settings"),
    },
    plus_menu = {
        title = _("Plus menu"),
        icon = "appbar.plus",
        description = _("File browser shortcuts and actions"),
    },
}

MenuTitles.submenu_info = {
    navi_settings = {
        title = _("Navigation settings"),
        description = _("Table of contents display, dots, font size, page map"),
    },
    document = {
        title = _("Document settings"),
        description = _("Metadata location, auto-save, end-of-document action"),
    },
    device = {
        title = _("Device settings"),
        description = _("Keyboard layout, power timeouts, buttons, time & units"),
    },
    navigation = {
        title = _("Navigation & buttons"),
        description = _("Hardware keys, gestures, back button behavior"),
    },
    network = {
        title = _("Network"),
        description = _("Wi-Fi, proxy, SSH, sync connections"),
    },
    screen = {
        title = _("Screen"),
        description = _("Rotation, DPI, e-ink optimization, screensaver, timeout"),
    },
    taps_and_gestures = {
        title = _("Taps & gestures"),
        description = _("Gesture manager, page turns, double taps, corner taps"),
    },
    more_tools = {
        title = _("More tools"),
        description = _("Plugins, patch management, terminal, doc settings tweak"),
    },
    search_settings = {
        title = _("Search settings"),
        description = _("Dictionary, Wikipedia, translation settings"),
    },
    help = {
        title = _("Help"),
        description = _("Quickstart guide, menu search, version, bug report"),
    },
    exit_menu = {
        title = _("Exit & power"),
        description = _("Restart, sleep, power off, reboot, exit"),
    },
}

MenuTitles.items = {
    -- Navigation
    table_of_contents = _("Table of contents"),
    bookmarks = _("Bookmarks"),
    toggle_bookmark = _("Toggle bookmark"),
    bookmark_browsing_mode = _("Bookmark browsing mode"),
    hide_nonlinear_flows = _("Hide non-linear flows"),
    book_map = _("Book map"),
    page_browser = _("Page browser"),
    go_to = _("Go to page"),
    skim_to = _("Skim to"),
    autoturn = _("Auto turn"),
    go_to_previous_location = _("Go to previous location"),
    go_to_next_location = _("Go to next location"),

    -- Navigation settings
    toc_ticks_level_ignore = _("TOC ticks level to ignore"),
    toc_items_per_page = _("TOC items per page"),
    toc_items_font_size = _("TOC font size"),
    toc_items_show_chapter_length = _("Show chapter length in TOC"),
    toc_items_with_dots = _("TOC leader dots"),
    toc_alt_toc = _("Alternative TOC"),
    handmade_toc = _("Handmade TOC"),
    handmade_hidden_flows = _("Handmade hidden flows"),
    handmade_settings = _("Handmade settings"),
    page_map = _("Page map"),
    bookmarks_settings = _("Bookmarks settings"),

    -- Typeset
    document_settings = _("Document settings"),
    set_render_style = _("Render style"),
    style_tweaks = _("Style tweaks"),
    change_font = _("Font"),
    typography = _("Typography"),
    switch_zoom_mode = _("Zoom mode"),
    page_overlap = _("Page overlap"),
    speed_reading_module_perception_expander = _("Perception expander"),
    highlight_options = _("Highlight options"),
    selection_text = _("Select text"),
    panel_zoom_options = _("Panel zoom options"),
    djvu_render_mode = _("DjVu render mode"),
    start_content_selection = _("Start content selection"),

    -- Common settings
    frontlight = _("Frontlight"),
    night_mode = _("Night mode"),
    language = _("Language"),
    status_bar = _("Status bar"),
    partial_rerendering = _("Partial re-rendering"),

    -- Document submenu
    document_metadata_location = _("Document metadata location"),
    document_metadata_location_move = _("Move document metadata"),
    document_auto_save = _("Document auto-save"),
    document_end_action = _("Document end action"),
    language_support = _("Language support"),

    -- Device submenu
    keyboard_layout = _("Keyboard layout"),
    external_keyboard = _("External keyboard"),
    font_ui_fallbacks = _("Font UI fallbacks"),
    time = _("Time & date"),
    units = _("Units"),
    device_status_alarm = _("Device status alarm"),
    charging_led = _("Charging LED"),
    autostandby = _("Auto standby"),
    autosuspend = _("Auto suspend"),
    autoshutdown = _("Auto shutdown"),
    pageturn_power = _("Page turn key power"),
    ignore_sleepcover = _("Ignore sleep cover"),
    ignore_open_sleepcover = _("Ignore open sleep cover"),
    cover_events = _("Cover events"),
    ignore_battery_optimizations = _("Ignore battery optimizations"),
    mass_storage_settings = _("Mass storage settings"),
    file_ext_assoc = _("Associate file extensions"),
    screenshot = _("Take screenshot"),

    -- Navigation submenu
    back_to_exit = _("Back to exit"),
    back_in_filemanager = _("Back in file manager"),
    back_in_reader = _("Back in reader"),
    backspace_as_back = _("Backspace key as back"),
    physical_buttons_setup = _("Physical buttons setup"),
    android_volume_keys = _("Android volume keys"),
    android_haptic_feedback = _("Android haptic feedback"),
    android_back_button = _("Android back button"),
    opening_page_location_stack = _("Opening page location stack"),
    skim_dialog_position = _("Skim dialog position"),

    -- Network submenu
    network_wifi = _("Wi-Fi connection"),
    network_proxy = _("Network proxy"),
    network_powersave = _("Wi-Fi power save"),
    network_restore = _("Restore Wi-Fi connection"),
    network_info = _("Network information"),
    network_before_wifi_action = _("Action before Wi-Fi"),
    network_after_wifi_action = _("Action after Wi-Fi"),
    network_dismiss_scan = _("Dismiss Wi-Fi scan"),
    ssh = _("SSH server"),

    -- Screen submenu
    screensaver = _("Sleep screen / screensaver"),
    coverimage = _("Cover image"),
    autodim = _("Auto dim screen"),
    screen_rotation = _("Screen rotation"),
    screen_dpi = _("Screen DPI"),
    screen_eink_opt = _("E-ink screen refresh"),
    autowarmth = _("Auto warmth"),
    color_rendering = _("Color rendering"),
    screen_timeout = _("Screen timeout"),
    fullscreen = _("Full screen mode"),
    screen_notification = _("Screen notifications"),

    -- Taps and gestures submenu
    gesture_manager = _("Gesture manager"),
    gesture_overview = _("Gesture overview"),
    gesture_intervals = _("Gesture intervals"),
    ignore_hold_corners = _("Ignore corner holds"),
    screen_disable_double_tap = _("Disable double tap"),
    follow_links = _("Follow links"),
    menu_activate = _("Menu activation zone"),
    page_turns = _("Page turn gestures"),
    scrolling = _("Scrolling options"),
    long_press = _("Long press actions"),

    -- Tools tab
    read_timer = _("Reading timer"),
    calibre = _("Calibre"),
    exporter = _("Highlights and notes exporter"),
    statistics = _("Reading statistics"),
    progress_sync = _("Progress synchronization"),
    cloud_storage = _("Cloud storage"),
    move_to_archive = _("Move to archive"),
    wallabag = _("Wallabag"),
    news_downloader = _("News downloader"),
    text_editor = _("Text editor"),
    profiles = _("Profiles"),
    qrclipboard = _("QR clipboard"),

    -- More tools submenu
    auto_frontlight = _("Auto frontlight"),
    battery_statistics = _("Battery statistics"),
    book_shortcuts = _("Book shortcuts"),
    synchronize_time = _("Synchronize time"),
    keep_alive = _("Keep alive"),
    doc_setting_tweak = _("Document setting tweak"),
    terminal = _("Terminal emulator"),
    plugin_management = _("Plugin management"),
    patch_management = _("Patch management"),
    advanced_settings = _("Advanced settings"),
    developer_options = _("Developer options"),
    reordering_menus = _("Reorder menus"),
    reorderingmenus = _("Reorder menus"),

    -- Search tab
    dictionary_lookup = _("Dictionary lookup"),
    dictionary_lookup_history = _("Dictionary history"),
    vocabbuilder = _("Vocabulary builder"),
    wikipedia_lookup = _("Wikipedia lookup"),
    wikipedia_history = _("Wikipedia history"),
    translate_current_page = _("Translate page"),
    file_search = _("File search"),
    file_search_results = _("File search results"),
    find_book_in_calibre_catalog = _("Find in Calibre catalog"),
    fulltext_search = _("Fulltext search"),
    fulltext_search_findall_results = _("Fulltext search results"),
    bookmark_search = _("Bookmark search"),
    opds = _("OPDS catalog"),

    -- Search settings submenu
    dictionary_settings = _("Dictionary settings"),
    wikipedia_settings = _("Wikipedia settings"),
    translation_settings = _("Translation settings"),
    fulltext_search_settings = _("Fulltext search settings"),

    -- File manager settings tab
    filemanager_display_mode = _("Display mode"),
    filebrowser_settings = _("File browser settings"),
    show_filter = _("Filter files"),
    sort_by = _("Sort by"),
    reverse_sorting = _("Reverse sorting"),
    sort_mixed = _("Sort files and folders mixed"),
    start_with = _("Start with"),

    -- Main menu tab
    history = _("Reading history"),
    open_previous_document = _("Open previous document"),
    open_last_document = _("Open last document"),
    favorites = _("Favorites"),
    collections = _("Collections"),
    book_status = _("Book status"),
    book_info = _("Book info"),
    mass_storage_actions = _("Mass storage"),
    ota_update = _("Check for updates"),

    -- Help submenu
    quickstart_guide = _("Quickstart guide"),
    search_menu = _("Menu search"),
    report_bug = _("Report bug"),
    system_statistics = _("System statistics"),
    version = _("Version info"),
    about = _("About KOReader"),

    -- Exit menu submenu
    restart_koreader = _("Restart KOReader"),
    sleep = _("Sleep / Suspend"),
    poweroff = _("Power off"),
    reboot = _("Reboot device"),
    start_bq = _("Start BQ reader"),
    exit = _("Exit KOReader"),
}

local function humanize(id)
    if not id or type(id) ~= "string" then return tostring(id) end
    local words = {}
    for word in id:gmatch("[^_]+") do
        local capitalized = word:sub(1, 1):upper() .. word:sub(2):lower()
        table.insert(words, capitalized)
    end
    return table.concat(words, " ")
end

function MenuTitles:getTitle(id, live_menu_items)
    if id == MenuSchema.SEPARATOR_ID or id == "separator" then
        return _("--- Separator ---")
    end

    if self.tab_info[id] then
        return self.tab_info[id].title
    end

    if self.submenu_info[id] then
        return self.submenu_info[id].title
    end

    if self.items[id] then
        return self.items[id]
    end

    -- Try to inspect live menu item if available
    if live_menu_items and live_menu_items[id] then
        local it = live_menu_items[id]
        if it.text then
            return it.text
        elseif it.text_func then
            local ok, str = pcall(it.text_func)
            if ok and str then return str end
        end
    end

    return humanize(id)
end

function MenuTitles:getIcon(id)
    if self.tab_info[id] and self.tab_info[id].icon then
        return self.tab_info[id].icon
    end
    return nil
end

function MenuTitles:getDescription(id)
    if self.tab_info[id] and self.tab_info[id].description then
        return self.tab_info[id].description
    end
    if self.submenu_info[id] and self.submenu_info[id].description then
        return self.submenu_info[id].description
    end
    return nil
end

function MenuTitles:isSubmenu(id)
    return self.submenu_info[id] ~= nil
end

function MenuTitles:isTab(id)
    return self.tab_info[id] ~= nil
end

return MenuTitles

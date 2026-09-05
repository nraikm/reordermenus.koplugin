-- Probe: revert via simpler approach — restore the original block text.
local project_dir = "/Users/nr/Development/ReorderingMenus"
local function read(p)
    local f = io.open(p, "r"); if not f then return nil end
    local c = f:read("*a"); f:close(); return c
end
local function write(p, c)
    local f = assert(io.open(p, "wb")); f:write(c); f:close()
end
local mpath = project_dir .. "/lib/materializer.lua"
local orig = read(mpath)
-- Replace the whole modified loop with the original single-line body.
local start_marker = [[    local lists = {}]]
local end_marker = [[    end

    local custom_titles]]
local i = orig:find(start_marker, 1, true)
assert(i, "start not found")
local j = orig:find(end_marker, i, true)
assert(j, "end not found")
local restored_block = [[    local lists = {}
    local empty_members = {}
    for _, menu_id in ipairs(sortedKeys(universe)) do
        lists[menu_id] = assembleMenuList(reg, intent, menu_id,
            members[menu_id] or empty_members, hidden, customs,
            prev_lists and prev_lists[menu_id] or nil)
    end

]]
write(mpath, orig:sub(1, i - 1) .. restored_block .. orig:sub(j + #end_marker))
print("reverted; collapse occurrences now:",
    select(2, read(mpath):gsub("Collapse adjacent", "")))

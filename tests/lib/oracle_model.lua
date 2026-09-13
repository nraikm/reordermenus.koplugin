--[[--
oracle_model.lua — INDEPENDENT behavioral oracle for menu customization.

Deliberately imports NOTHING from production code (no lib.* requires): it is
a small WYSIWYG model of user-visible semantics written directly against the
problem statement. Property tests drive the SAME operation script through
this model and through production (Manager verbs) and compare user-visible
outcomes after every commit + restart:

  state per view:
    lists   menu -> ordered rows (plain ids; "---" divider rows are data)
    home    id -> menu (explicit placement; custom containers included)
    hidden  id -> origin menu hidden FROM (per-id invisibility + restore
            origin, mirroring hidden records; presence = hidden)
    down    set of ids whose provider is absent (filtered, memory kept)
    customs set of user-created container ids

  ops mutate rows EXACTLY as arranged (ground truth, no inference):
    move_in_menu(menu, from_idx, to_idx)   row splice, dividers stay
    move_cross(id, dest, idx)              reparent + splice at index
    hide(id) / unhide(id)                  set membership
    add_divider(menu, idx) / del_divider(menu, idx)
    clear_dividers(menu)                   remove all "---" rows
    provider_down(id) / provider_up(id)    applicability filter
    reset_item(id)                         home=default, unhide
    reset_menu(menu)                       rows back to construction order,
                                           unhide members, drop customs inside
    create_submenu(menu, id, idx)          custom container + row
    restart()                              deep-copy round trip (stateless by
                                           construction; asserts serializability)

  queries (user-visible):
    visible_items(menu)  rows minus hidden minus down (dividers kept)
    anchors(menu)        divider anchors like production (preceding id/false)
    is_hidden(id), parent_of(id)

Where the oracle INTENTIONALLY differs from production (documented, not
defects): stock-default following (oracle has no upstream; menus start as
given and never change underneath), sparse-vs-complete storage (oracle stores
rows; production stores intent), minimized-vs-litter records. The compared
surface is strictly user-visible: per-menu visible order, divider anchors,
hidden membership, and restart/provider stability.
--]]

local Oracle = {}
Oracle.__index = Oracle

local SEP = "----------------------------"
Oracle.SEP = SEP

function Oracle.new(menus)
    local self = setmetatable({}, Oracle)
    self.lists = {}
    self.home = {}
    self.default_home = {}
    self.default_rows = {}
    self.hidden = {}
    self.down = {}
    self.customs = {}
    for menu, rows in pairs(menus or {}) do
        self.lists[menu] = {}
        for _, id in ipairs(rows) do
            self.lists[menu][#self.lists[menu] + 1] = id
            if id ~= SEP then
                self.home[id] = menu
                self.default_home[id] = menu
            end
        end
        self.default_rows[menu] = self:copy_list(self.lists[menu])
    end
    return self
end

function Oracle:copy_list(rows)
    local out = {}
    for _, id in ipairs(rows or {}) do out[#out + 1] = id end
    return out
end

function Oracle:members(menu)
    local out = {}
    for id, home in pairs(self.home) do
        if home == menu and not self.hidden[id] and not self.down[id] then
            out[#out + 1] = id
        end
    end
    return out
end

function Oracle:visible_items(menu)
    local out = {}
    for _, id in ipairs(self.lists[menu] or {}) do
        if id == SEP then
            out[#out + 1] = id
        elseif not self.hidden[id] and not self.down[id] then
            out[#out + 1] = id
        end
    end
    return out
end

function Oracle:anchors(menu)
    local out, prev = {}, false
    for _, id in ipairs(self:visible_items(menu)) do
        if id == SEP then out[#out + 1] = prev
        else prev = id end
    end
    return out
end

function Oracle:is_hidden(id) return self.hidden[id] ~= nil end
function Oracle:hidden_origin(id) return self.hidden[id] end
function Oracle:parent_of(id) return self.home[id] end

function Oracle:move_in_menu(menu, from_idx, to_idx)
    local rows = self.lists[menu]
    if type(rows) ~= "table" then return false end
    if from_idx < 1 or from_idx > #rows or to_idx < 1 or to_idx > #rows then
        return false
    end
    local row = table.remove(rows, from_idx)
    table.insert(rows, to_idx, row)
    return true
end

function Oracle:move_cross(id, dest, idx)
    if id == SEP or self.lists[dest] == nil then return false end
    -- A container cannot move into itself or its descendant (oracle-level
    -- cycle guard, mirroring the validated-mirror rule).
    if id == dest then return false end
    if self.lists[id] ~= nil then
        local seen, stack = {}, { id }
        while #stack > 0 do
            local cur = table.remove(stack)
            if not seen[cur] then
                seen[cur] = true
                for _, row in ipairs(self.lists[cur] or {}) do
                    if row == dest then return false end
                    if self.lists[row] then stack[#stack + 1] = row end
                end
            end
        end
    end
    local src = self.home[id]
    if src ~= nil then
        for i, row in ipairs(self.lists[src] or {}) do
            if row == id then table.remove(self.lists[src], i) break end
        end
    end
    self.home[id] = dest
    self.hidden[id] = nil
    local rows = self.lists[dest]
    if dest == self.default_home[id] then
        -- Homecoming without an explicit slot (walk appends only): mirrors
        -- slot-alignment of anchor-free placement at the default home.
        table.insert(rows, self:slot_position(dest, id), id)
        return true
    end
    -- Anchor-free arrivals elsewhere slot-align at the tail (foreigner
    -- append); the walk only uses tail appends.
    idx = idx or (#rows + 1)
    if idx < 1 then idx = 1 end
    if idx > #rows + 1 then idx = #rows + 1 end
    table.insert(rows, idx, id)
    return true
end

function Oracle:hide(id, origin)
    if id == SEP then return false end
    self.hidden[id] = origin or self.home[id] or true
    return true
end

function Oracle:unhide(id)
    -- Slot-derived restoration (mirrors merge: drop, then slot-derive among
    -- current rows). Callers restore only when no anchors are homed to the
    -- menu (see test guards); then merge slot IS the answer and in-place
    -- return would wrongly freeze pre-hide neighbor positions.
    local home = self.home[id]
    if home ~= nil then
        for i, row in ipairs(self.lists[home] or {}) do
            if row == id then table.remove(self.lists[home], i) break end
        end
    end
    self.hidden[id] = nil
    if home ~= nil then
        self.lists[home] = self.lists[home] or {}
        table.insert(self.lists[home], self:slot_position(home, id), id)
    end
    return true
end

-- Merge-slot derivation (mirrors stock slot-alignment WITHOUT anchors):
-- position of id among currently listed default residents of home, following
-- production's insertAtStockSlot preference (first present FOLLOWING default
-- sibling, else nearest present preceding one, else append). Extras (ids in
-- no default list) slot-align at the tail. Hidden/down rows never anchor.
-- Used by reset_item/unhide so restoration matches slot derivation instead
-- of naive in-place return (neighbors may have moved on).
function Oracle:slot_position(home, id)
    local rows = self.lists[home] or {}
    local def = self.default_rows[home] or {}
    local dipos
    for i, row in ipairs(def) do
        if row == id then dipos = i break end
    end
    if dipos == nil then return #rows + 1 end
    local defset = {}
    for _, row in ipairs(def) do defset[row] = true end
    local function present(cand)
        if cand == SEP or not defset[cand] then return nil end
        if self.hidden[cand] or self.down[cand] then return nil end
        for j, row in ipairs(rows) do
            if row == cand then return j end
        end
        return nil
    end
    for i = dipos + 1, #def do
        local cand = def[i]
        if cand ~= SEP then
            local j = present(cand)
            if j then return j end
        end
    end
    for i = dipos - 1, 1, -1 do
        local cand = def[i]
        if cand ~= SEP then
            local j = present(cand)
            if j then return j + 1 end
        end
    end
    return #rows + 1
end

function Oracle:add_divider(menu, idx)
    local rows = self.lists[menu]
    if type(rows) ~= "table" then return false end
    if idx < 1 then idx = 1 end
    if idx > #rows + 1 then idx = #rows + 1 end
    table.insert(rows, idx, SEP)
    return true
end

function Oracle:del_divider(menu, idx)
    local rows = self.lists[menu]
    if type(rows) ~= "table" or rows[idx] ~= SEP then return false end
    table.remove(rows, idx)
    return true
end

function Oracle:clear_dividers(menu)
    local rows = self.lists[menu]
    if type(rows) ~= "table" then return false end
    local kept = {}
    for _, id in ipairs(rows) do
        if id ~= SEP then kept[#kept + 1] = id end
    end
    self.lists[menu] = kept
    return true
end

function Oracle:provider_down(id) self.down[id] = true end
function Oracle:provider_up(id) self.down[id] = nil end

function Oracle:reset_item(id)
    self.hidden[id] = nil
    local home = self.default_home[id]
    if home == nil then return end
    -- Return to the merge slot like production's pinned-then-pruned restore:
    -- drop from wherever listed, then slot-derive (following-first, so hidden
    -- rows don't shift it); live-only extras slot-align at the tail.
    -- Callers run this only anchor-free for id (see test guards): with no
    -- surviving anchors, merge slot IS the answer.
    local cur = self.home[id]
    if cur ~= nil then
        for i, row in ipairs(self.lists[cur] or {}) do
            if row == id then table.remove(self.lists[cur], i) break end
        end
    end
    self.home[id] = home
    self.lists[home] = self.lists[home] or {}
    table.insert(self.lists[home], self:slot_position(home, id), id)
end

function Oracle:reset_menu(menu)
    local def = self.default_rows[menu]
    if def == nil then return false end
    self.lists[menu] = self:copy_list(def)
    for id, home in pairs(self.home) do
        if home == menu and self.default_home[id] ~= menu then
            self.home[id] = self.default_home[id]
        end
    end
    -- Ids homed here by default but listed nowhere (live-only rows such as
    -- p, whose construction rows predate them): restore at the tail,
    -- matching slot-aligned resolution of record-free state. Without this
    -- they orphan (homed but unlisted) and silently vanish.
    local listed = {}
    for _, rows in pairs(self.lists) do
        for _, row in ipairs(rows) do listed[row] = true end
    end
    local missing = {}
    for id, home in pairs(self.home) do
        if home == menu and self.default_home[id] == menu and not listed[id] then
            missing[#missing + 1] = id
        end
    end
    table.sort(missing)
    for _, id in ipairs(missing) do
        table.insert(self.lists[menu], id)
    end
    -- Unhide exactly what production's submenu reset unhides: hidden entries
    -- whose origin is this menu, plus hidden entries for this menu's default
    -- children (clearItem drops those records regardless of origin).
    do
        local defset = {}
        for _, row in ipairs(def) do defset[row] = true end
        for id, origin in pairs(self.hidden) do
            if origin == menu or defset[id] then self.hidden[id] = nil end
        end
    end
    return true
end

function Oracle:create_submenu(menu, id, idx)
    if self.lists[menu] == nil or self.lists[id] ~= nil then return false end
    self.lists[id] = {}
    self.customs[id] = true
    self.home[id] = menu
    local rows = self.lists[menu]
    idx = idx or (#rows + 1)
    table.insert(rows, math.max(1, math.min(idx, #rows + 1)), id)
    return true
end

-- Restart: serialize + rebuild (stateless by construction). Returns a fresh
-- oracle with identical user-visible state; any divergence here is an oracle
-- bug, not production behavior.
function Oracle:restart()
    local menus = {}
    for menu, rows in pairs(self.lists) do menus[menu] = self:copy_list(rows) end
    local fresh = Oracle.new({})
    fresh.lists = menus
    fresh.home = {}
    fresh.default_home = {}
    for k, v in pairs(self.home) do fresh.home[k] = v end
    for k, v in pairs(self.default_home) do fresh.default_home[k] = v end
    fresh.default_rows = {}
    for k, v in pairs(self.default_rows) do fresh.default_rows[k] = self:copy_list(v) end
    for k, v in pairs(self.hidden) do fresh.hidden[k] = v end
    for k, v in pairs(self.down) do fresh.down[k] = v end
    for k, v in pairs(self.customs) do fresh.customs[k] = v end
    return fresh
end

return Oracle

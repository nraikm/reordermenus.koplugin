--[[--
resolver.lua — ONE resolver owning effective invariants (Prompt 3 Part B/D).

Target model:

  native snapshot + saved intent
              ↓
        optional draft
              ↓
          resolver
              ↓
       effective model

`Resolver.resolve(reg, intent_or_draft)` composes PURE helpers (no god
object, no I/O, no mutation of saved intent):

  Materializer.resolve  history-free placement/ordering/dividers/customs
  Validator.validate    deterministic structural repairs (single parent, no
                        cycles, hidden containment, nested-tab safety,
                        unreachable cascade, protected items, non-empty bar)
  Visibility.status     per-id reason (visible / explicitly_hidden /
                        hidden_by_ancestor / unplaced / provider_absent)

Effective model (single source for editors, native projection, visibility
explanations, validation diagnostics):

  {
    tabs = {...}, lists = {...}, disabled = {...}, custom_titles = {...},
    unplaced = {...},
    owner = { [id] = menu_id },            -- one effective parent per row
    parents = { [id] = menu_id },           -- alias of owner (renderable ids)
    parent_index = { [id] = index },        -- 1-based index within owner list
    visibility = { [id] = { state=..., ancestor=..., path=..., ... } },
    diagnostics = { warnings = {...} },     -- validator repairs + notes
    provenance = { hidden_applies = {...} },-- applicability where UI needs it
  }

Invariants enforced once, here (not downstream):
  one effective parent per rendered item, no duplicate rendered occurrence,
  no effective container cycle, valid/reachable tabs, hidden containment,
  explicit vs ancestor-hidden distinction, provider-absent dormancy,
  unknown survival, determinism, resolver never mutates saved intent.

Invalid imported intent is never destroyed to produce a valid projection:
the input section is deep-copied before resolve/validate (when the caller
passes its live staging table, Resolver must not mutate it); the effective
output is always valid; diagnostics explain repairs. New editor commands
(IntentionOps) are validated via Placement before staging invalid structures.
--]]

local Materializer = require("lib.materializer")
local Validator = require("lib.validator")
local Visibility = require("lib.visibility")
local MenuSchema = require("lib.menu_schema")

local Resolver = {}

local function deepCopy(t, seen)
  if type(t) ~= "table" then return t end
  seen = seen or {}
  if seen[t] then return seen[t] end
  local c = {}
  seen[t] = c
  for k, v in pairs(t) do c[deepCopy(k, seen)] = deepCopy(v, seen) end
  return c
end

local function sortedKeys(t)
  local ks = {}
  for k in pairs(t or {}) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
  return ks
end

--- resolve(reg, intent_or_draft [, opts]) -> effective, diagnostics.
--- opts.include_ids (array) forces visibility computation for ids that have
--- no references in this view (e.g. cross-view provider_absent queries like
--- "does FM know reader-only id?"). Without it, visibilityOf falls back to
--- UNPLACED for unmapped ids, which misreports truly absent ids that have no
--- claims here (they must be provider_absent, not unplaced).
--- Never mutates its inputs (deep-copies the intent section for the
--- validator's benefit; Materializer/Validator are pure over their args but
--- Validator repairs a COPY of the graph — the intent table itself is never
--- written here).
function Resolver.resolve(reg, intent_or_draft, opts)
  reg = reg or { menus = {}, nodes = {}, tab_list = {} }
  local intent = intent_or_draft or Materializer.emptyIntent()
  -- Work on a copy so resolve never mutates saved/staged intent even if a
  -- future helper writes into it by accident (crash-safe persistence relies
  -- on intent tables only changing through transactions).
  local intent_copy = deepCopy(intent)
  local graph = Materializer.resolve(reg, intent_copy)
  local _, repaired, warnings = Validator.validate(graph, reg, intent_copy)
  -- Ownership: one effective parent per rendered row + index.
  local owner, parent_index = {}, {}
  for _, menu_id in ipairs(sortedKeys(repaired.lists)) do
    local list = repaired.lists[menu_id] or {}
    for idx, id in ipairs(list) do
      if id ~= MenuSchema.SEPARATOR_ID and owner[id] == nil then
        owner[id] = menu_id
        parent_index[id] = idx
      end
    end
  end
  -- Visibility reasons for every id the world knows about (renderable +
  -- dormant + unknown referenced by intent). Computed ONCE here; downstream
  -- must NOT reconstruct reasons independently (Part D).
  local visibility = {}
  do
    local ids = {}
    for id in pairs(reg.nodes or {}) do ids[id] = true end
    if type(intent_copy.custom_menus) == "table" then
      for id in pairs(intent_copy.custom_menus) do ids[id] = true end
    end
    for _, coll in ipairs({ "hidden", "parent_override", "position_override" }) do
      local c = intent_copy[coll]
      if type(c) == "table" then for id in pairs(c) do ids[id] = true end end
    end
    if type(intent_copy.order_override) == "table" then
      for _, rec in pairs(intent_copy.order_override) do
        if type(rec) == "table" and type(rec.entries) == "table" then
          for _, e in ipairs(rec.entries) do
            local eid = MenuSchema.entryId(e)
            if eid and eid ~= MenuSchema.SEPARATOR_ID then ids[eid] = true end
          end
        end
      end
    end
    for _, id in ipairs(repaired.disabled or {}) do ids[id] = true end
    for _, id in ipairs(repaired.unplaced or {}) do ids[id] = true end
    for _, id in ipairs(repaired.tabs or {}) do ids[id] = true end
    if type(opts) == "table" and type(opts.include_ids) == "table" then
      for _, id in ipairs(opts.include_ids) do
        if type(id) == "string" then ids[id] = true end
      end
    end
    for id in pairs(ids) do
      if type(id) == "string" then
        local ok, st = pcall(Visibility.status, reg, intent_copy, graph, repaired, id)
        if ok and type(st) == "table" and st.state then
          visibility[id] = st
        else
          visibility[id] = { state = Visibility.STATES.UNPLACED, id = id }
        end
      end
    end
  end
  local effective = {
    tabs = repaired.tabs,
    lists = repaired.lists,
    disabled = repaired.disabled,
    custom_titles = repaired.custom_titles,
    unplaced = repaired.unplaced,
    owner = owner,
    parents = owner,
    parent_index = parent_index,
    visibility = visibility,
    diagnostics = { warnings = warnings or {} },
    provenance = {},
  }
  -- Applicability provenance where UI requires it (hidden applies?).
  do
    local applies = {}
    if type(intent_copy.hidden) == "table" then
      for id in pairs(intent_copy.hidden) do
        applies[id] = Materializer.hiddenApplies(reg, intent_copy, id)
      end
    end
    effective.provenance.hidden_applies = applies
  end
  return effective, effective.diagnostics
end

--- Convenience: visibility reason for one id from an effective model
--- (no re-derivation; falls back to unplaced for unknown ids).
function Resolver.visibilityOf(effective, id)
  if type(effective) == "table" and type(effective.visibility) == "table" then
    local st = effective.visibility[id]
    if type(st) == "table" and st.state then return st end
  end
  return { state = Visibility.STATES.UNPLACED, id = id }
end

return Resolver

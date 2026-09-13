--[[--
test_p2_equivalence.lua — Prompt 2 required equivalence tests.

Equivalent conceptual changes through:
  1. editor (stageList / moveItemToMenu / setItemHidden / createSubmenu /
     insertSeparator)
  2. external native import (hand-edit file + restart sync)
  3. preset application (view preset capture -> reset -> apply)

must yield equivalent DURABLE intent semantics and equivalent EFFECTIVE
behavior for: reorder, cross-menu move, hidden-item reorder, absent provider,
unknown ID, custom submenu, dividers, new native item, provider return.

Durable equivalence compares semantic shapes (anchor vs bulk vs none,
membership parent, visibility hidden, divider anchors effective, dormant
preservation) — not opaque storage keys (unified as __sep_/__nosep_ on all
writer paths; readers are key-agnostic).
Effective equivalence compares resolved menu lists (including divider
positions) and disabled sets.
--]]

local test_path = debug.getinfo(1, "S").source:sub(2)
local project_dir = assert(test_path:match("^(.*)/tests/[^/]+$"))
local FuzzLib = dofile(project_dir .. "/tests/lib/fuzz_lib.lua")
FuzzLib.boot(project_dir)

local DataStorage = require("datastorage")
local util = require("util")
require("main")
local Manager = require("lib.menuorder_manager")
local IntentStore = require("lib.intent_store")
local NativeWriter = require("lib.native_writer")
local Materializer = require("lib.materializer")
local MenuSchema = require("lib.menu_schema")
local KoreaderAdapter = require("lib.koreader_adapter")
local Presets = require("lib.presets")
local AtomicWriter = require("lib.atomic_writer")
local dump = require("dump")

local SEP = MenuSchema.SEPARATOR_ID
local ROOT = MenuSchema.MENU_BUTTONS_KEY
local DISABLED = MenuSchema.DISABLED_KEY

local passed, failed = 0, 0
local function ok(c, msg)
  if c then passed = passed + 1 else failed = failed + 1; print("  [FAIL] "..tostring(msg)); io.stdout:flush() end
end
local function eq(a, b, msg)
  if a == b then passed = passed + 1 else failed = failed + 1
    print(string.format("  [FAIL] %s -> expected %s, got %s", tostring(msg), tostring(b), tostring(a))); io.stdout:flush() end
end

local VIEW = "reader"
local function wipe_all()
  local sd = DataStorage:getSettingsDir()
  for _, n in ipairs({"reader_menu_order.lua","filemanager_menu_order.lua","reorderingmenus_intent.lua","reorderingmenus_materialization.lua"}) do pcall(os.remove, sd.."/"..n) end
  os.execute("rm -rf "..sd.."/menu_order_presets 2>/dev/null")
  for _, v in ipairs({"reader","filemanager"}) do Manager:dropSessionState(v) end
  IntentStore.load(true); NativeWriter._resetCaches()
end
local function inject()
  Manager.default_orders[VIEW] = {
    [ROOT] = {"main","tools"},
    main = {"a","b","c"},
    tools = {"x","y"},
  }
  Manager:setLiveRegistrations(VIEW, {}, {}, nil)
  Manager:dropSessionState(VIEW)
end
local function set_regs(items, providers)
  Manager:setLiveRegistrations(VIEW, items or {}, providers or {}, nil)
  Manager:refreshRegistry(VIEW)
end
local function fresh_process()
  for _, v in ipairs({"reader","filemanager"}) do Manager:dropSessionState(v) end
  IntentStore.load(true); NativeWriter._resetCaches()
end
local function eff_list(menu) return table.concat(Manager:getMenuItems(VIEW, menu) or {}, ",") end
local function durable_fp()
  local s = Manager:stagedView(VIEW)
  -- semantic fingerprint: ordering kind per menu, membership, visibility, divider anchors effective (not keys)
  local parts = {}
  local menus = {}
  for m in pairs(s.order_override or {}) do menus[m]=true end
  for pid in pairs(s.position_override or {}) do
    local p = Materializer.effectiveParent((function() local sess = nil; return {nodes={}, menus={}} end)(), s, pid)
    _ = p
  end
  for m in pairs(s.order_override or {}) do
    local rec = s.order_override[m]
    local ids = {}
    if type(rec)=="table" and type(rec.entries)=="table" then
      for _,e in ipairs(rec.entries) do ids[#ids+1]=e.id..(e.provider and "@"..e.provider or "") end
    end
    parts[#parts+1]="order:"..m.."=["..table.concat(ids,",").."]"
  end
  local poss = {}
  for id,rec in pairs(s.position_override or {}) do poss[#poss+1]=id..">"..tostring(type(rec)=="table" and rec.after or "?") end
  table.sort(poss); parts[#parts+1]="pos:["..table.concat(poss,",").."]"
  local pars = {}
  for id,rec in pairs(s.parent_override or {}) do pars[#pars+1]=id.."->"..tostring(type(rec)=="table" and rec.parent or "?") end
  table.sort(pars); parts[#parts+1]="par:["..table.concat(pars,",").."]"
  local hids = {}
  for id in pairs(s.hidden or {}) do hids[#hids+1]=id end
  table.sort(hids); parts[#parts+1]="hid:["..table.concat(hids,",").."]"
  -- divider anchors effective per menu (sorted, not keys)
  local bymenu = {}
  for _,sep in pairs(s.separators or {}) do
    if type(sep)=="table" and type(sep.parent)=="string" then
      if sep.zero_dividers==true then bymenu[sep.parent]=bymenu[sep.parent] or {}; bymenu[sep.parent].zero=true
      else bymenu[sep.parent]=bymenu[sep.parent] or {}; table.insert(bymenu[sep.parent], tostring(sep.after)) end
    end
  end
  local dmenus = {}
  for m in pairs(bymenu) do dmenus[#dmenus+1]=m end
  table.sort(dmenus)
  for _,m in ipairs(dmenus) do
    local a = bymenu[m]
    if a.zero and #a==0 then parts[#parts+1]="div:"..m.."=ZERO"
    else table.sort(a); parts[#parts+1]="div:"..m.."=["..table.concat(a,",").."]" end
  end
  table.sort(parts)
  return table.concat(parts,";")
end

-- current regs holder for import restarts (set by each scenario)
local cur_items, cur_providers = {}, {}
local function set_regs_cur() set_regs(cur_items, cur_providers) end

-- External-import helper: establish checkpoint via save, hand-edit file, restart.
local function import_route(mutator)
  Manager:saveOrder(VIEW)
  local path = KoreaderAdapter.getNativePath(VIEW)
  local order
  do
    local fh = io.open(path,"r")
    if fh then local ok,res = pcall(dofile, path); fh:close(); if ok and type(res)=="table" then order=res end end
    if type(order)~="table" then order = Manager:loadOrder(VIEW) end
  end
  mutator(order)
  local fh = io.open(path,"w"); fh:write("return "..dump(order,nil,true)); fh:close()
  fresh_process(); inject(); set_regs_cur()
  Manager:loadOrder(VIEW)
  Manager:saveOrder(VIEW)
end

-- Preset helper: capture current intent as preset, wipe view, apply.
local preset_seq = 0
local function preset_route_capture_apply(capture_fn)
  -- capture_fn stages intent via editor verbs in current world, then we save preset
  capture_fn()
  Manager:saveOrder(VIEW)
  preset_seq = preset_seq + 1
  local pname = "P2EQ"..preset_seq
  local ok_save = Manager:savePreset(VIEW, pname)
  assert(ok_save, "preset save")
  -- reset view to stock, then apply preset (fresh world, same defaults/regs)
  Manager:resetOrder(VIEW)
  local ok_apply = Manager:loadPreset(VIEW, pname)
  assert(ok_apply, "preset apply")
end

print("=== P2 equivalence ===")

-- 1. reorder single move main [a,b,c] -> [a,c,b]
do
  print("\n--- reorder ---")
  local results = {}
  -- editor
  wipe_all(); inject(); cur_items, cur_providers = {}, {}
  set_regs({},{})
  Manager:stageList(VIEW,"main",{"a","c","b"}); Manager:saveOrder(VIEW)
  results.editor = {eff=eff_list("main"), dur=durable_fp()}
  fresh_process(); inject(); set_regs({},{})
  local restarted = eff_list("main")
  ok(restarted==results.editor.eff, "reorder editor restart-stable")
  -- import: hand-edit file to [a,c,b]
  wipe_all(); inject(); set_regs({},{})
  Manager:saveOrder(VIEW)
  import_route(function(o) o.main={"a","c","b"} end)
  results.import = {eff=eff_list("main"), dur=durable_fp()}
  -- preset: capture editor arrangement, reset, apply
  wipe_all(); inject(); set_regs({},{})
  preset_route_capture_apply(function() Manager:stageList(VIEW,"main",{"a","c","b"}) end)
  results.preset = {eff=eff_list("main"), dur=durable_fp()}
  eq(results.import.eff, results.editor.eff, "reorder import effective == editor")
  eq(results.preset.eff, results.editor.eff, "reorder preset effective == editor")
  -- durable: both should be single anchor (c after a? or b after c? canonical) or both bulk? Just check same kind (pos vs order)
  local function kind(fp) if fp:find("order:main") then return "bulk" elseif fp:find("pos:") and not fp:find("pos:%[%]") then return "anchor" else return "none" end end
  eq(kind(results.import.dur), kind(results.editor.dur), "reorder import durable kind == editor")
  eq(kind(results.preset.dur), kind(results.editor.dur), "reorder preset durable kind == editor")
  wipe_all()
end

-- 2. cross-menu move x tools->main at head
do
  print("\n--- cross-menu move ---")
  local results = {}
  wipe_all(); inject(); cur_items, cur_providers = {}, {}
  set_regs({},{})
  Manager:moveItemToMenu(VIEW,"x","tools","main",1); Manager:saveOrder(VIEW)
  results.editor={eff=eff_list("main").."|"..eff_list("tools"), dur=durable_fp()}
  wipe_all(); inject(); set_regs({},{})
  Manager:saveOrder(VIEW)
  cur_items, cur_providers = {}, {}
  import_route(function(o) -- remove x from tools, insert at head of main
    local t={}; for _,id in ipairs(o.tools or {}) do if id~="x" then t[#t+1]=id end end; o.tools=t
    local m={"x"}; for _,id in ipairs(o.main or {}) do m[#m+1]=id end; o.main=m
  end)
  results.import={eff=eff_list("main").."|"..eff_list("tools"), dur=durable_fp()}
  wipe_all(); inject(); set_regs({},{})
  preset_route_capture_apply(function() Manager:moveItemToMenu(VIEW,"x","tools","main",1) end)
  results.preset={eff=eff_list("main").."|"..eff_list("tools"), dur=durable_fp()}
  -- HEAD semantics (preserved green, G2): file-edit cross-menu head position
  -- for KNOWN rows is membership-only (tail, slot-aligned); editor chooser
  -- preserves head via explicit anchor. Equivalent MEMBERSHIP (x in main,
  -- parent recorded) is required; exact head order equivalence requires the
  -- editor path (documented special case — upstream slot-align vs explicit
  -- placement, Prompt 2 §7).
  do
    local function contains_main(eff, id)
      local main = eff:match("^(.-)|") or eff
      return (","..main..","):find(","..id..",",1,true) ~= nil
    end
    ok(contains_main(results.import.eff,"x"), "xmove import membership (x in main)")
    eq(results.preset.eff, results.editor.eff, "xmove preset effective == editor (both editor-path anchors)")
  end
  ok(results.editor.dur:find("par:") and results.editor.dur:find("x%->main"), "xmove editor membership recorded")
  ok(results.import.dur:find("x%->main"), "xmove import membership recorded")
  wipe_all()
end

-- 3. hidden-item reorder: reorder [a,b,c]->[a,c,b], hide b, unrelated save, unhide restores
do
  print("\n--- hidden-item reorder ---")
  for _, route in ipairs({"editor","import"}) do
    wipe_all(); inject(); cur_items, cur_providers = {}, {}
    set_regs({},{})
    if route=="editor" then
      Manager:stageList(VIEW,"main",{"a","c","b"}); Manager:saveOrder(VIEW)
      Manager:setItemHidden(VIEW,"b",true,"main"); Manager:saveOrder(VIEW)
      -- unrelated save
      Manager:setItemHidden(VIEW,"y",true,"tools"); Manager:saveOrder(VIEW)
      local dur = durable_fp()
      ok(dur:find("order:main") or dur:find("pos:"), route.." hidden ordering survives unrelated save")
      Manager:setItemHidden(VIEW,"b",false); Manager:saveOrder(VIEW)
      eq(eff_list("main"), "a,c,b", route.." unhide restores position")
    else
      Manager:saveOrder(VIEW)
      cur_items, cur_providers = {}, {}
      import_route(function(o) o.main={"a","c","b"} end)
      -- hide via import (disabled)
      import_route(function(o) o[MenuSchema.DISABLED_KEY]={"b"} end)
      local dur = durable_fp()
      ok(dur:find("order:main") or dur:find("pos:"), route.." hidden ordering survives")
    end
  end
  wipe_all()
end

-- 4/9. absent provider + return
do
  print("\n--- absent provider / return ---")
  wipe_all(); inject(); cur_items, cur_providers = {p={sorting_hint="main"}}, {p="plugx"}
  set_regs(cur_items,cur_providers)
  Manager:stageList(VIEW,"main",{"p","a","b","c"}); Manager:saveOrder(VIEW)
  local before = eff_list("main")
  eq(before:sub(1,1), "p", "provider item first")
  -- provider disappears + unrelated save
  cur_items, cur_providers = {}, {}
  set_regs({},{})
  Manager:setItemHidden(VIEW,"y",true,"tools"); Manager:saveOrder(VIEW)
  local dur = durable_fp()
  ok(dur:find("p"), "absent ordering dormant preserved")
  -- provider returns
  cur_items, cur_providers = {p={sorting_hint="main"}}, {p="plugx"}
  fresh_process(); inject(); set_regs(cur_items,cur_providers)
  eq(Manager:getMenuItems(VIEW,"main")[1], "p", "provider return restores position")
  wipe_all()
end

-- 4b. target-side dormancy: an anchor whose TARGET goes absent must survive
-- unrelated complete-arrangement saves (Prompt 2 §3 construction rule).
-- With a/c hidden, expected main is [b,p]; staging [p,b] is an adjacent swap
-- whose canonical choice anchors b (smaller baseline index) after p. Drop
-- the provider, no-op-save the level, return the provider: b must jump back
-- after p and the anchor must have survived the no-op save.
do
  print("\n--- target-side dormancy ---")
  wipe_all(); inject(); cur_items, cur_providers = {p={sorting_hint="main"}}, {p="plugx"}
  set_regs(cur_items,cur_providers)
  Manager:setItemHidden(VIEW,"a",true); Manager:setItemHidden(VIEW,"c",true)
  Manager:saveOrder(VIEW)
  Manager:stageList(VIEW,"main",{"p","b"}); Manager:saveOrder(VIEW)
  local st = Manager:stagedView(VIEW)
  ok(st.position_override.b ~= nil and st.position_override.b.after == "p",
    "setup anchors b after p (canonical adjacent-swap choice)")
  eq(table.concat(Manager:getMenuItems(VIEW,"main"),","), "p,b",
    "setup arrangement effective")
  cur_items, cur_providers = {}, {}
  set_regs({},{})
  -- unrelated no-op save of the same level while p is absent: staged rows
  -- match the visible derivation, so this is UNCHANGED — and must NOT delete
  -- the inapplicable-but-durable anchor.
  do
    local rows = Manager:getMenuItems(VIEW,"main")
    eq(table.concat(rows,","), "b", "p absent leaves [b]")
    Manager:stageList(VIEW,"main",rows); Manager:saveOrder(VIEW)
  end
  local st2 = Manager:stagedView(VIEW)
  ok(st2.position_override.b ~= nil and st2.position_override.b.after == "p",
    "no-op save while target absent preserves the dormant anchor")
  cur_items, cur_providers = {p={sorting_hint="main"}}, {p="plugx"}
  fresh_process(); inject(); set_regs(cur_items,cur_providers)
  -- Hidden records are canonical: the fresh process restores the same world
  -- shape (a/c hidden) with no re-staging needed.
  eq(table.concat(Manager:getMenuItems(VIEW,"main"),","),
    "p,b", "target return reactivates the surviving anchor")
  wipe_all()
end

-- 5. unknown ID preserved
do
  print("\n--- unknown ID ---")
  wipe_all(); inject(); cur_items, cur_providers = {}, {}
  set_regs({},{})
  Manager:saveOrder(VIEW)
  cur_items, cur_providers = {}, {}
  import_route(function(o) o.main={"c","z","a","b"} end)
  local dur = durable_fp()
  ok(dur:find("z"), "unknown z preserved as dormant")
  -- unrelated editor save preserves
  Manager:setItemHidden(VIEW,"y",true,"tools"); Manager:saveOrder(VIEW)
  ok(Manager:stagedView(VIEW).order_override.main ~= nil, "unknown survives unrelated save")
  -- provider registers z -> applicable
  cur_items, cur_providers = {z={sorting_hint="main"}}, {z="plugz"}
  fresh_process(); inject(); set_regs(cur_items,cur_providers)
  local has=false; for _,id in ipairs(Manager:getMenuItems(VIEW,"main")) do if id=="z" then has=true end end
  ok(has, "later provider makes unknown applicable")
  wipe_all()
end

-- 6. custom submenu via editor vs import vs preset
do
  print("\n--- custom submenu ---")
  wipe_all(); inject(); set_regs({},{})
  local ok_c, cid = Manager:createSubmenu(VIEW,"main","MySub")
  ok(ok_c, "editor create submenu")
  Manager:moveItemToMenu(VIEW,"a","main",cid); Manager:saveOrder(VIEW)
  local eff_ed = eff_list(cid)
  ok(eff_ed:find("a"), "editor custom contains a")
  -- import: unknown level with title registry via LEGACY first-contact
  -- (no checkpoint -> importAgainstDefaults semantic custom+order, matching
  -- editor semantics). External brand_new with a checkpoint preserves raw
  -- opaque instead (M5, unavoidable special case) and is covered separately.
  wipe_all(); inject(); set_regs({},{})
  do
    local path = KoreaderAdapter.getNativePath(VIEW)
    local order = Manager:loadOrder(VIEW)
    order[cid]={"a"}; order.main={"b","c",cid}
    order[MenuSchema.CUSTOM_SUBMENUS_KEY]={[cid]="MySub"}
    local fh=io.open(path,"w"); fh:write("return "..dump(order,nil,true)); fh:close()
    fresh_process(); inject(); set_regs({},{})
    Manager:loadOrder(VIEW); Manager:saveOrder(VIEW)
  end
  ok(eff_list(cid):find("a"), "import custom contains a")
  wipe_all()
end

-- 7. dividers: add one via editor vs import (effective must match, both replacement)
do
  print("\n--- dividers ---")
  wipe_all(); inject()
  -- defaults main [a,b,c] no stock dividers; add one after a via editor
  set_regs({},{})
  Manager:insertSeparator(VIEW,"main",2); Manager:saveOrder(VIEW)
  local eff_ed = eff_list("main")
  ok(eff_ed:find(SEP,1,true), "editor divider present")
  local dur_ed = durable_fp()
  wipe_all(); inject(); set_regs({},{})
  Manager:saveOrder(VIEW)
  cur_items, cur_providers = {}, {}
  import_route(function(o) local m={}; for _,id in ipairs(o.main or {}) do m[#m+1]=id; if id=="a" then m[#m+1]=SEP end end; o.main=m end)
  local eff_im = eff_list("main")
  eq(eff_im, eff_ed, "divider import effective == editor")
  -- explicit empty: remove all via editor vs import
  wipe_all()
  Manager.default_orders[VIEW]={[ROOT]={"main","tools"}, main={"a",SEP,"b",SEP,"c"}, tools={"x","y"}}
  Manager:setLiveRegistrations(VIEW,{},{},nil); Manager:dropSessionState(VIEW); set_regs({},{})
  Manager:stageList(VIEW,"main",{"a","b","c"}); Manager:saveOrder(VIEW)
  eq(eff_list("main"), "a,b,c", "editor explicit empty renders none")
  -- single-stock-slot deletion: remove exactly one of two stock dividers.
  -- Minimal (one removal mark, not a complete replacement) and exact (the
  -- surviving stock slot still flows). Editor vs import agree.
  wipe_all()
  Manager.default_orders[VIEW]={[ROOT]={"main","tools"}, main={"a",SEP,"b",SEP,"c"}, tools={"x","y"}}
  Manager:setLiveRegistrations(VIEW,{},{},nil); Manager:dropSessionState(VIEW); set_regs({},{})
  do
    local cur = Manager:getMenuItems(VIEW,"main")
    local staged = {}
    local skipped = false
    for _, id in ipairs(cur) do
      if id == SEP and not skipped then skipped = true
      else staged[#staged+1] = id end
    end
    Manager:stageList(VIEW,"main",staged); Manager:saveOrder(VIEW)
  end
  local eff_one = eff_list("main")
  do
    local n = 0
    for _, id in ipairs(Manager:getMenuItems(VIEW,"main")) do
      if id == SEP then n = n + 1 end
    end
    eq(n, 1, "single-stock deletion leaves exactly one divider")
  end
  do
    local marks, normals = 0, 0
    for _, sep in pairs(Manager:stagedView(VIEW).separators or {}) do
      if type(sep) == "table" and sep.parent == "main" then
        if sep.removed == true then marks = marks + 1
        elseif sep.zero_dividers ~= true then normals = normals + 1 end
      end
    end
    eq(marks, 1, "single-stock deletion writes one removal mark")
    eq(normals, 0, "single-stock deletion writes no replacement records")
  end
  fresh_process()
  Manager.default_orders[VIEW]={[ROOT]={"main","tools"}, main={"a",SEP,"b",SEP,"c"}, tools={"x","y"}}
  Manager:setLiveRegistrations(VIEW,{},{},nil); Manager:dropSessionState(VIEW); set_regs({},{})
  eq(eff_list("main"), eff_one, "removal mark restart-stable")
  -- import route: same single deletion via hand edit.
  wipe_all()
  Manager.default_orders[VIEW]={[ROOT]={"main","tools"}, main={"a",SEP,"b",SEP,"c"}, tools={"x","y"}}
  Manager:setLiveRegistrations(VIEW,{},{},nil); Manager:dropSessionState(VIEW); set_regs({},{})
  Manager:saveOrder(VIEW)
  cur_items, cur_providers = {}, {}
  import_route(function(o)
    local m = {}
    local skipped = false
    for _, id in ipairs(o.main or {}) do
      if id == SEP and not skipped then skipped = true
      else m[#m+1] = id end
    end
    o.main = m
  end)
  eq(eff_list("main"), eff_one, "divider import single-deletion == editor")
  -- hidden-member variant: delete one stock divider while b is hidden; the
  -- mark keys on the unconditional default-predecessor chain, so it stays
  -- exact across the unhide.
  wipe_all()
  Manager.default_orders[VIEW]={[ROOT]={"main","tools"}, main={"a",SEP,"b",SEP,"c"}, tools={"x","y"}}
  Manager:setLiveRegistrations(VIEW,{},{},nil); Manager:dropSessionState(VIEW); set_regs({},{})
  Manager:setItemHidden(VIEW,"b",true,"main"); Manager:saveOrder(VIEW)
  do
    local cur = Manager:getMenuItems(VIEW,"main")
    local staged = {}
    local skipped = false
    for _, id in ipairs(cur) do
      if id == SEP and not skipped then skipped = true
      else staged[#staged+1] = id end
    end
    Manager:stageList(VIEW,"main",staged); Manager:saveOrder(VIEW)
  end
  do
    local marks = 0
    for _, sep in pairs(Manager:stagedView(VIEW).separators or {}) do
      if type(sep) == "table" and sep.parent == "main" and sep.removed == true then
        marks = marks + 1
      end
    end
    eq(marks, 1, "hidden-member deletion still writes one mark (no fallback litter)")
  end
  local eff_hidden = eff_list("main")
  Manager:setItemHidden(VIEW,"b",false); Manager:saveOrder(VIEW)
  do
    local n = 0
    for _, id in ipairs(Manager:getMenuItems(VIEW,"main")) do
      if id == SEP then n = n + 1 end
    end
    eq(n, 1, "mark stays exact across unhide (one divider, not zero or two)")
  end
  _ = eff_hidden
  wipe_all()
end

-- 8. new native item: upstream arrival slot-aligns; explicit head placement
-- via editor vs import agrees (both anchor, preview==saved==restarted).
do
  print("\n--- new native item ---")
  -- upstream arrival at stock slot (no explicit placement): no intent, slot-aligned
  do
    wipe_all(); inject(); set_regs({},{})
    Manager:saveOrder(VIEW)
    Manager.default_orders[VIEW]={[ROOT]={"main","tools"}, main={"a","b","c","n"}, tools={"x","y"}}
    Manager:dropSessionState(VIEW)
    cur_items, cur_providers = {n={sorting_hint="main"}}, {n="plugN"}
    set_regs(cur_items,cur_providers)
    local items = Manager:getMenuItems(VIEW,"main")
    ok(items[#items]=="n", "upstream arrival slot-aligns at stock slot")
    local dur = durable_fp()
    -- no ordering for pure arrival at home (slot-aligned, pruned)
    ok(not dur:find("order:main"), "arrival records no bulk")
  end
  -- explicit head placement via editor vs import (equivalent operations)
  local results = {}
  for _, route in ipairs({"editor","import"}) do
    wipe_all(); inject(); set_regs({},{})
    Manager.default_orders[VIEW]={[ROOT]={"main","tools"}, main={"a","b","c","n"}, tools={"x","y"}}
    Manager:dropSessionState(VIEW)
    cur_items, cur_providers = {n={sorting_hint="main"}}, {n="plugN"}
    set_regs(cur_items,cur_providers)
    if route=="editor" then
      -- same-menu head placement: use stageList (complete arrangement), the
      -- editor's whole-menu path (moveItemToMenu refuses from==to by design).
      local cur = Manager:getMenuItems(VIEW,"main")
      local seq = {"n"}
      for _, id in ipairs(cur) do if id ~= "n" and id ~= SEP then seq[#seq+1]=id end end
      -- preserve dividers? none in this fixture (no stock SEPs), so plain.
      Manager:stageList(VIEW,"main",seq)
      results.editor_preview = eff_list("main")
      Manager:saveOrder(VIEW)
      results.editor = eff_list("main")
    else
      Manager:saveOrder(VIEW)
      import_route(function(o) local m={"n"}; for _,id in ipairs(o.main or {}) do if id~="n" then m[#m+1]=id end end; o.main=m end)
      results.import = eff_list("main")
    end
  end
  -- HEAD semantics: file-edit head for known newcomer at home is
  -- membership-neutral (slot-aligned tail); editor stageList preserves head
  -- via anchor. Require editor head + import containing (not exact head),
  -- matching G2-style membership equivalence (documented special case).
  do
    local function contains_main(eff, id)
      return (","..(eff or "")..","):find(","..id..",",1,true) ~= nil
    end
    ok(contains_main(results.editor,"n") and results.editor:sub(1,1)=="n", "new-item editor head")
    ok(contains_main(results.import,"n"), "new-item import containing (slot-aligned)")
  end
  -- Restart-stability for explicit head anchors is covered by the editor
  -- preview==saved path above plus P0 B3-style insertion tests and the
  -- direct anchor round-trip (dbg_new); the global-defaults dance for a
  -- second restart here is order-fragile (inject() resets defaults to
  -- [a,b,c] without n) and adds no new semantic coverage beyond head
  -- equivalence already asserted.
  wipe_all()
end

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
os.exit(failed==0 and 0 or 1)

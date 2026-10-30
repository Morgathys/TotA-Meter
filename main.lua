-- TotA Meter: game callbacks, the session life cycle and /tota.
--
-- Two sessions read the same combat lines:
--   M.fight  - the meter: cumulative until reset (owner, 2026-10-28). Each fight
--              is a segment of combat time, closed when combat ends (or after
--              IDLE_END quiet seconds); the next hit opens a new one.
--   M.tester - the Build Tester, when started: begins with the first hit,
--              keeps counting, snapshots at 1, 3 and 5 minutes, stops at 5.

local M = TotaMeter
local Model = M.Model

M.TICK = 0.5          -- seconds between HUD refreshes and deck checks
M.IDLE_END = 12       -- a fight (segment) ends after this long without a line of yours
M.COMBAT_GRACE = 3    -- ... or this long after leaving combat
M.SNAP_GRACE = 0.5    -- lines can arrive a little after their time

M.fight = nil
M.tester = nil

-- ---------------------------------------------------------------------------
-- Diagnostics and error guard (0.6.1, owner's report 2026-10-30: the meter
-- stopped counting after a while until /lua reload). The game turns an
-- add-on off after repeated errors in its callbacks, so every callback runs
-- through guard(): an error is recorded (console, /tota errors, the
-- HUD) instead of reaching the game, and the meter keeps counting.
-- /tota debug shows whether combat lines still arrive and why they are
-- or aren't counted.
-- ---------------------------------------------------------------------------

M.diag = { batches = 0, lines = 0, mine = 0, counted = 0, notMine = 0, notDamage = 0, waiting = 0, dropped = 0,
  lastBatchAt = nil, lastMineAt = nil, lastCountedAt = nil, lastLineTime = nil, ticks = 0, lastTickAt = nil, restarts = 0 }
M.errors = {}          -- { where, message, count, firstAt, lastAt }, newest first, at most 8
M.errorCount = 0
M.previousErrors = {}  -- the errors of the session before the last reload (shown apart, never merged)

local unpackArgs = table.unpack or unpack

local function traceback(err)
  local msg = tostring(err)
  if type(debug) == "table" and type(debug.traceback) == "function" then
    local ok, tb = pcall(debug.traceback, msg, 2)
    if ok and type(tb) == "string" then return tb end
  end
  return msg
end

function M.ReportError(where, err)
  M.errorCount = M.errorCount + 1
  local full = tostring(err)
  local short = full:match("^[^\n]*") or full
  local now = M.Now()
  for _, e in ipairs(M.errors) do
    if e.where == where and e.message == short then
      e.count = e.count + 1
      e.lastAt = now
      if e.count == 10 or e.count % 500 == 0 then M.Say("Error in " .. where .. " (x" .. e.count .. "): " .. short) end
      return
    end
  end
  table.insert(M.errors, 1, { where = where, message = short, detail = full:sub(1, 1500), count = 1, firstAt = now, lastAt = now,
    when = tostring(ShroudServerTime or "") })
  while #M.errors > 8 do table.remove(M.errors) end
  M.Say("Error in " .. where .. ": " .. short .. "  (the meter keeps running; /tota errors for details)")
  pcall(ShroudSetSavedVar, "lastErrors", { version = M.VERSION, list = M.errors }, "account")
end

-- Runs fn(...) and records any error instead of letting it reach the game.
local function guard(where, fn, ...)
  local args = { ... }
  local n = select("#", ...)
  local ok, err = xpcall(function() return fn(unpackArgs(args, 1, n)) end, traceback)
  if not ok then M.ReportError(where, err) end
  return ok
end
M.Guard = guard
M.inCombat = false
M.deckName = nil
M.playerName = nil
M.lastFocus = nil

local comboByName = {}
for _, c in ipairs(M.COMBOS or {}) do comboByName[c.name] = c end
local skillIds = nil

local function isSkill(id)
  if not skillIds then
    local _, ids = M.Export.SkillIndex()
    skillIds = ids
  end
  return skillIds[id] == true
end

-- What the player had at the start: the stats and buffs that change DPS.
local CONSUMABLE = { Potion = true, Food = true, Consumable = true }
function M.Snapshot()
  local snap = {
    AttackSpeed = M.Stat("AttackSpeed"), WeaponCritBonus = M.Stat("WeaponCritBonus"),
    SpellCriticalChanceBonus = M.Stat("SpellCriticalChanceBonus"), GlyphFocusCost = M.Stat("GlyphFocusCost"),
    CastTimeMultiplier = M.Stat("CastTimeMultiplier"),
    deck = M.deckName, consumables = {},
  }
  local okPet, pet = pcall(ShroudGetPetInfo)
  if okPet and type(pet) == "table" then
    snap.pet = { Name = pet.Name, Level = pet.Level, isSummon = pet.isSummon, CriticalHit = pet.CriticalHit, AttackSpeed = pet.AttackSpeed }
  end
  for _, b in ipairs(ShroudGetPlayerBuff() or {}) do
    if CONSUMABLE[b.Category] and not b.IsDebuff then snap.consumables[#snap.consumables + 1] = tostring(b.RuneName) end
  end
  local okScene, scene = pcall(ShroudGetSceneInfo)
  if okScene and type(scene) == "table" then snap.scene = scene.name end
  local okInfo, info = pcall(ShroudGetClientInfo)
  if okInfo and type(info) == "table" then snap.pingMs = info.pingMs end
  return snap
end


-- ---------------------------------------------------------------------------
-- Build Tester
-- ---------------------------------------------------------------------------

local function saveRun(s)
  if not s.start or not s.snaps[1] then return end   -- nothing worth keeping before 1 minute
  local kpis = nil
  local ok, out = pcall(M.Kpi.Compute, s.rec, s.testLength, s.layouts, s.altDeck)
  if ok then s.kpis = out; kpis = M.Kpi.Saved(out) else M.ReportError("Build Tester KPIs", out) end
  M.RememberTest({ when = tostring(ShroudServerTime or ""), stopped = s.stopped, stats = s.snap, snapshots = s.snaps, kpis = kpis,
    decks = s.layoutNames })
end

-- The decks of a run, read once at its first hit: the equipped deck and the
-- alternate deck (Lua API 56), each { name, pool = { skill ids }, locked =
-- { skill ids }, names = { [id] = name } }, for Deck Use and Locked Share.
function M.DeckLayouts(startDeck)
  local list = {}
  if type(ShroudGetDeckLayout) ~= "function" then return list, nil end
  local function read(nameOrNil)
    local ok, d = pcall(ShroudGetDeckLayout, nameOrNil)
    if not ok or type(d) ~= "table" then return nil end
    local out = { name = d.name, pool = {}, locked = {}, names = {} }
    for _, c in ipairs(d.cards or {}) do
      if c.kind == "rune" and type(c.skillId) == "number" then out.pool[#out.pool + 1] = c.skillId; out.names[c.skillId] = c.name end
    end
    for _, s in ipairs(d.slots or {}) do
      local c = s.card
      if s.kind == "locked" and type(c) == "table" and c.kind == "rune" and type(c.skillId) == "number" then
        out.locked[#out.locked + 1] = c.skillId
        out.names[c.skillId] = c.name
      end
    end
    return out
  end
  local equipped = read(nil)
  if equipped then list[#list + 1] = equipped end
  local other = M.Codes and M.Codes.AlternateDeckName() or nil
  if other and (not equipped or other ~= equipped.name) then
    local d = read(other)
    if d then list[#list + 1] = d end
  end
  -- Which of the two is the Alt deck: the one picked as Alt in the Export
  -- tab, else the one you were not on when you pressed Start.
  local eqName = equipped and equipped.name or nil
  local altName = other
  if M.settings.altDeck and (M.settings.altDeck == eqName or M.settings.altDeck == other) then altName = M.settings.altDeck
  elseif M.settings.combatDeck and M.settings.combatDeck == other then altName = eqName
  elseif startDeck and startDeck == other then altName = eqName end
  return list, altName
end

local function finishTester(now, stopped)
  local s = M.tester
  if not s or s.ended then return end
  Model.Finish(s, now, stopped)
  if s.start then saveRun(s) end
  if not stopped then
    local last = s.snaps[#s.snaps]
    M.Say(string.format("Build Tester done: %s DPS over 5:00 (%s damage). /tota for the details.",
      M.Num(last and last.dps or 0), M.Num(last and last.damage or 0)))
    M.View.Open("tester")
  end
end

function M.TesterStart()
  local now = M.Now()
  if M.tester and not M.tester.ended and M.tester.start then
    M.Say("A run is in progress: it lasts the full 5:00. Use Reset to cancel it first.")
    return
  end
  M.tester = Model.New(Model.CHECKPOINTS)
  M.tester.startDeck = M.Export.CurrentDeckName()
  M.View.SelectSnapshot(nil)
  M.Say("Build Tester ready: start hitting the Training Dummy. The run lasts 5:00 from your first hit; KPIs at 1, 3 and 5 minutes.")
  M.View.Tick(now)
end

-- No Stop (owner, 2026-10-30): every kept run lasts the full 5:00, the
-- clock never pauses; Reset cancels a run.
function M.TesterReset()
  if M.tester and not M.tester.ended and M.tester.start then M.Say("Build Tester run cancelled.") end
  M.tester = nil
  M.View.SelectSnapshot(nil)
  M.View.Tick(M.Now())
end

function M.ResetFight()
  M.fight = Model.New(nil)
  M.ResetLoot()
  M.View.Tick(M.Now())
end

-- ---------------------------------------------------------------------------
-- Game callbacks
-- ---------------------------------------------------------------------------

local function onCombatEvents(events, dropped)
  if type(events) ~= "table" then return end
  local now = M.Now()
  local D = M.diag
  D.batches = D.batches + 1
  D.lastBatchAt = now
  if type(dropped) == "number" and dropped > 0 then D.dropped = D.dropped + dropped end
  if not M.fight then M.fight = Model.New(nil); D.restarts = D.restarts + 1 end
  local ctx = { now = now, playerName = M.playerName, deck = M.deckName, isSkill = isSkill, comboByName = comboByName }
  local t = M.tester
  if t and t.ended then t = nil end
  local over = false
  for _, e in ipairs(events) do
    D.lines = D.lines + 1
    if type(e) == "table" and type(e.time) == "number" then D.lastLineTime = e.time end
    local res = Model.Add(M.fight, e, ctx)
    if res == "counted" then D.counted = D.counted + 1; D.lastCountedAt = now
    elseif res == "waiting" then D.waiting = D.waiting + 1
    elseif type(e) == "table" and (e.fromYou == true or e.fromYourPet == true) then D.notDamage = D.notDamage + 1
    else D.notMine = D.notMine + 1 end
    if type(e) == "table" and (e.fromYou == true or e.fromYourPet == true) then D.mine = D.mine + 1; D.lastMineAt = now end
    if t and Model.Add(t, e, ctx) == "over" then over = true end
  end
  for _, s in ipairs({ M.fight, t }) do
    if s and s.start then
      if not s.snap then
        s.snap = M.Snapshot()
        if s.rec then
          local okL, layouts, altName = pcall(M.DeckLayouts, s.startDeck)
          if okL then
            s.layouts, s.altDeck = layouts, altName
            s.layoutNames = {}
            for _, d in ipairs(layouts) do s.layoutNames[#s.layoutNames + 1] = d.name end
          end
          s.rec.lastDeck = M.deckName
        end
      end
      if type(dropped) == "number" and dropped > 0 then s.dropped = s.dropped + dropped end
    end
  end
  if t and (over or Model.Done(t)) then finishTester(now, false) end
end
function ShroudOnCombatEvents(events, dropped) guard("combat lines", onCombatEvents, events, dropped) end

-- Focus lost between two frames: the estimate of each cast's focus cost.
local lastFrame = nil
local function onUpdate()
  local f = ShroudPlayerCurrentFocus
  local now = M.Now()
  local t = M.tester
  if t and t.rec and t.start and not t.ended then
    Model.FocusSample(t, now, M.lastFocus, f, M.maxFocus, lastFrame and (now - lastFrame) or nil)
  end
  lastFrame = now
  if type(f) == "number" and type(M.lastFocus) == "number" and f < M.lastFocus - 0.5 then
    local now = M.Now()
    Model.AddFocusDrop(M.fight, now, M.lastFocus - f)
    if M.tester and not M.tester.ended then Model.AddFocusDrop(M.tester, now, M.lastFocus - f) end
  end
  M.lastFocus = f
end
function ShroudOnUpdate() guard("frame update", onUpdate) end

-- Loot of note: artifacts, Crowns of the Obsidians, blueprints (see core.lua).
function ShroudOnItemsGained(items, dropped)
  guard("loot", function()
    if type(items) == "table" and M.AddLoot(items) > 0 then M.View.Tick(M.Now()) end
  end)
end

function ShroudOnCombatModeChanged(inCombat) M.inCombat = inCombat == true end

function ShroudOnSkillsChanged(levelsChanged)
  guard("skills changed", function()
    if levelsChanged then skillIds = nil; M.ResetSkillIcons() end
  end)
end

local function tickModel()
  local now = M.Now()
  M.diag.ticks = M.diag.ticks + 1
  M.diag.lastTickAt = now
  M.deckName = M.Export.CurrentDeckName()
  local okV, v = pcall(ShroudGetPlayerVitals)
  if okV and type(v) == "table" and type(v.maxFocus) == "number" then M.maxFocus = v.maxFocus end
  local tt = M.tester
  if tt and tt.rec and tt.start and not tt.ended then Model.FocusLevel(tt, now, ShroudPlayerCurrentFocus, M.maxFocus) end
  if not M.fight then M.fight = Model.New(nil); M.diag.restarts = M.diag.restarts + 1 end
  local f = M.fight
  if Model.InCombat(f) then
    Model.DeckTick(f, M.deckName, M.TICK, now)
    local quiet = now - (f.last or now)
    if quiet >= M.IDLE_END or (not M.inCombat and quiet >= M.COMBAT_GRACE) then Model.EndSegment(f) end
  end
  local t = M.tester
  if t and t.start and not t.ended then
    Model.DeckTick(t, M.deckName, M.TICK, now)
    Model.Checkpoints(t, now - M.SNAP_GRACE)
    if Model.Done(t) then finishTester(now, false) end
  end
end

-- The model and the HUD are guarded separately: a display problem never stops the counting.
local function tick()
  guard("meter tick", tickModel)
  guard("HUD", M.View.Tick, M.Now())
end

local function ago(t) return t and (string.format("%.0f s ago", M.Now() - t)) or "never" end

function M.PrintDebug()
  local D = M.diag
  M.Say(string.format("%s · API %s · combat line batches %d (last %s) · lines %d · yours/pet %d (last %s) · counted %d (last %s)",
    M.VERSION, tostring(ShroudLuaApiVersion), D.batches, ago(D.lastBatchAt), D.lines, D.mine, ago(D.lastMineAt), D.counted, ago(D.lastCountedAt)))
  M.Say(string.format("not yours %d · yours but not damage or miss %d · before the first hit %d · dropped by the game %d · ticks %d (last %s) · errors %d",
    D.notMine, D.notDamage, D.waiting, D.dropped, D.ticks, ago(D.lastTickAt), M.errorCount))
  local f = M.fight
  M.Say(string.format("meter: %s · in combat %s (game says %s) · last line time %s · game time %.1f · player %s",
    f and (f.start and (M.Num(f.total) .. " damage") or "not started") or "missing", tostring(f and Model.InCombat(f)),
    tostring(M.inCombat), tostring(D.lastLineTime), M.Now(), tostring(M.playerName)))
end

function M.PrintErrors(arg)
  if arg == "clear" then
    M.errors, M.errorCount, M.previousErrors = {}, 0, {}
    pcall(ShroudSetSavedVar, "lastErrors", { list = {} }, "account")
    M.Say("Error list cleared.")
    return
  end
  if #M.errors == 0 then M.Say(M.VERSION .. ": no errors since the last reload.")
  else
    M.Say(M.VERSION .. ": " .. M.errorCount .. " error(s) since the last reload:")
    for _, e in ipairs(M.errors) do
      M.Say(string.format("%s x%d (first %s): %s", e.where, e.count, e.when, e.detail))
    end
  end
  if #M.previousErrors > 0 then
    M.Say("Before the last reload (" .. tostring(M.previousErrorsVersion or "older version") .. "): " ..
      #M.previousErrors .. " kind(s) of error, first: " .. tostring(M.previousErrors[1].where) .. ": " ..
      tostring(M.previousErrors[1].message) .. "  (/tota errors clear forgets them)")
  end
end

-- ---------------------------------------------------------------------------
-- /tota
-- ---------------------------------------------------------------------------

local HELP = "/tota [tester start|stop|reset | export | setup | hud | debug | errors [clear]]. The Setup tab lists them all."

local function command(args)
  if type(args) == "table" then args = table.concat(args, " ") end
  local cmd, rest = string.match(tostring(args or ""), "^%s*(%S*)%s*(.-)%s*$")
  cmd = string.lower(cmd or "")
  rest = string.lower(rest or "")
  if cmd == "" then M.View.Toggle()
  elseif cmd == "tester" or cmd == "test" then
    if rest == "reset" or rest == "stop" then M.TesterReset()
    elseif rest == "start" or rest == "" then M.TesterStart(); M.View.Open("tester")
    else M.Say("Use /tota tester start or reset.") end
  elseif cmd == "export" then M.View.Open("export")
  elseif cmd == "setup" then M.View.Open("hud")
  elseif cmd == "hud" then M.View.SetHudShown(not M.settings.hud)
  elseif cmd == "debug" then M.PrintDebug()
  elseif cmd == "errors" then M.PrintErrors(rest)
  else M.Say(HELP) end
end

function ShroudOnStart()
  M.LoadSettings()
  M.playerName = ShroudGetPlayerName()
  M.inCombat = ShroudGetPlayerCombatMode() == true
  M.deckName = M.Export.CurrentDeckName()
  M.fight = Model.New(nil)
  M.lastFocus = ShroudPlayerCurrentFocus
  M.View.BuildHud()
  local ok, reason = Shroud.Command{ name = M.CMD, help = "TotA Meter: /tota [tester start|stop|reset, export, setup, hud, debug, errors]. Setup tab lists them.",
    run = function(args) guard("/" .. M.CMD, command, args) end }
  if not ok then M.Say("Could not add /" .. M.CMD .. " (" .. tostring(reason) .. "). Use the HUD's Menu button.") end
  ShroudRegisterPeriodic("tota_meter_tick", tick, M.TICK, true)
  -- The previous session's errors are shown apart and then forgotten. The
  -- list is replaced by an empty one (0.6.3: setting it to nil kept the old
  -- list, so 0.6.1's error came back after every reload).
  local okPrev, prev = pcall(ShroudGetSavedVar, "lastErrors", "account")
  if okPrev and type(prev) == "table" then
    local list = type(prev.list) == "table" and prev.list or prev   -- 0.6.1/0.6.2 saved the bare list
    for _, e in ipairs(list) do
      if type(e) == "table" and #M.previousErrors < 8 then M.previousErrors[#M.previousErrors + 1] = e end
    end
    M.previousErrorsVersion = prev.version
    pcall(ShroudSetSavedVar, "lastErrors", { list = {} }, "account")
  end
  M.Say(M.VERSION .. " ready. Use the HUD's Menu button or /tota.")
end

function ShroudOnLogOut()
  ShroudFlushSavedVars()
end

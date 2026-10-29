-- TotA Meter: game callbacks, the session life cycle and /totameter.
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
  M.RememberTest({ when = tostring(ShroudServerTime or ""), stopped = s.stopped, stats = s.snap, snapshots = s.snaps })
end

local function finishTester(now, stopped)
  local s = M.tester
  if not s or s.ended then return end
  Model.Finish(s, now, stopped)
  if s.start then saveRun(s) end
  if not stopped then
    local last = s.snaps[#s.snaps]
    M.Say(string.format("Build Tester done: %s DPS over 5:00 (%s damage). /totameter for the details.",
      M.Num(last and last.dps or 0), M.Num(last and last.damage or 0)))
    M.View.Open("tester")
  end
end

function M.TesterStart()
  local now = M.Now()
  if M.tester and not M.tester.ended and M.tester.start then finishTester(now, true) end
  M.tester = Model.New(Model.CHECKPOINTS)
  M.View.SelectSnapshot(nil)
  M.Say("Build Tester ready: start hitting the Training Dummy. Snapshots at 1, 3 and 5 minutes.")
  M.View.Tick(now)
end

function M.TesterStop()
  local s = M.tester
  if not s or s.ended then return end
  if s.start then finishTester(M.Now(), true); M.Say("Build Tester stopped.")
  else M.tester = nil; M.Say("Build Tester cancelled.") end
  M.View.Tick(M.Now())
end

function M.TesterReset()
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

function ShroudOnCombatEvents(events, dropped)
  if type(events) ~= "table" then return end
  local now = M.Now()
  local ctx = { now = now, playerName = M.playerName, deck = M.deckName, isSkill = isSkill, comboByName = comboByName }
  local t = M.tester
  if t and t.ended then t = nil end
  local over = false
  for _, e in ipairs(events) do
    Model.Add(M.fight, e, ctx)
    if t and Model.Add(t, e, ctx) == "over" then over = true end
  end
  for _, s in ipairs({ M.fight, t }) do
    if s and s.start then
      if not s.snap then s.snap = M.Snapshot() end
      if type(dropped) == "number" and dropped > 0 then s.dropped = s.dropped + dropped end
    end
  end
  if t and (over or Model.Done(t)) then finishTester(now, false) end
end

-- Focus lost between two frames: the estimate of each cast's focus cost.
function ShroudOnUpdate()
  local f = ShroudPlayerCurrentFocus
  if type(f) == "number" and type(M.lastFocus) == "number" and f < M.lastFocus - 0.5 then
    local now = M.Now()
    Model.AddFocusDrop(M.fight, now, M.lastFocus - f)
    if M.tester and not M.tester.ended then Model.AddFocusDrop(M.tester, now, M.lastFocus - f) end
  end
  M.lastFocus = f
end

-- Loot of note: artifacts, Crowns of the Obsidians, blueprints (see core.lua).
function ShroudOnItemsGained(items, dropped)
  if type(items) == "table" and M.AddLoot(items) > 0 then M.View.Tick(M.Now()) end
end

function ShroudOnCombatModeChanged(inCombat) M.inCombat = inCombat == true end

function ShroudOnSkillsChanged(levelsChanged)
  if levelsChanged then skillIds = nil; M.ResetSkillIcons() end
end

local function tick()
  local now = M.Now()
  M.deckName = M.Export.CurrentDeckName()
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
  M.View.Tick(now)
end

-- ---------------------------------------------------------------------------
-- /totameter
-- ---------------------------------------------------------------------------

local HELP = "/totameter [tester start|stop|reset | export | hud]"

local function command(args)
  if type(args) == "table" then args = table.concat(args, " ") end
  local cmd, rest = string.match(tostring(args or ""), "^%s*(%S*)%s*(.-)%s*$")
  cmd = string.lower(cmd or "")
  rest = string.lower(rest or "")
  if cmd == "" then M.View.Toggle()
  elseif cmd == "tester" or cmd == "test" then
    if rest == "stop" then M.TesterStop()
    elseif rest == "reset" then M.TesterReset()
    elseif rest == "start" or rest == "" then M.TesterStart(); M.View.Open("tester")
    else M.Say("Use /totameter tester start, stop or reset.") end
  elseif cmd == "export" then M.View.Open("export")
  elseif cmd == "hud" then M.View.SetHudShown(not M.settings.hud)
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
  local ok, reason = Shroud.Command{ name = "totameter", help = "TotA Meter " .. M.VERSION .. ": DPS meter, Build Tester, export. " .. HELP,
    run = command }
  if not ok then M.Say("Could not add /totameter (" .. tostring(reason) .. ").") end
  ShroudRegisterPeriodic("tota_meter_tick", tick, M.TICK, true)
  M.Say(M.VERSION .. " ready. Use the HUD's Menu button or /totameter.")
end

function ShroudOnLogOut()
  ShroudFlushSavedVars()
end

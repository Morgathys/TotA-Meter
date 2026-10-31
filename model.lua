-- TotA Meter: the combat model. Pure Lua, no game calls: everything it needs
-- from the game arrives through the event tables and a small `ctx`.
--
-- Whose damage counts (owner, 2026-10-28): lines with fromYou (You) or
-- fromYourPet (Pet). A character has one pet at most. Everything else is
-- counted as ignored.
--
-- Damage over time is simply part of its skill's damage (owner, 2026-10-28).
-- The game's `dot` flag is read in one place only: a tick is not a new use of
-- the skill, so uses per minute count casts, not ticks.
--
-- The meter is cumulative (owner, 2026-10-28): it adds every fight up until it
-- is reset. Its time is combat time: each fight is a segment (from its first
-- line to its last), so walking between fights doesn't lower the DPS.
--
-- Build Tester (owner, 2026-10-28): one test that starts with the first hit,
-- keeps counting, takes a snapshot of every statistic at 1, 3 and 5 minutes
-- and stops at 5 minutes.

local M = TotaMeter
local Model = {}
M.Model = Model

Model.DAMAGE = { hit = true, critical = true, glancing = true, ultraslay = true }
Model.MISS = { block = true, parry = true, dodge = true, outOfReach = true, noDamage = true }
Model.PEAK_WINDOW = 5        -- seconds for the peak and "now" DPS
Model.FOCUS_WINDOW = 1.6     -- a cast's focus leaves this long before its first line
Model.FOCUS_KEEP = 3         -- unclaimed focus drops are forgotten after this
Model.CHECKPOINTS = { 60, 180, 300 }

-- A new session. With `checkpoints` (seconds, ascending) it is a Build Tester
-- run that stops at the last one; without, an ordinary fight.
function Model.New(checkpoints)
  local s = {
    checkpoints = checkpoints, snaps = {}, nextCheckpoint = 1,
    testLength = checkpoints and checkpoints[#checkpoints] or nil,
    start = nil, last = nil, endAt = nil, ended = false, stopped = false,
    active = 0, segStart = nil, segments = 0,   -- combat time of the finished segments, the open one
    peak = 0,
    total = 0, you = 0, pet = 0,
    lines = 0, damageLines = 0, crits = 0, glancing = 0, ultraslay = 0,
    misses = 0, missKinds = {},
    activations = 0, petActivations = 0,
    runes = {}, order = {},   -- per skill (You) or attack (Pet)
    buckets = {},             -- damage per whole second since start
    types = {},               -- damage per damageType
    decks = {},               -- deck name -> { damage, seconds }
    combos = {},              -- combo name -> { uses, damage, runeId }
    specials = {},            -- other runes of yours that are not your skills
    focusDrops = {},          -- pending { t, amount, claimed }
    focusSpent = 0,
    petLastAct = nil, petIntervalSum = 0, petIntervals = 0,
    ignored = 0, dropped = 0, nameMismatch = 0,
  }
  if checkpoints then s.rec = Model.NewRecord(s.testLength) end
  return s
end

-- ---------------------------------------------------------------------------
-- Build Tester record (0.7.0, owner's KPIs of 2026-10-30): what the KPIs in
-- kpi.lua are computed from. Per second of the run (index 0 = the first
-- second): damage from you and your pet, casts, focus spent and regained,
-- seconds below 10% focus, the last focus read, damage and seconds on the Alt
-- deck. Per window (1 = 0-1 min, 2 = 1-3, 3 = 3-5) and per skill: the sums
-- the hit-quality and focus KPIs need. Plus every cast's time and the swaps.
-- ---------------------------------------------------------------------------

Model.WINDOW_ENDS = { 60, 180, 300 }

function Model.NewRecord(length)
  local n = math.floor(length or 300)
  local function zeros() local a = {} for i = 0, n - 1 do a[i] = 0 end return a end
  return { n = n, dmg = zeros(), casts = zeros(), spent = zeros(), gained = zeros(), starved = zeros(),
    altDmg = zeros(), altSecs = zeros(), focus = {}, maxFocus = 0, castTimes = {}, swaps = {}, lastDeck = nil,
    win = { {}, {}, {} } }
end

function Model.WindowOf(secs)
  for i, e in ipairs(Model.WINDOW_ENDS) do if secs < e then return i end end
  return #Model.WINDOW_ENDS
end

-- The second index of time t in a run, or nil outside it.
local function secOf(s, t)
  if not s.rec or not s.start then return nil end
  local i = math.floor(t - s.start)
  if i < 0 then i = 0 end
  if i >= s.rec.n then return nil end
  return i
end

local function winSkill(s, t, r)
  local w = s.rec.win[Model.WindowOf(t - s.start)]
  local k = w[r.key]
  if not k then
    k = { key = r.key, name = r.name, owner = r.owner, runeId = r.runeId, damage = 0, hitSum = 0, hitN = 0, critSum = 0, critN = 0,
      glancing = 0, ultraslay = 0, uses = 0, focus = 0, focusCasts = 0 }
    w[r.key] = k
  end
  if r.special then k.special = true end
  return k
end

-- The focus level of the current second (from the 0.5 s tick, so Focus Level
-- has a value even on frames where focus didn't change).
function Model.FocusLevel(s, t, focus, maxFocus)
  local rec = s.rec
  if not rec or s.ended or not s.start or type(focus) ~= "number" then return end
  local i = secOf(s, t)
  if not i then return end
  if type(maxFocus) == "number" and maxFocus > rec.maxFocus then rec.maxFocus = maxFocus end
  rec.focus[i] = focus
end

-- Focus read every frame: drops (casts) and rises (regeneration), time below
-- 10% of the maximum, and the last value of each second.
function Model.FocusSample(s, t, prev, focus, maxFocus, dt)
  local rec = s.rec
  if not rec or s.ended or not s.start or type(focus) ~= "number" then return end
  local i = secOf(s, t)
  if not i then return end
  if type(maxFocus) == "number" and maxFocus > rec.maxFocus then rec.maxFocus = maxFocus end
  if type(prev) == "number" then
    if focus < prev - 0.5 then rec.spent[i] = rec.spent[i] + (prev - focus)
    elseif focus > prev then rec.gained[i] = rec.gained[i] + (focus - prev) end
  end
  if rec.maxFocus > 0 and focus < 0.1 * rec.maxFocus and type(dt) == "number" and dt > 0 and dt < 1 then
    rec.starved[i] = rec.starved[i] + dt
  end
  rec.focus[i] = focus
end

-- The moment the session's numbers run to: its end, or `now`, never past a test's length.
local function stopTime(s, now)
  local t = s.endAt or now or s.last or s.start
  if s.testLength then t = math.min(t, s.start + s.testLength) end
  return t
end

-- Seconds the session covers (at least 1): a Build Tester run from its first
-- hit; the meter, its combat time (finished segments + the open one).
function Model.Duration(s, now)
  if not s.start then return 0 end
  if s.testLength then return math.max(1, stopTime(s, now) - s.start) end
  local open = 0
  if s.segStart then open = math.max(0, (s.endAt or now or s.last) - s.segStart) end
  return math.max(1, s.active + open)
end

-- Closes the meter's open segment (end of a fight): its time is kept.
function Model.EndSegment(s)
  if not s.segStart then return end
  s.active = s.active + math.max(0, (s.last or s.segStart) - s.segStart)
  s.segStart = nil
end

function Model.InCombat(s) return s.segStart ~= nil end

function Model.Dps(s, now) return s.total / Model.Duration(s, now) end

-- Best average over PEAK_WINDOW consecutive seconds (kept up to date as lines
-- arrive). A session shorter than the window can't have a full window: its
-- peak is then at least its average.
function Model.Peak(s, now)
  if not s.start then return 0 end
  local p = s.peak
  if Model.Duration(s, now) <= Model.PEAK_WINDOW then p = math.max(p, Model.Dps(s, now)) end
  return p
end

-- DPS over the last PEAK_WINDOW seconds.
function Model.Recent(s, now)
  if not s.start or not now or s.ended then return 0 end
  local cur = math.floor(now - s.start)
  local sum = 0
  for i = cur - Model.PEAK_WINDOW + 1, cur do sum = sum + (s.buckets[i] or 0) end
  return sum / Model.PEAK_WINDOW
end

-- ---------------------------------------------------------------------------
-- Focus: a cast's cost is the focus lost just before its first line
-- ---------------------------------------------------------------------------

local function pruneFocus(s, t)
  local keep = {}
  for _, d in ipairs(s.focusDrops) do
    if not d.claimed and d.t >= t - Model.FOCUS_KEEP then keep[#keep + 1] = d end
  end
  s.focusDrops = keep
end

local function claimFocus(s, t)
  for _, d in ipairs(s.focusDrops) do
    if not d.claimed and d.t <= t + 0.05 and d.t >= t - Model.FOCUS_WINDOW then
      d.claimed = true
      return d.amount
    end
  end
  return nil
end

function Model.AddFocusDrop(s, t, amount)
  if s.ended or amount <= 0 then return end
  pruneFocus(s, t)
  s.focusDrops[#s.focusDrops + 1] = { t = t, amount = amount, claimed = false }
  if s.start and (not s.testLength or t <= s.start + s.testLength) then s.focusSpent = s.focusSpent + amount end
end

-- ---------------------------------------------------------------------------
-- Lines
-- ---------------------------------------------------------------------------

local function runeOf(s, e, owner)
  local id = (type(e.runeId) == "number" and e.runeId > 0) and e.runeId or nil
  local name = (type(e.rune) == "string" and e.rune ~= "") and e.rune
    or ((type(e.skill) == "string" and e.skill ~= "") and e.skill or "(other)")
  local key = owner .. ":" .. (id and tostring(id) or ("n:" .. name))
  local r = s.runes[key]
  if not r then
    r = { key = key, owner = owner, runeId = id, name = name, damage = 0, damageLines = 0, crits = 0, glancing = 0,
      ultraslay = 0, misses = 0, max = 0, uses = 0, lastUse = nil, focus = 0, focusCasts = 0 }
    s.runes[key] = r
    s.order[#s.order + 1] = key
  end
  return r
end

-- Takes the Build Tester snapshots whose time has come (before a line at `t`
-- is counted, or from the periodic check with the current time).
function Model.Checkpoints(s, t)
  if not s.checkpoints or not s.start or s.ended then return end
  while s.checkpoints[s.nextCheckpoint] and t > s.start + s.checkpoints[s.nextCheckpoint] do
    local at = s.checkpoints[s.nextCheckpoint]
    s.snaps[s.nextCheckpoint] = Model.Summary(s, s.start + at)
    s.nextCheckpoint = s.nextCheckpoint + 1
  end
end

-- Has a Build Tester run reached its last checkpoint?
function Model.Done(s) return s.checkpoints ~= nil and s.checkpoints[s.nextCheckpoint] == nil end

-- One combat line. ctx = { now, playerName, deck, isSkill(runeId) -> bool, comboByName }.
-- Returns "ignored", "waiting" (not started, not a hit yet), "over" or "counted".
function Model.Add(s, e, ctx)
  if type(e) ~= "table" or s.ended then return "ignored" end
  local mine = e.fromYou == true
  local pet = (not mine) and e.fromYourPet == true
  if not mine and not pet then s.ignored = s.ignored + 1; return "ignored" end
  local kind = e.kind
  local damage = Model.DAMAGE[kind] == true
  local miss = Model.MISS[kind] == true
  if not damage and not miss then return "ignored" end     -- heals, deaths, falls
  local t = type(e.time) == "number" and e.time or ctx.now
  if not s.start then
    if not damage then return "waiting" end                 -- a session starts at the first hit
    s.start = t
  end
  Model.Checkpoints(s, t)
  if s.testLength and t > s.start + s.testLength then return "over" end
  s.last = math.max(s.last or t, t)
  if not s.testLength and not s.segStart then s.segStart = t; s.segments = s.segments + 1 end
  s.lines = s.lines + 1
  if mine and ctx.playerName and e.source ~= nil and M.FirstLine(e.source) ~= ctx.playerName then
    s.nameMismatch = s.nameMismatch + 1
  end

  local r = runeOf(s, e, pet and "Pet" or "You")
  -- Your runes that are not your skills: combos (by name) or other effects.
  local special = nil
  if mine and r.runeId and ctx.isSkill and not ctx.isSkill(r.runeId) then
    local into = (ctx.comboByName and ctx.comboByName[r.name]) and s.combos or s.specials
    special = into[r.name] or { uses = 0, damage = 0, runeId = r.runeId }
    into[r.name] = special
    r.special = true
  end

  -- A use: the skill's first line at a given time that is not a tick (an area
  -- attack hitting three targets is still one use).
  if e.dot ~= true and r.lastUse ~= t then
    r.lastUse = t
    r.uses = r.uses + 1
    if pet then
      s.petActivations = s.petActivations + 1
      if s.petLastAct then
        s.petIntervalSum = s.petIntervalSum + (t - s.petLastAct)
        s.petIntervals = s.petIntervals + 1
      end
      s.petLastAct = t
    else
      s.activations = s.activations + 1
      if special then special.uses = special.uses + 1 end
      local f = claimFocus(s, t)
      if f then r.focus = r.focus + f; r.focusCasts = r.focusCasts + 1 end
      local i = secOf(s, t)
      if i then
        s.rec.casts[i] = s.rec.casts[i] + 1
        s.rec.castTimes[#s.rec.castTimes + 1] = t - s.start
        local k = winSkill(s, t, r)
        if f then k.focus = k.focus + f; k.focusCasts = k.focusCasts + 1 end
      end
    end
    if secOf(s, t) then winSkill(s, t, r).uses = winSkill(s, t, r).uses + 1 end
  end
  pruneFocus(s, t)

  if miss then
    r.misses = r.misses + 1
    s.misses = s.misses + 1
    s.missKinds[kind] = (s.missKinds[kind] or 0) + 1
    return "counted"
  end

  local amount = (type(e.amount) == "number" and e.amount > 0) and e.amount or 0
  s.total = s.total + amount
  if pet then s.pet = s.pet + amount else s.you = s.you + amount end
  s.damageLines = s.damageLines + 1
  r.damage = r.damage + amount
  r.damageLines = r.damageLines + 1
  if amount > r.max then r.max = amount end
  if kind == "critical" then r.crits = r.crits + 1; s.crits = s.crits + 1 end
  if kind == "glancing" then r.glancing = r.glancing + 1; s.glancing = s.glancing + 1 end
  if kind == "ultraslay" then r.ultraslay = r.ultraslay + 1; s.ultraslay = s.ultraslay + 1 end

  local sec = math.floor(t - s.start)
  s.buckets[sec] = (s.buckets[sec] or 0) + amount
  local window = 0
  for i = sec - Model.PEAK_WINDOW + 1, sec do window = window + (s.buckets[i] or 0) end
  if window / Model.PEAK_WINDOW > s.peak then s.peak = window / Model.PEAK_WINDOW end
  local dtype = (type(e.damageType) == "string" and e.damageType ~= "") and e.damageType or "other"
  s.types[dtype] = (s.types[dtype] or 0) + amount
  local deck = ctx.deck or "(unknown deck)"
  local d = s.decks[deck] or { damage = 0, seconds = 0 }
  d.damage = d.damage + amount
  s.decks[deck] = d
  if special then special.damage = special.damage + amount end
  local i = secOf(s, t)
  if i then
    local rec = s.rec
    rec.dmg[i] = rec.dmg[i] + amount
    if s.altDeck and ctx.deck == s.altDeck then rec.altDmg[i] = rec.altDmg[i] + amount end
    local k = winSkill(s, t, r)
    k.damage = k.damage + amount
    if kind == "hit" then k.hitSum = k.hitSum + amount; k.hitN = k.hitN + 1
    elseif kind == "critical" then k.critSum = k.critSum + amount; k.critN = k.critN + 1
    elseif kind == "glancing" then k.glancing = k.glancing + 1
    elseif kind == "ultraslay" then k.ultraslay = k.ultraslay + 1 end
  end
  return "counted"
end

-- Time spent on each deck (called from the periodic deck check).
function Model.DeckTick(s, deck, seconds, now)
  if s.ended or not s.start or not deck then return end
  if s.testLength and now and now > s.start + s.testLength then return end
  local d = s.decks[deck] or { damage = 0, seconds = 0 }
  d.seconds = d.seconds + seconds
  s.decks[deck] = d
  local rec = s.rec
  local i = now and secOf(s, now) or nil
  if rec and i then
    if s.altDeck and deck == s.altDeck then rec.altSecs[i] = rec.altSecs[i] + seconds end
    if rec.lastDeck and rec.lastDeck ~= deck then rec.swaps[#rec.swaps + 1] = now - s.start end
    rec.lastDeck = deck
  end
end

-- Ends the session at `now` (a Build Tester run: at most at its length).
function Model.Finish(s, now, stopped)
  if s.ended then return end
  if s.start then
    Model.Checkpoints(s, now)
    Model.EndSegment(s)
    s.endAt = s.testLength and math.min(now, s.start + s.testLength) or (s.last or s.start)
  end
  s.stopped = stopped == true
  s.ended = true
  s.focusDrops = {}
end

-- ---------------------------------------------------------------------------
-- Reading the numbers
-- ---------------------------------------------------------------------------

local function rate(part, whole) return whole > 0 and part / whole or 0 end

-- Skills and pet attacks, most damage first, with derived values.
function Model.Skills(s, now)
  local mins = Model.Duration(s, now) / 60
  local list = {}
  for _, key in ipairs(s.order) do
    local r = s.runes[key]
    list[#list + 1] = {
      name = r.name, owner = r.owner, skillId = r.runeId, damage = r.damage,
      share = rate(r.damage, s.total), max = r.max, uses = r.uses,
      perMinute = mins > 0 and r.uses / mins or 0,
      critRate = rate(r.crits, r.damageLines), glancingRate = rate(r.glancing, r.damageLines),
      ultraslayRate = rate(r.ultraslay, r.damageLines), misses = r.misses,
      focus = r.focusCasts > 0 and r.focus / r.focusCasts or nil,
    }
  end
  table.sort(list, function(a, b)
    if a.damage ~= b.damage then return a.damage > b.damage end
    return a.name < b.name
  end)
  return list
end

function Model.Types(s)
  local list = {}
  for k, v in pairs(s.types) do list[#list + 1] = { type = k, damage = v, share = rate(v, s.total) } end
  table.sort(list, function(a, b) if a.damage ~= b.damage then return a.damage > b.damage end return a.type < b.type end)
  return list
end

-- Every number at `now`, as plain tables: a Build Tester snapshot, the test
-- history and the export use it.
function Model.Summary(s, now)
  local dur = Model.Duration(s, now)
  local out = {
    seconds = math.floor(dur + 0.5),
    damage = math.floor(s.total + 0.5), dps = Model.Dps(s, now), peakDps = Model.Peak(s, now),
    you = math.floor(s.you + 0.5), pet = math.floor(s.pet + 0.5),
    critRate = rate(s.crits, s.damageLines), glancingRate = rate(s.glancing, s.damageLines),
    ultraslayRate = rate(s.ultraslay, s.damageLines), missRate = rate(s.misses, s.damageLines + s.misses),
    castsPerMinute = s.activations / (dur / 60),
    petAttackInterval = s.petIntervals > 0 and s.petIntervalSum / s.petIntervals or nil,
    focusSpent = math.floor(s.focusSpent + 0.5),
    skills = Model.Skills(s, now), types = {}, combos = {}, decks = {},
  }
  for _, t in ipairs(Model.Types(s)) do out.types[#out.types + 1] = { type = t.type, damage = math.floor(t.damage + 0.5), share = t.share } end
  for name, c in pairs(s.combos) do out.combos[#out.combos + 1] = { name = name, uses = c.uses, damage = math.floor(c.damage + 0.5), runeId = c.runeId } end
  for name, c in pairs(s.specials) do out.combos[#out.combos + 1] = { name = name, uses = c.uses, damage = math.floor(c.damage + 0.5), runeId = c.runeId, other = true } end
  for name, d in pairs(s.decks) do out.decks[#out.decks + 1] = { name = name, damage = math.floor(d.damage + 0.5), seconds = math.floor(d.seconds + 0.5) } end
  table.sort(out.combos, function(a, b) return a.damage > b.damage end)
  table.sort(out.decks, function(a, b) return a.damage > b.damage end)
  return out
end

-- TotA Meter: Build Tester KPIs (owner's list of 2026-10-30, formulas in the
-- project doc "build-tester-kpis.md"). Pure Lua: computed from a run's record
-- (model.lua, Model.NewRecord) and its deck layouts, no game calls.
--
-- Spans: three windows (0-1, 1-3, 3-5 min) and three cumulative checkpoints
-- (@1, @3, @5, from the first hit). A span still running is computed on the
-- seconds it has so far (`live`). Damage = you + your pet, combos and ticks
-- included (owner, 2026-10-30). A cast = one of your skills or combos;
-- pet attacks are not casts.

local M = TotaMeter
local Kpi = {}
M.Kpi = Kpi

Kpi.SPANS = {
  { key = "w1", label = "0-1", from = 0, to = 60, windows = { 1 } },
  { key = "w2", label = "1-3", from = 60, to = 180, windows = { 2 } },
  { key = "w3", label = "3-5", from = 180, to = 300, windows = { 3 } },
  { key = "c1", label = "@1", from = 0, to = 60, windows = { 1 }, cumulative = true },
  { key = "c3", label = "@3", from = 0, to = 180, windows = { 1, 2 }, cumulative = true },
  { key = "c5", label = "@5", from = 0, to = 300, windows = { 1, 2, 3 }, cumulative = true },
}
-- Kill Clock damage levels (owner, 2026-11-05: 25k / 75k / 150k; 10k / 25k /
-- 50k up to 1.1.1, which the site still reads for runs made with those).
Kpi.KILL = { 25000, 75000, 150000 }
Kpi.ROTATION_SHARE = 0.75
Kpi.STARVED = 0.10
Kpi.RAMP = 0.90

local floor, max, min, sqrt = math.floor, math.max, math.min, math.sqrt

local function sum(a, from, to) local s = 0 for i = from, to - 1 do s = s + (a[i] or 0) end return s end
local function div(a, b) if type(a) ~= "number" or type(b) ~= "number" or b == 0 then return nil end return a / b end

-- Per-skill sums of a span (windows added up), most damage first.
function Kpi.Skills(rec, span)
  local by, list = {}, {}
  for _, w in ipairs(span.windows) do
    for key, k in pairs(rec.win[w] or {}) do
      local t = by[key]
      if not t then
        t = { key = key, name = k.name, owner = k.owner, runeId = k.runeId, skillId = k.runeId, damage = 0, hitSum = 0, hitN = 0, critSum = 0, critN = 0,
          glancing = 0, ultraslay = 0, uses = 0, focus = 0, focusCasts = 0 }
        by[key] = t
        list[#list + 1] = t
      end
      if k.special then t.special = true end
      for _, f in ipairs({ "damage", "hitSum", "hitN", "critSum", "critN", "glancing", "ultraslay", "uses", "focus", "focusCasts" }) do
        t[f] = t[f] + (k[f] or 0)
      end
    end
  end
  for _, t in ipairs(list) do
    t.avgHit = div(t.hitSum, t.hitN)
    t.avgCrit = div(t.critSum, t.critN)
    t.critPower = (t.avgHit and t.avgCrit) and t.avgCrit / t.avgHit or nil
    t.critRate = div(t.critN, t.hitN + t.critN + t.glancing + t.ultraslay)
    t.focusPerCast = div(t.focus, t.focusCasts)
    -- damage per focus: the skill's damage over the focus its casts cost (estimated)
    t.damagePerFocus = (t.focusPerCast and t.uses > 0) and div(t.damage, t.focusPerCast * t.uses) or nil
  end
  table.sort(list, function(a, b) if a.damage ~= b.damage then return a.damage > b.damage end return a.name < b.name end)
  return list
end

-- The deck sets the layouts give: every rune id, the ids only in locked
-- slots, the ids both locked and in the pool, and the names.
function Kpi.DeckSets(layouts)
  local all, locked, pool, names = {}, {}, {}, {}
  for _, d in ipairs(layouts or {}) do
    for _, id in ipairs(d.pool or {}) do pool[id] = true; all[id] = true end
    for _, id in ipairs(d.locked or {}) do locked[id] = true; all[id] = true end
    for id, n in pairs(d.names or {}) do names[id] = n end
  end
  local lockedOnly, both = {}, {}
  for id in pairs(locked) do if pool[id] then both[id] = true else lockedOnly[id] = true end end
  local count = 0
  for _ in pairs(all) do count = count + 1 end
  return { all = all, count = count, lockedOnly = lockedOnly, both = both, names = names }
end

-- Everything for one span. `elapsed` = seconds the run has (300 when done).
function Kpi.Span(rec, span, elapsed, ctx)
  local a = span.from
  local b = min(span.to, max(span.from, floor(elapsed)))
  local T = b - a
  local r = { key = span.key, label = span.label, seconds = T, live = elapsed < span.to }
  if T <= 0 then r.empty = true return r end
  local damage = sum(rec.dmg, a, b)
  r.damage = damage
  r.dps = damage / T

  -- Peak Burst: best 5-second span inside the window
  local best = nil
  if T >= 5 then
    local roll = sum(rec.dmg, a, a + 5)
    best = roll
    for j = a + 5, b - 1 do
      roll = roll + (rec.dmg[j] or 0) - (rec.dmg[j - 5] or 0)
      if roll > best then best = roll end
    end
    best = best / 5
  else best = damage / T end
  r.peakBurst = best

  -- Opener DPS (first 10 s), Ramp-up and Kill Clock: from the first hit
  if a == 0 and b >= 10 then r.opener = sum(rec.dmg, 0, 10) / 10 end
  if span.cumulative then
    local target = Kpi.RAMP * r.dps
    local rolling = 0
    for t = 0, b - 1 do
      rolling = rolling + (rec.dmg[t] or 0) - (t >= 5 and (rec.dmg[t - 5] or 0) or 0)
      if t >= 4 and rolling / 5 >= target and target > 0 then r.rampUp = t + 1 break end
    end
    r.killClock = {}
    local cum = 0
    for t = 0, b - 1 do
      cum = cum + (rec.dmg[t] or 0)
      for n, need in ipairs(Kpi.KILL) do
        if not r.killClock[n] and cum >= need then r.killClock[n] = t + 1 end
      end
    end
  end

  -- Hit quality
  local skills = Kpi.Skills(rec, span)
  r.skills = skills
  local hitSum, hitN, critSum, critN, other, powerNum, powerDen, gain = 0, 0, 0, 0, 0, 0, 0, 0
  for _, k in ipairs(skills) do
    hitSum, hitN = hitSum + k.hitSum, hitN + k.hitN
    critSum, critN = critSum + k.critSum, critN + k.critN
    other = other + k.glancing + k.ultraslay
    if k.avgHit and k.critN > 0 then
      powerNum = powerNum + k.critSum
      powerDen = powerDen + k.critN * k.avgHit
      gain = gain + (k.critSum - k.critN * k.avgHit)
    end
  end
  r.avgHit = div(hitSum, hitN)
  r.avgCrit = div(critSum, critN)
  r.critPower = div(powerNum, powerDen)
  r.critRate = div(critN, hitN + critN + other)
  r.critGain = damage > 0 and gain / damage or nil

  -- Rhythm and usability
  local casts = sum(rec.casts, a, b)
  r.casts = casts
  r.tempo = casts / (T / 60)
  local best10 = 0
  local n = min(rec.n, max(0, floor(elapsed)))
  local roll = 0
  for j = 0, n - 1 do
    roll = roll + (rec.casts[j] or 0) - (j >= 10 and (rec.casts[j - 10] or 0) or 0)
    if roll > best10 then best10 = roll end
  end
  r.tempoEfficiency = best10 > 0 and r.tempo / (best10 * 6) or nil
  local times = {}
  for _, ct in ipairs(rec.castTimes) do if ct >= a and ct < b then times[#times + 1] = ct end end
  if #times >= 2 then
    local total, longest = 0, 0
    for i = 2, #times do
      local g = times[i] - times[i - 1]
      total = total + g
      if g > longest then longest = g end
    end
    r.castGap = total / (#times - 1)
    r.castGapMax = longest
  end
  local deck = ctx and ctx.deck
  if deck and deck.count > 0 then
    local used, unused = 0, {}
    local cast = {}
    for _, k in ipairs(skills) do if k.owner == "You" and k.runeId and k.uses > 0 then cast[k.runeId] = true end end
    for id in pairs(deck.all) do
      if cast[id] then used = used + 1 else unused[#unused + 1] = deck.names[id] or ("#" .. id) end
    end
    table.sort(unused)
    r.deckUse = used / deck.count
    r.unused = unused
    r.deckRunes = {}
    for id in pairs(deck.all) do r.deckRunes[#r.deckRunes + 1] = { id = id, cast = cast[id] == true } end
    table.sort(r.deckRunes, function(x, y) return x.id < y.id end)
    local lockedDmg, bothDmg = 0, 0
    for _, k in ipairs(skills) do
      if k.owner == "You" and k.runeId then
        if deck.lockedOnly[k.runeId] then lockedDmg = lockedDmg + k.damage
        elseif deck.both[k.runeId] then bothDmg = bothDmg + k.damage end
      end
    end
    r.lockedShare = div(lockedDmg, damage)
    r.bothShare = div(bothDmg, damage)
  end
  local acc, depth = 0, 0
  for _, k in ipairs(skills) do
    if damage <= 0 or acc >= Kpi.ROTATION_SHARE * damage then break end
    acc = acc + k.damage
    depth = depth + 1
  end
  r.rotationDepth = damage > 0 and depth or nil
  r.altShare = div(sum(rec.altDmg, a, b), damage)
  r.altTime = sum(rec.altSecs, a, b) / T
  local swaps = 0
  for _, sw in ipairs(rec.swaps) do if sw >= a and sw < b then swaps = swaps + 1 end end
  r.swaps = swaps

  -- Stability: full 5-second slices
  local slices = {}
  for j = a, b - 5, 5 do slices[#slices + 1] = sum(rec.dmg, j, j + 5) / 5 end
  if #slices >= 2 then
    local mean, lo, hi = 0, nil, nil
    for _, d in ipairs(slices) do
      mean = mean + d
      if not lo or d < lo then lo = d end
      if not hi or d > hi then hi = d end
    end
    mean = mean / #slices
    local var = 0
    for _, d in ipairs(slices) do var = var + (d - mean) ^ 2 end
    local sd = sqrt(var / #slices)
    if mean > 0 then
      r.consistency = max(0, 1 - sd / mean)
      r.spread = (hi - lo) / mean
    end
  end
  local down, run, longest = 0, 0, 0
  for i = a, b - 1 do
    if (rec.dmg[i] or 0) <= 0 then
      down = down + 1
      run = run + 1
      if run > longest then longest = run end
    else run = 0 end
  end
  r.downtime = down
  r.downtimeMax = longest

  -- Focus
  local spent, gained = sum(rec.spent, a, b), sum(rec.gained, a, b)
  r.focusSpent = spent
  r.focusPerMinute = spent / (T / 60)
  r.focusBalance = (gained - spent) / T
  r.starved = sum(rec.starved, a, b)
  r.damagePerFocus = div(damage, spent)
  local claimed, claims = 0, 0
  for _, k in ipairs(skills) do claimed, claims = claimed + k.focus, claims + k.focusCasts end
  r.focusPerCast = div(claimed, claims)
  if span.cumulative and not r.live and rec.maxFocus > 0 then
    local last = nil
    for i = b - 1, max(a, b - 5), -1 do if rec.focus[i] then last = rec.focus[i] break end end
    if last then r.focusLevel = last / rec.maxFocus; r.focusAt = last end
  end
  return r
end

-- Every span, plus the cross-window KPIs (Hold Ratio, Trend, Runway).
function Kpi.Compute(rec, elapsed, layouts, altDeck)
  -- the Alt deck's runes count for Deck Use only when the run used it
  local used = {}
  local onAlt = sum(rec.altSecs, 0, rec.n) > 0 or #rec.swaps > 0
  for _, d in ipairs(layouts or {}) do
    if onAlt or not altDeck or d.name ~= altDeck then used[#used + 1] = d end
  end
  local ctx = { deck = Kpi.DeckSets(used) }
  local out = {}
  for _, span in ipairs(Kpi.SPANS) do out[span.key] = Kpi.Span(rec, span, elapsed, ctx) end
  local w1, w2, w3 = out.w1, out.w2, out.w3
  if w1.dps and w1.dps > 0 and not w1.live then
    if w2.dps then w2.holdRatio = w2.dps / w1.dps; w2.trend = w2.dps / w1.dps - 1 end
    if w3.dps then w3.holdRatio = w3.dps / w1.dps end
  end
  if w2.dps and w2.dps > 0 and not w2.live and w3.dps then w3.trend = w3.dps / w2.dps - 1 end
  -- Focus Runway: at the 3-5 pace, from the focus at 5:00
  local c5 = out.c5
  if not c5.live and c5.focusAt and w3.focusBalance then
    c5.runway = (w3.focusBalance < 0) and (max(0, c5.focusAt) / -w3.focusBalance) or math.huge
    w3.runway = c5.runway
  end
  return out
end

-- ---------------------------------------------------------------------------
-- The KPI rows the Build Tester tab shows: { id, name, tooltip, icon, cell(r) }.
-- cell returns the text of one span ("" = not shown for that span).
-- ---------------------------------------------------------------------------

local function num(v) return v and M.Num(v) or "-" end
local function pct(v) return v and (M.Num(v * 100) .. "%") or "-" end
local function secs(v) return v and (M.Dec(v) .. " s") or "-" end
local function clock(v) return v and M.Clock(v) or "-" end
local function signed(v) if not v then return "-" end return (v >= 0 and "+" or "") .. M.Num(v * 100) .. "%" end
local function w(fn) return function(r) if r.key:sub(1, 1) ~= "w" then return "" end return fn(r) end end
local function c(fn) return function(r) if r.key:sub(1, 1) ~= "c" then return "" end return fn(r) end end
local function kill(n) return c(function(r)
  local v = r.killClock and r.killClock[n]
  if v then return M.Clock(v) end
  return "> " .. M.Clock(r.seconds)
end) end

Kpi.GROUPS = {
  { "Damage", {
    { "dps", "DPS", "Damage per second from you and your pet in this window.", function(r) return num(r.dps) end },
    { "peakBurst", "Peak Burst", "Your best 5 seconds of damage, per second.", function(r) return num(r.peakBurst) end },
    { "opener", "Opener DPS", "Damage per second over your first 10 seconds: how hard you open a fight.",
      function(r) return (r.key == "w1" or r.key == "c1") and num(r.opener) or "" end },
    { "rampUp", "Ramp-up Time", "Seconds until your 5-second DPS first reaches 90% of the DPS at this checkpoint.",
      c(function(r) return r.rampUp and (r.rampUp .. " s") or "-" end) },
    { "killClock", "Kill Clock 25k", "Seconds to deal 25,000 damage: how fast you'd kill a creature with that much health.", kill(1) },
    { "killClock", "Kill Clock 75k", "Seconds to deal 75,000 damage: how fast you'd kill a creature with that much health.", kill(2) },
    { "killClock", "Kill Clock 150k", "Seconds to deal 150,000 damage: how fast you'd kill a creature with that much health.", kill(3) },
  } },
  { "Hit quality", {
    { "avgHit", "Average Hit", "Average damage of your normal hits (per skill below).", function(r) return num(r.avgHit) end },
    { "avgCrit", "Average Crit", "Average damage of your critical hits (per skill below).", function(r) return num(r.avgCrit) end },
    { "critPower", "Crit Power", "How much harder a crit lands than a normal hit (average crit / average hit).",
      function(r) return r.critPower and ("x" .. M.Dec(r.critPower)) or "-" end },
    { "critRate", "Crit Rate", "Share of your damaging hits that were critical.", function(r) return pct(r.critRate) end },
    { "critGain", "Crit Gain", "Share of your damage that came from crits hitting harder than normal hits.", function(r) return pct(r.critGain) end },
  } },
  { "Rhythm and usability", {
    { "tempo", "Tempo", "Casts per minute.", function(r) return r.tempo and M.Dec(r.tempo) or "-" end },
    { "tempoEfficiency", "Tempo Efficiency", "Your casts per minute against the best 10-second pace you reached this run.",
      function(r) return pct(r.tempoEfficiency) end },
    { "castGap", "Cast Gap", "Average seconds between two casts; the longest gap beside it.",
      function(r) return r.castGap and (M.Dec(r.castGap) .. " s (" .. M.Dec(r.castGapMax) .. ")") or "-" end },
    { "deckUse", "Deck Use", "Share of the runes in your deck you actually cast; unused runes are listed under the skills.",
      function(r) return pct(r.deckUse) end },
    { "rotationDepth", "Rotation Depth", "How many skills make up 75% of your damage (1-2 = the build relies on a few skills).",
      function(r) return r.rotationDepth and tostring(r.rotationDepth) or "-" end },
    { "lockedShare", "Locked Share", "Part of your damage from glyphs in locked slots; the rest comes from drawn glyphs, combos and your pet.",
      function(r) return r.lockedShare and (pct(r.lockedShare) .. ((r.bothShare or 0) > 0 and (" (+" .. pct(r.bothShare) .. ")") or "")) or "-" end },
    { "altShare", "Alt Deck Share", "Part of the damage and of the time on your Alt deck, and how many swaps.",
      function(r) return r.altShare and (pct(r.altShare) .. " / " .. pct(r.altTime) .. " / " .. r.swaps) or "-" end },
  } },
  { "Stability", {
    { "consistency", "Consistency", "How even your damage is from one 5-second slice to the next; 100% = perfectly even.",
      function(r) return pct(r.consistency) end },
    { "spread", "Spread", "Gap between your best and worst 5-second slice, as a share of your average.", function(r) return pct(r.spread) end },
    { "downtime", "Downtime", "Seconds without damage from you or your pet; the longest stretch beside it.",
      function(r) return r.downtime and (r.downtime .. " s (" .. r.downtimeMax .. ")") or "-" end },
    { "holdRatio", "Hold Ratio", "DPS of this window against the first minute: 100% = no drop after the burst.",
      w(function(r) if r.key == "w1" then return "" end return pct(r.holdRatio) end) },
    { "trend", "Trend", "DPS change from the previous window.",
      w(function(r) if r.key == "w1" then return "" end return signed(r.trend) end) },
  } },
  { "Focus and sustainability", {
    { "focusSpent", "Focus Spent", "Focus your casts used in this window, and per minute.",
      function(r) return r.focusSpent and (num(r.focusSpent) .. " (" .. num(r.focusPerMinute) .. "/min)") or "-" end },
    { "focusLevel", "Focus Level", "Your focus at 1, 3 and 5 minutes, as a share of your maximum.", c(function(r) return pct(r.focusLevel) end) },
    { "focusBalance", "Focus Balance", "Focus regained minus focus spent, per second. Below zero, your bar is emptying.",
      function(r) return r.focusBalance and (((r.focusBalance >= 0) and "+" or "") .. M.Dec(r.focusBalance) .. "/s") or "-" end },
    { "focusRunway", "Focus Runway", "At your 3-5 minute pace, how long until your focus runs dry (never = it doesn't).",
      function(r) if r.key ~= "c5" then return "" end
        if not r.runway then return "-" end
        if r.runway == math.huge then return "never" end
        return "+" .. M.Clock(r.runway) end },
    { "starved", "Starved Time", "Seconds below 10% focus, when your casts are likely to fail.", function(r) return secs(r.starved) end },
    { "damagePerFocus", "Damage per Focus", "Damage dealt for each point of focus spent (your pet's damage included; per skill below).",
      function(r) return r.damagePerFocus and M.Dec(r.damagePerFocus) or "-" end },
    { "focusPerCast", "Focus per Cast", "Average focus a cast costs (estimated; per skill below).",
      function(r) return r.focusPerCast and M.Dec(r.focusPerCast) or "-" end },
  } },
}

-- A compact copy of the numbers for the saved history and the export file.
function Kpi.Saved(out)
  local keep = { "seconds", "damage", "dps", "peakBurst", "opener", "rampUp", "avgHit", "avgCrit", "critPower", "critRate", "critGain",
    "casts", "tempo", "tempoEfficiency", "castGap", "castGapMax", "deckUse", "rotationDepth", "lockedShare", "bothShare",
    "altShare", "altTime", "swaps", "consistency", "spread", "downtime", "downtimeMax", "holdRatio", "trend", "focusSpent",
    "focusPerMinute", "focusLevel", "focusBalance", "starved", "damagePerFocus", "focusPerCast" }
  local saved = {}
  for key, r in pairs(out) do
    local t = {}
    for _, f in ipairs(keep) do if type(r[f]) == "number" and r[f] == r[f] then t[f] = r[f] end end
    if r.killClock then t.killClock = { r.killClock[1] or -1, r.killClock[2] or -1, r.killClock[3] or -1 } end
    if r.runway then t.runway = (r.runway == math.huge) and -1 or r.runway end
    if r.unused and #r.unused > 0 then t.unused = r.unused end
    saved[key] = t
  end
  return saved
end

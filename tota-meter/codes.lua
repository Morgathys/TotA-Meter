-- TotA Meter: the three import codes for Tools of the Avatar (owner, 2026-10-29).
-- There is no clipboard API: the player copies each code from a text box
-- (at most 1024 characters) and pastes it in the site's Import window.
--
--   Decks          TOTA1D:<Combat deck share code>[|<Alt deck share code>]
--                  (ShroudGetDeckCode, Lua API 56: the exact slot layout)
--   Adventurer XP  TOTA1A:<base64url(zlib(payload))>
--   Producer XP    TOTA1P:<base64url(zlib(payload))>
--
-- XP payload: varint skill-table version, then for each skill of the pool in
-- the table's order (skilltable.lua) one level byte (0 = not in the game's
-- list, else 1-200) and, below 200, a varint with the XP earned inside that
-- level; then a varint with the pool's total experience. Varints are
-- unsigned LEB128. Plain arithmetic only (no bit library): numbers go past
-- 2^32 (totals in the billions) and stay exact in doubles below 2^53.
-- The site's reader is src/importcodes.js in the Tools of the Avatar repo.

local M = TotaMeter
local Codes = {}
M.Codes = Codes

Codes.PREFIX = { decks = "TOTA1D:", adventurer = "TOTA1A:", producer = "TOTA1P:" }
Codes.MAX_LENGTH = 1024   -- what a UI.TextField holds
Codes.NEEDS_API = 56      -- ShroudGetDeckCode / ShroudCurrentDeck("alternate")

local floor = math.floor

-- ---------------------------------------------------------------------------
-- Bytes
-- ---------------------------------------------------------------------------

local function varint(out, n)
  n = floor(n)
  if n < 0 then n = 0 end
  while n >= 128 do
    out[#out + 1] = (n % 128) + 128
    n = floor(n / 128)
  end
  out[#out + 1] = n
end
Codes.Varint = varint

-- Bit writer, least significant bit first (DEFLATE order).
local function bitWriter()
  local w = { bytes = {}, acc = 0, n = 0 }
  function w.put(value, count)
    local mul = 1
    for _ = 1, w.n do mul = mul * 2 end
    w.acc = w.acc + value * mul
    w.n = w.n + count
    while w.n >= 8 do
      w.bytes[#w.bytes + 1] = w.acc % 256
      w.acc = floor(w.acc / 256)
      w.n = w.n - 8
    end
  end
  -- Huffman codes are sent most significant bit first.
  function w.code(code, len)
    local rev = 0
    for _ = 1, len do
      rev = rev * 2 + code % 2
      code = floor(code / 2)
    end
    w.put(rev, len)
  end
  function w.flush()
    if w.n > 0 then w.bytes[#w.bytes + 1] = w.acc % 256; w.acc = 0; w.n = 0 end
    return w.bytes
  end
  return w
end

-- ---------------------------------------------------------------------------
-- zlib (RFC 1950) with one DEFLATE block of fixed Huffman codes (RFC 1951)
-- ---------------------------------------------------------------------------

local LBASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEXT = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DBASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
  4097, 6145, 8193, 12289, 16385, 24577 }
local DEXT = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }

local function putSymbol(w, v)   -- literal/length alphabet, fixed codes
  if v <= 143 then w.code(48 + v, 8)
  elseif v <= 255 then w.code(400 + v - 144, 9)
  elseif v <= 279 then w.code(v - 256, 7)
  else w.code(192 + v - 280, 8) end
end

local function putMatch(w, len, dist)
  local i = #LBASE
  while LBASE[i] > len do i = i - 1 end
  putSymbol(w, 256 + i)
  if LEXT[i] > 0 then w.put(len - LBASE[i], LEXT[i]) end
  local d = #DBASE
  while DBASE[d] > dist do d = d - 1 end
  w.code(d - 1, 5)
  if DEXT[d] > 0 then w.put(dist - DBASE[d], DEXT[d]) end
end

local MIN_MATCH, MAX_MATCH, WINDOW, CHAIN = 3, 258, 32768, 64

-- data: list of byte values. Returns the zlib stream as a list of bytes.
function Codes.Zlib(data)
  local w = bitWriter()
  w.put(1, 1)   -- BFINAL
  w.put(1, 2)   -- BTYPE 01: fixed Huffman codes
  local heads, prev = {}, {}
  local n = #data
  local function key(i) return (data[i] * 256 + data[i + 1]) * 256 + data[i + 2] end
  local function insert(i)
    if i + 2 <= n then
      local k = key(i)
      prev[i] = heads[k]
      heads[k] = i
    end
  end
  local i = 1
  while i <= n do
    local bestLen, bestDist = 0, 0
    if i + 2 <= n then
      local cand, tries = heads[key(i)], 0
      while cand and i - cand <= WINDOW and tries < CHAIN do
        local len = 0
        while len < MAX_MATCH and i + len <= n and data[cand + len] == data[i + len] do len = len + 1 end
        if len > bestLen then bestLen, bestDist = len, i - cand end
        if len == MAX_MATCH then break end
        cand = prev[cand]
        tries = tries + 1
      end
    end
    if bestLen >= MIN_MATCH then
      putMatch(w, bestLen, bestDist)
      for j = i, i + bestLen - 1 do insert(j) end
      i = i + bestLen
    else
      putSymbol(w, data[i])
      insert(i)
      i = i + 1
    end
  end
  putSymbol(w, 256)   -- end of block
  local body = w.flush()
  local out = { 0x78, 0x01 }
  for _, b in ipairs(body) do out[#out + 1] = b end
  local a, b = 1, 0
  for _, v in ipairs(data) do
    a = (a + v) % 65521
    b = (b + a) % 65521
  end
  out[#out + 1] = floor(b / 256); out[#out + 1] = b % 256
  out[#out + 1] = floor(a / 256); out[#out + 1] = a % 256
  return out
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

function Codes.Base64url(bytes)
  local out = {}
  local n = #bytes
  for i = 1, n, 3 do
    local b1, b2, b3 = bytes[i], bytes[i + 1] or 0, bytes[i + 2] or 0
    local v = (b1 * 256 + b2) * 256 + b3
    local c = { floor(v / 262144) % 64, floor(v / 4096) % 64, floor(v / 64) % 64, v % 64 }
    local keep = (i + 2 <= n) and 4 or ((i + 1 <= n) and 3 or 2)
    for j = 1, keep do out[#out + 1] = B64:sub(c[j] + 1, c[j] + 1) end
  end
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- XP codes
-- ---------------------------------------------------------------------------

local FACTORS = { 0.5, 1, 2, 3, 4, 5, 6, 8, 10, 20 }

-- XP earned inside the skill's trained level. The game gives the total
-- (experience) and what is left to the next level (experienceForNext); the
-- skill's factor is measured from their sum (= factor x the x1 total at the
-- next level, exact for every skill in the owner's export of 2026-10-28), so
-- a factor the site has wrong can't shift the level's start.
function Codes.InsideXp(skill, level, x1)
  local exp, rem = tonumber(skill.experience), tonumber(skill.experienceForNext)
  if not exp or exp <= 0 then return 0 end
  if level < 1 or level >= 200 then return 0 end
  local start = 0
  if rem and rem >= 0 and x1[level + 1] and x1[level + 1] > 0 then
    local stop = exp + rem
    local best, bestDiff = 1, nil
    for _, f in ipairs(FACTORS) do
      local diff = math.abs(f * x1[level + 1] - stop)
      if not bestDiff or diff < bestDiff then best, bestDiff = f, diff end
    end
    start = floor(best * x1[level] + 0.5)
  else
    return 0
  end
  local inside = exp - start
  if inside < 0 then inside = 0 end
  return floor(inside)
end

local TOTAL = {
  adventurer = function() return ShroudGetTotalAdventurerExperience and ShroudGetTotalAdventurerExperience() end,
  producer = function() return ShroudGetTotalProducerExperience and ShroudGetTotalProducerExperience() end,
}

-- kind: "adventurer" | "producer". skills: ShroudGetSkills() (optional).
-- Returns code, info { skills = trained skills listed, missing = game skills
-- of no table } or nil, message.
function Codes.Xp(kind, skills)
  local T = M.SkillTable
  if not T or not T[kind] then return nil, "The skill table is missing: reinstall TotA Meter." end
  skills = skills or ShroudGetSkills()
  if type(skills) ~= "table" then return nil, "Your skills aren't loaded yet: try again in a moment." end
  local byId = {}
  for _, s in ipairs(skills) do
    if type(s) == "table" and type(s.id) == "number" then byId[s.id] = s end
  end
  local out = {}
  varint(out, T.version)
  local listed = 0
  for _, id in ipairs(T[kind]) do
    local s = byId[id]
    local level = s and floor(tonumber(s.trainedLevel) or 0) or 0
    if level > 200 then level = 200 end
    if level < 1 then
      out[#out + 1] = 0
    else
      listed = listed + 1
      out[#out + 1] = level
      if level < 200 then varint(out, Codes.InsideXp(s, level, T.x1)) end
    end
  end
  local okTotal, total = pcall(TOTAL[kind])
  varint(out, (okTotal and tonumber(total)) or 0)
  local code = Codes.PREFIX[kind] .. Codes.Base64url(Codes.Zlib(out))
  -- skills the game lists that no table knows (added to the game after this
  -- version of the add-on): they can't be sent; say how many.
  local known = {}
  for _, id in ipairs(T.adventurer) do known[id] = true end
  for _, id in ipairs(T.producer) do known[id] = true end
  local missing = 0
  for id in pairs(byId) do if not known[id] then missing = missing + 1 end end
  if #code > Codes.MAX_LENGTH then
    return nil, "The code is " .. #code .. " characters, more than the box holds (" .. Codes.MAX_LENGTH .. "). Please tell Tools of the Avatar."
  end
  return code, { skills = listed, missing = missing }
end

-- ---------------------------------------------------------------------------
-- Decks code
-- ---------------------------------------------------------------------------

local REASONS = {
  no_such_deck = "no deck has that name",
  ambiguous_name = "several decks have that name: rename one in game",
  not_loaded = "your decks aren't loaded yet",
}

function Codes.HasDeckApi()
  return type(ShroudGetDeckCode) == "function" and (tonumber(ShroudLuaApiVersion) or 0) >= Codes.NEEDS_API
end

-- combat: deck name (required); alt: deck name or nil. Returns code or nil, message.
function Codes.Decks(combat, alt)
  if not Codes.HasDeckApi() then
    return nil, "The Decks code needs the game's Lua API " .. Codes.NEEDS_API .. " (yours is " .. tostring(ShroudLuaApiVersion) ..
      "). Use the export file meanwhile."
  end
  if type(combat) ~= "string" or combat == "" then return nil, "Pick your Combat deck first." end
  if alt == combat then return nil, "The Combat and Alt decks must be different." end
  local ok, c, why = pcall(ShroudGetDeckCode, combat)
  if not ok or type(c) ~= "string" then
    return nil, "Combat deck \"" .. combat .. "\": " .. (REASONS[why] or tostring(why or c or "no code")) .. "."
  end
  local code = Codes.PREFIX.decks .. c
  if alt and alt ~= "" then
    local ok2, a, why2 = pcall(ShroudGetDeckCode, alt)
    if not ok2 or type(a) ~= "string" then
      return nil, "Alt deck \"" .. alt .. "\": " .. (REASONS[why2] or tostring(why2 or a or "no code")) .. "."
    end
    code = code .. "|" .. a
  end
  if #code > Codes.MAX_LENGTH then return nil, "The Decks code is longer than the box holds: shorten the deck names." end
  return code
end

-- The alternate deck's name (the one the swap key switches to), or nil.
function Codes.AlternateDeckName()
  if not Codes.HasDeckApi() then return nil end
  local ok, d = pcall(ShroudCurrentDeck, "alternate")
  if not ok or not d then return nil end
  local ok2, n = pcall(function() return d.name end)
  return (ok2 and type(n) == "string" and n ~= "") and n or nil
end

-- ---------------------------------------------------------------------------
-- Build Tester code (0.8.0): one saved run for the site's Metrics & KPIs.
--   TOTA1T:<base64url(zlib(payload))>, or, past MAX_PART characters, two
--   parts "TOTA1T:1/2.<id>.<chunk>" and "TOTA1T:2/2.<id>.<chunk>" (id = 4
--   characters shared by the parts; the chunks put together are the code).
-- Payload (version 1), varints unless said; a "value" is 0 when absent, else
-- zigzag(round(v * scale)) + 1:
--   1, flags (1 = full 5:00, 2 = deck codes known), addon version (string),
--   run date (string), Combat deck name, its code's Adler-32 + 1 (0 = none),
--   Alt deck name, its Adler-32 + 1, max focus, attack speed x100, melee crit
--   and spell crit in thousandths, potions/food count, lines dropped;
--   spans (6: w1 w2 w3 c1 c3 c5), fields (count), then values span by span in
--   Codes.TEST_FIELDS order; slices (count), then per slice damage, casts,
--   focus spent, focus regained, focus level thousandths + 1 (0 = none), and
--   a bit set of the slices on the Alt deck; skills (count), each kind (0 skill,
--   1 combo or other rune, 2 pet attack, 3 the rest summed), rune id, name
--   (string, empty for kind 0), damage, hit sum, hits, crit sum, crits, uses,
--   claimed focus, casts that claimed focus; deck runes (count), each
--   id * 2 + cast (1 = cast at least once).
-- A string is a varint length then its bytes. The site's reader:
-- src/kpicodes.js in the Tools of the Avatar repo (same field list).
-- ---------------------------------------------------------------------------

Codes.TEST_VERSION = 1
Codes.MAX_PART = 1000
Codes.TEST_SPANS = { "w1", "w2", "w3", "c1", "c3", "c5" }
Codes.TEST_FIELDS = {
  { "dps", 1 }, { "peakBurst", 1 }, { "opener", 1 }, { "rampUp", 1 }, { "kill1", 1 }, { "kill2", 1 }, { "kill3", 1 },
  { "avgHit", 1 }, { "avgCrit", 1 }, { "critPower", 100 }, { "critRate", 1000 }, { "critGain", 1000 },
  { "tempo", 10 }, { "tempoEfficiency", 1000 }, { "castGap", 10 }, { "castGapMax", 10 }, { "deckUse", 1000 },
  { "rotationDepth", 1 }, { "lockedShare", 1000 }, { "bothShare", 1000 }, { "altShare", 1000 }, { "altTime", 1000 },
  { "swaps", 1 }, { "consistency", 1000 }, { "spread", 1000 }, { "downtime", 1 }, { "downtimeMax", 1 },
  { "holdRatio", 1000 }, { "trend", 1000 }, { "focusSpent", 1 }, { "focusPerMinute", 1 }, { "focusLevel", 1000 },
  { "focusBalance", 10 }, { "runway", 1 }, { "starved", 10 }, { "damagePerFocus", 100 }, { "focusPerCast", 10 },
}

local function str(out, s)
  s = tostring(s or "")
  if #s > 120 then s = s:sub(1, 120) end
  varint(out, #s)
  for i = 1, #s do out[#out + 1] = s:byte(i) end
end

local function value(out, v, scale)
  if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = 0 return end
  local n = floor(v * (scale or 1) + 0.5)
  local z = (n >= 0) and (2 * n) or (-2 * n - 1)
  varint(out, z + 1)
end

local function adler(s)
  local a, b = 1, 0
  for i = 1, #s do a = (a + s:byte(i)) % 65521; b = (b + a) % 65521 end
  return b * 65536 + a
end
Codes.Adler = adler

-- The payload bytes of a saved run (M.tests entry).
function Codes.TestPayload(run)
  local out = {}
  varint(out, Codes.TEST_VERSION)
  local codes = run.deckCodes or {}
  local combat, alt = nil, nil
  for _, d in ipairs(codes) do if d.alt then alt = d else combat = combat or d end end
  varint(out, (run.stopped and 0 or 1) + ((#codes > 0) and 2 or 0))
  str(out, M.VERSION)
  str(out, run.when)
  str(out, combat and combat.name or "")
  varint(out, combat and (adler(combat.code) + 1) or 0)
  str(out, alt and alt.name or "")
  varint(out, alt and (adler(alt.code) + 1) or 0)
  local st = run.stats or {}
  varint(out, floor(tonumber(run.maxFocus) or 0))
  value(out, st.AttackSpeed, 100)
  value(out, st.WeaponCritBonus, 1000)
  value(out, st.SpellCriticalChanceBonus, 1000)
  varint(out, #(st.consumables or {}))
  varint(out, floor(tonumber(run.dropped) or 0))
  local k = run.kpis or {}
  varint(out, #Codes.TEST_SPANS)
  varint(out, #Codes.TEST_FIELDS)
  for _, span in ipairs(Codes.TEST_SPANS) do
    local r = k[span] or {}
    for _, f in ipairs(Codes.TEST_FIELDS) do
      local v = r[f[1]]
      local kc = r.killClock
      if f[1] == "kill1" then v = kc and kc[1] elseif f[1] == "kill2" then v = kc and kc[2] elseif f[1] == "kill3" then v = kc and kc[3] end
      if (f[1]:sub(1, 4) == "kill") and type(v) == "number" and v < 0 then v = nil end
      value(out, v, f[2])
    end
  end
  local tl = run.timeline or {}
  varint(out, #tl)
  for _, sl in ipairs(tl) do
    varint(out, floor((sl.d or 0) + 0.5)); varint(out, sl.c or 0)
    varint(out, floor((sl.sp or 0) + 0.5)); varint(out, floor((sl.g or 0) + 0.5))
    varint(out, sl.f and (sl.f + 1) or 0)
  end
  local byte, bit = 0, 1
  for i, sl in ipairs(tl) do
    if sl.alt then byte = byte + bit end
    bit = bit * 2
    if bit == 256 or i == #tl then out[#out + 1] = byte; byte, bit = 0, 1 end
  end
  local sk = run.skills or {}
  varint(out, #sk)
  for _, s in ipairs(sk) do
    varint(out, s.kind or 0); varint(out, s.id or 0); str(out, (s.kind or 0) ~= 0 and s.name or "")
    for _, f in ipairs({ "damage", "hitSum", "hitN", "critSum", "critN", "uses", "focus", "focusCasts" }) do
      varint(out, floor((tonumber(s[f]) or 0) + 0.5))
    end
  end
  local dr = run.deckRunes or {}
  varint(out, #dr)
  for _, d in ipairs(dr) do varint(out, (d.id or 0) * 2 + (d.cast and 1 or 0)) end
  return out
end

-- The code for a saved run: a list of one or two strings.
function Codes.Test(run)
  if type(run) ~= "table" or not run.kpis or not run.timeline then
    return nil, "This run was saved by an older TotA Meter: run a new Build Tester test."
  end
  local body = Codes.Base64url(Codes.Zlib(Codes.TestPayload(run)))
  local prefix = "TOTA1T:"
  if #prefix + #body <= Codes.MAX_LENGTH and #prefix + #body <= Codes.MAX_PART then return { prefix .. body } end
  local id = Codes.Base64url({ adler(body) % 256, floor(adler(body) / 256) % 256, floor(adler(body) / 65536) % 256 })
  local head = #prefix + 4 + 1 + #id + 1
  local room = Codes.MAX_PART - head
  local n = math.ceil(#body / room)
  if n > 2 then return nil, "This run is too long for two codes (" .. #body .. " characters). Please tell Tools of the Avatar." end
  local parts = {}
  for i = 1, n do
    parts[i] = prefix .. i .. "/" .. n .. "." .. id .. "." .. body:sub((i - 1) * room + 1, i * room)
  end
  return parts
end

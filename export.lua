-- TotA Meter: export to Tools of the Avatar (owner, 2026-10-27).
-- One file holds the Combat deck (required), the Alt deck (optional), the
-- skills with their XP, the specializations, the pooled XP and the last test
-- results. The player uploads it on the build page; the site validates it.
-- No character name is written (character names are private on the site).

local M = TotaMeter
local Export = {}
M.Export = Export

Export.FORMAT = "tota-export"
Export.VERSION = 1
Export.FILE = "tota_export.json"

-- Decks and cards are game objects: read fields one by one.
local function field(o, k)
  local ok, v = pcall(function() return o[k] end)
  if ok then return v end
  return nil
end

-- Deck names in the game's order, each once; and the names used twice.
-- ShroudGetDeckCardList takes a name only, so two decks with the same name
-- can't be told apart.
function Export.DeckNames()
  local names, seen, dupes = {}, {}, {}
  local list = ShroudDeckList() or {}
  for _, d in ipairs(list) do
    local n = field(d, "name")
    if type(n) == "string" and n ~= "" then
      if seen[n] then
        if seen[n] == 1 then dupes[#dupes + 1] = n end
        seen[n] = seen[n] + 1
      else
        seen[n] = 1
        names[#names + 1] = n
      end
    end
  end
  return names, dupes, seen
end

function Export.CurrentDeckName()
  local d = ShroudCurrentDeck()
  local n = d and field(d, "name") or nil
  return type(n) == "string" and n or nil
end

-- Skill lookups from ShroudGetSkills(): by display name (card names are in
-- the same language) and the set of ids.
function Export.SkillIndex()
  local byName, ids = {}, {}
  for _, s in ipairs(ShroudGetSkills() or {}) do
    if type(s.name) == "string" then byName[s.name] = s end
    if type(s.id) == "number" then ids[s.id] = true end
  end
  return byName, ids
end

-- The cards of one deck, matched to skill ids. Returns deck table, unmatched names.
local function deckTable(name, byName)
  local cards, unmatched = {}, {}
  for _, c in ipairs(ShroudGetDeckCardList(name) or {}) do
    local cname = field(c, "name")
    local qty = field(c, "quantity")
    if type(cname) == "string" then
      local skill = byName[cname]
      cards[#cards + 1] = { name = cname, copies = type(qty) == "number" and qty or 1, skillId = skill and skill.id or nil }
      if not skill then unmatched[#unmatched + 1] = cname end
    end
  end
  return { name = name, cards = (#cards > 0) and cards or M.Json.ARRAY }, unmatched
end

-- Builds the export table. combat: deck name (required); alt: deck name or nil.
-- Returns the table, or nil and a message for the player.
function Export.Build(combat, alt, includeSkills)
  local _, dupes, seen = Export.DeckNames()
  if type(combat) ~= "string" or not seen[combat] then return nil, "Pick your Combat deck first." end
  if alt and not seen[alt] then return nil, "The Alt deck \"" .. alt .. "\" was not found. Reopen the window." end
  if alt == combat then return nil, "The Combat and Alt decks must be different." end
  for _, n in ipairs(dupes) do
    if n == combat or n == alt then return nil, "Several decks are named \"" .. n .. "\": rename them in game first." end
  end

  local byName = Export.SkillIndex()
  local unmatched = {}
  local function addUnmatched(list) for _, n in ipairs(list) do unmatched[#unmatched + 1] = n end end
  local decks = {}
  local d, u = deckTable(combat, byName)
  decks.combat = d; addUnmatched(u)
  if alt then
    d, u = deckTable(alt, byName)
    decks.alt = d; addUnmatched(u)
  end

  local okInfo, info = pcall(ShroudGetClientInfo)
  if not okInfo or type(info) ~= "table" then info = {} end
  local out = {
    format = Export.FORMAT, version = Export.VERSION,
    exportedAt = tostring(ShroudServerTime or ""),
    addon = M.VERSION,
    client = { build = info.build, luaApi = ShroudLuaApiVersion, language = info.languageCode },
    decks = decks,
    unmatched = (#unmatched > 0) and unmatched or M.Json.ARRAY,
  }

  if includeSkills then
    local skills = {}
    for _, s in ipairs(ShroudGetSkills() or {}) do
      skills[#skills + 1] = { id = s.id, key = s.key, trainedLevel = s.trainedLevel, experience = s.experience,
        experienceForNext = s.experienceForNext, mode = s.mode }
    end
    out.skills = (#skills > 0) and skills or M.Json.ARRAY
    local specs = {}
    for _, sp in ipairs(ShroudGetSpecializations() or {}) do specs[#specs + 1] = sp.schoolKey or sp.school end
    out.specializations = (#specs > 0) and specs or M.Json.ARRAY
    out.xp = {
      pooledAdventurer = ShroudGetPooledAdventurerExperience(), pooledProducer = ShroudGetPooledProducerExperience(),
      totalAdventurer = ShroudGetTotalAdventurerExperience(), totalProducer = ShroudGetTotalProducerExperience(),
    }
  end
  out.tests = (#(M.tests or {}) > 0) and M.tests or M.Json.ARRAY
  return out
end

-- Writes the file in the Lua folder. Returns ok, path or message.
function Export.Write(tbl)
  local text = M.Json.Encode(tbl)
  local path = tostring(ShroudLuaPath or "") .. "/" .. Export.FILE
  local ok, err = pcall(function()
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
  end)
  if not ok then return false, "Could not write " .. path .. " (" .. tostring(err) .. ")." end
  return true, path
end

-- Build + write, for the Export button. Returns ok, message.
function Export.Run(combat, alt, includeSkills)
  local tbl, err = Export.Build(combat, alt, includeSkills)
  if not tbl then return false, err end
  local ok, where = Export.Write(tbl)
  if not ok then return false, where end
  local msg = "Saved " .. (tbl.decks.alt and "Combat and Alt decks" or "Combat deck") ..
    (includeSkills and (", " .. #tbl.skills .. " skills and XP") or "") .. " to " .. where ..
    ". Upload this file on your build's page on Tools of the Avatar."
  if #tbl.unmatched > 0 then msg = msg .. " " .. #tbl.unmatched .. " card(s) could not be matched to a skill." end
  return true, msg
end

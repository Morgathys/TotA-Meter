-- TotA Meter: shared helpers and settings.
-- Every local starts with an explicit value: some MoonSharp builds were seen
-- to keep an old value in a bare `local x`.

TotaMeter = TotaMeter or {}
local M = TotaMeter

M.VERSION = "0.7.0"

-- Slash commands (owner, 2026-10-30: /tota instead of /totameter), listed in
-- the Setup tab and in the game's /help.
M.CMD = "tota"
M.COMMAND_LIST = {
  { "/tota", "Open or close the TotA Meter window" },
  { "/tota tester start", "Start a Build Tester run: 5:00 from your first hit, KPIs at 1, 3 and 5 minutes" },
  { "/tota tester reset", "Cancel or clear the Build Tester run" },
  { "/tota export", "Open the Export tab (codes for Tools of the Avatar)" },
  { "/tota setup", "Open this Setup tab" },
  { "/tota hud", "Show or hide the HUD" },
  { "/tota debug", "Check that the meter receives and counts your combat lines" },
  { "/tota errors", "List the errors caught since the last reload" },
  { "/tota errors clear", "Forget the recorded errors" },
}
M.SLUG = "tota-meter"

-- The gauge icon shipped with the package (store icon: icon.png).
M.ICON_FILE = M.SLUG .. "/meter-48.png"
local iconTexture = nil
function M.Icon()
  if iconTexture == nil then
    local ok, tex = pcall(ShroudLoadTexture, M.ICON_FILE)
    iconTexture = (ok and type(tex) == "number") and tex or -1
  end
  return iconTexture >= 0 and iconTexture or nil
end

-- Metric icons (owner, 2026-10-28): one picture, 12 frames of 64 px side by
-- side, shown one at a time with uv (a package may ship 12 pictures at most).
M.SHEET_FILE = M.SLUG .. "/metrics.png"
M.SHEET = { "dps", "peak", "total", "duration", "crit", "casts", "pet", "missed", "focus", "glancing", "ultraslay", "rune" }
local sheetIndex = {}
for i, n in ipairs(M.SHEET) do sheetIndex[n] = i end
local sheetTexture = nil
function M.Sheet()
  if sheetTexture == nil then
    local ok, tex = pcall(ShroudLoadTexture, M.SHEET_FILE)
    sheetTexture = (ok and type(tex) == "number") and tex or -1
  end
  return sheetTexture >= 0 and sheetTexture or nil
end

-- KPI icons (0.7.0): one picture of 8 x 4 frames of 64 px (kpis.png), the
-- frames in this order, left to right then top to bottom.
M.KPI_SHEET_FILE = M.SLUG .. "/kpis.png"
M.KPI_SHEET = { "dps", "peakBurst", "opener", "rampUp", "killClock", "avgHit", "avgCrit", "critPower",
  "critRate", "critGain", "tempo", "tempoEfficiency", "castGap", "deckUse", "rotationDepth", "lockedShare",
  "altShare", "consistency", "spread", "downtime", "holdRatio", "trend", "focusSpent", "focusLevel",
  "focusBalance", "focusRunway", "starved", "damagePerFocus", "focusPerCast" }
M.KPI_SHEET_COLS, M.KPI_SHEET_ROWS = 8, 4
local kpiIndex = {}
for i, n in ipairs(M.KPI_SHEET) do kpiIndex[n] = i end
local kpiTexture = nil
function M.KpiIcon(name)
  if kpiTexture == nil then
    local ok, tex = pcall(ShroudLoadTexture, M.KPI_SHEET_FILE)
    kpiTexture = (ok and type(tex) == "number") and tex or -1
  end
  local i = kpiIndex[name]
  if kpiTexture < 0 or not i then return nil end
  local col, row = (i - 1) % M.KPI_SHEET_COLS, math.floor((i - 1) / M.KPI_SHEET_COLS)
  return { tex = kpiTexture, uv = { col / M.KPI_SHEET_COLS, row / M.KPI_SHEET_ROWS, 1 / M.KPI_SHEET_COLS, 1 / M.KPI_SHEET_ROWS },
    key = "k:" .. name }
end

-- An icon: { tex, uv = { x, y, w, h }, key }, or nil when the sheet is missing.
function M.MetricIcon(name)
  local tex = M.Sheet()
  local i = sheetIndex[name]
  if not tex or not i then return nil end
  local w = 1 / #M.SHEET
  return { tex = tex, uv = { (i - 1) * w, 0, w, 1 }, key = "m:" .. name }
end

-- A skill's own game icon (ShroudGetSkills().icon, else ShroudGetSkillIcon by
-- rune name, e.g. combos); a pet attack shows the paw, an unknown rune the rune.
local skillTextures = nil
function M.ResetSkillIcons() skillTextures = nil end
function M.SkillIcon(k)
  if not M.Sheet() then return nil end
  if k.owner == "Pet" then return M.MetricIcon("pet") end
  if not skillTextures then
    skillTextures = {}
    for _, s in ipairs(ShroudGetSkills() or {}) do
      if type(s.id) == "number" and type(s.icon) == "number" and s.icon >= 0 then skillTextures[s.id] = s.icon end
    end
  end
  local tex = k.skillId and skillTextures[k.skillId] or nil
  if not tex and type(k.name) == "string" then
    local cached = skillTextures["n:" .. k.name]
    if cached == nil then
      local ok, t = pcall(ShroudGetSkillIcon, k.name)
      cached = (ok and type(t) == "number" and t >= 0) and t or false
      skillTextures["n:" .. k.name] = cached
    end
    tex = cached or nil
  end
  if tex then return { tex = tex, uv = { 0, 0, 1, 1 }, key = "t:" .. tostring(tex) } end
  return M.MetricIcon("rune")
end

function M.Say(text) ShroudConsoleLog("[TotA Meter] " .. tostring(text)) end

-- The engine clock (seconds), the same clock as combat lines' `time`.
function M.Now() return ShroudTime or 0 end

-- 12345.6 -> "12,346"
function M.Num(n)
  if type(n) ~= "number" or n ~= n then return "0" end
  local s = string.format("%d", math.floor(n + 0.5))
  local neg = ""
  if string.sub(s, 1, 1) == "-" then neg = "-"; s = string.sub(s, 2) end
  local out = s
  while true do
    local k = 0
    out, k = string.gsub(out, "^(%d+)(%d%d%d)", "%1,%2")
    if k == 0 then break end
  end
  return neg .. out
end

-- 0.183 -> "18%" (nil when there is nothing to divide)
function M.Pct(part, whole)
  if type(whole) ~= "number" or whole <= 0 then return "-" end
  return string.format("%d%%", math.floor(100 * part / whole + 0.5))
end

-- 75 -> "1:15"
function M.Clock(secs)
  secs = math.max(0, math.floor((secs or 0) + 0.5))
  return string.format("%d:%02d", math.floor(secs / 60), secs % 60)
end

-- One decimal (two below 1), without trailing zeros ("2.5", "3", "0.16").
function M.Dec(n)
  if type(n) ~= "number" then return "-" end
  local s = string.format(math.abs(n) < 1 and "%.2f" or "%.1f", n)
  s = string.gsub(s, "(%.%d-)0+$", "%1")
  return (string.gsub(s, "%.$", ""))
end

-- The first line of a name: a pet's `source` reads "Phoenix\n<Owner>".
function M.FirstLine(s)
  if type(s) ~= "string" then return "" end
  return string.match(s, "^([^\n]*)") or s
end

-- ---------------------------------------------------------------------------
-- Settings (character saved variables)
-- ---------------------------------------------------------------------------

-- What the HUD shows (owner, 2026-10-28): each line can be switched on or off.
M.HUD_ITEMS = {
  { key = "dps", label = "DPS" },
  { key = "peak", label = "Peak DPS (best 5 s)" },
  { key = "total", label = "Total damage" },
  { key = "crit", label = "Critical rate" },
  { key = "share", label = "Skill damage share" },
  { key = "max", label = "Skill max hit" },
  { key = "perMinute", label = "Skill uses per minute" },
  { key = "loot", label = "Last artifact / crown / blueprint" },
}
M.HUD_DEFAULT = { dps = true, peak = true, total = true, crit = true, share = true, max = false, perMinute = false, loot = true }
M.HUD_SKILL_CHOICES = { "3", "5", "8" }

M.settings = { hud = true, hudShow = {}, hudSkills = 5, combatDeck = nil, altDeck = nil, includeSkills = true }
for k, v in pairs(M.HUD_DEFAULT) do M.settings.hudShow[k] = v end
M.HISTORY = 10   -- finished Build Tester runs kept

function M.LoadSettings()
  local saved = ShroudGetSavedVar("settings", "character")
  if type(saved) == "table" then
    if saved.hud == false then M.settings.hud = false end
    if type(saved.combatDeck) == "string" then M.settings.combatDeck = saved.combatDeck end
    if type(saved.altDeck) == "string" then M.settings.altDeck = saved.altDeck end
    if saved.includeSkills == false then M.settings.includeSkills = false end
    if saved.hudSkills == 3 or saved.hudSkills == 5 or saved.hudSkills == 8 then M.settings.hudSkills = saved.hudSkills end
    if type(saved.hudShow) == "table" then
      for _, item in ipairs(M.HUD_ITEMS) do
        if type(saved.hudShow[item.key]) == "boolean" then M.settings.hudShow[item.key] = saved.hudShow[item.key] end
      end
    end
  end
  local h = ShroudGetSavedVar("tests", "character")
  M.tests = type(h) == "table" and h or {}
  M.LoadLoot()
end

function M.SaveSettings()
  ShroudSetSavedVar("settings", M.settings, "character")
end

-- A finished Build Tester run, newest first, at most M.HISTORY.
function M.RememberTest(summary)
  table.insert(M.tests, 1, summary)
  for i = #M.tests, M.HISTORY + 1, -1 do M.tests[i] = nil end
  ShroudSetSavedVar("tests", M.tests, "character")
  ShroudFlushSavedVars()
end

-- ---------------------------------------------------------------------------
-- Loot of note (owner, 2026-10-28): artifacts, Crowns of the Obsidians and
-- blueprints, from ShroudOnItemsGained (name, quantity, icon only: the API has
-- no rarity, so the name decides). Cleared with the meter.
-- ---------------------------------------------------------------------------

M.LOOT_KEEP = 200          -- items remembered
M.LOOT_TOOLTIP = 20        -- items listed when hovering the HUD's loot line
M.ARTIFACT_WORDS = { common = true, uncommon = true, rare = true, legendary = true, epic = true }
M.LOOT_LABEL = { artifact = "Artifact", crown = "Crown", blueprint = "Blueprint" }
-- Also artifacts: any name containing one of these (owner, 2026-10-28; any case).
M.ARTIFACT_PHRASES = {
  "Short Glowing Blue Cylinder", "Supply Bundle", "Book of Learning", "Ring of Luck", "Cowbell of Reaping",
  "Embry's Harp", "Fleet Flute", "Flute of Defiance", "Glowing Belt Buckle", "Harp of Invigoration",
  "Lute of Discordant Notes", "Strip of Thick Troll Skin", "Short Glowing Cylinder", "Lute of Inspiration",
  "Mossy Green Handle", "Savage Handle", "Torc'Dawl's", "Lich Skull", "Troll Rib Cage", "Troll Pelvic Bones",
  "Unicorn Blood", "Unicorn Hair", "Shadow Essence",
}
local artifactPhrases = {}
for i, p in ipairs(M.ARTIFACT_PHRASES) do artifactPhrases[i] = string.lower(p) end

-- "artifact", "crown", "blueprint" or nil.
function M.LootKind(name)
  if type(name) ~= "string" or name == "" then return nil end
  -- typographic apostrophes (U+2019) count as plain ones
  local lower = string.lower((string.gsub(name, "\226\128\153", "'")))
  if string.find(lower, "^%s*blueprint") then return "blueprint" end
  if string.find(lower, "crowns? of the obsidians?") then return "crown" end
  for word in string.gmatch(lower, "%a+") do
    if M.ARTIFACT_WORDS[word] then return "artifact" end
  end
  for _, p in ipairs(artifactPhrases) do
    if string.find(lower, p, 1, true) then return "artifact" end
  end
  return nil
end

local function emptyLoot() return { items = {}, counts = { artifact = 0, crown = 0, blueprint = 0 } } end
M.loot = emptyLoot()

-- The loot list is a character saved variable, so /lua reload and relogs keep
-- it until the meter is reset (it used to live in memory only).
-- Item icons are texture ids the game registers for the current session only
-- (0.6.2: a saved id shown after a reload or relog raised "no texture with id"
-- on every HUD refresh until the game turned the add-on off). So icons are
-- kept in memory and never saved.
function M.SaveLoot()
  local items = {}
  for i, it in ipairs(M.loot.items) do items[i] = { name = it.name, quantity = it.quantity, kind = it.kind } end
  ShroudSetSavedVar("loot", { items = items, counts = M.loot.counts }, "character")
  ShroudFlushSavedVars()
end

function M.LoadLoot()
  local saved = ShroudGetSavedVar("loot", "character")
  M.loot = emptyLoot()
  if type(saved) ~= "table" or type(saved.items) ~= "table" then return end
  for _, it in ipairs(saved.items) do
    if type(it) == "table" and type(it.name) == "string" and M.LOOT_LABEL[it.kind] and #M.loot.items < M.LOOT_KEEP then
      local qty = (type(it.quantity) == "number" and it.quantity > 0) and it.quantity or 1
      M.loot.items[#M.loot.items + 1] = { name = it.name, quantity = qty, kind = it.kind }   -- no icon: see SaveLoot
    end
  end
  if type(saved.counts) == "table" then
    for k in pairs(M.loot.counts) do
      if type(saved.counts[k]) == "number" and saved.counts[k] >= 0 then M.loot.counts[k] = saved.counts[k] end
    end
  end
end

function M.ResetLoot()
  M.loot = emptyLoot()
  M.SaveLoot()
end

-- Items gained ({ name, quantity, icon }); returns how many were of note.
function M.AddLoot(items)
  local n = 0
  for _, it in ipairs(items or {}) do
    local kind = type(it) == "table" and M.LootKind(it.name) or nil
    if kind then
      local qty = (type(it.quantity) == "number" and it.quantity > 0) and it.quantity or 1
      table.insert(M.loot.items, 1, { name = it.name, quantity = qty, kind = kind,
        icon = (type(it.icon) == "number" and it.icon >= 0) and it.icon or nil })
      M.loot.counts[kind] = M.loot.counts[kind] + qty
      n = n + 1
    end
  end
  for i = #M.loot.items, M.LOOT_KEEP + 1, -1 do M.loot.items[i] = nil end
  if n > 0 then M.SaveLoot() end
  return n
end

-- The game's tooltip text: the last LOOT_TOOLTIP items, newest first (tooltips stop at 512 characters).
function M.LootTooltip()
  local items = M.loot.items
  if #items == 0 then return "Artifacts, Crowns of the Obsidians and blueprints you loot show here." end
  local lines = { "Last " .. math.min(#items, M.LOOT_TOOLTIP) .. " looted (newest first):" }
  local size = #lines[1]
  for i = 1, math.min(#items, M.LOOT_TOOLTIP) do
    local it = items[i]
    local line = it.name .. (it.quantity > 1 and (" x" .. it.quantity) or "")
    if size + #line + 1 > 500 then lines[#lines + 1] = "..." break end
    lines[#lines + 1] = line
    size = size + #line + 1
  end
  return table.concat(lines, "\n")
end

-- Reads a stat by name; nil when unknown, hidden or unreadable.
function M.Stat(name)
  local ok, v = pcall(ShroudGetStatValueByName, name)
  if not ok or type(v) ~= "number" or v == InvalidStatResult then return nil end
  if v == 0 and not ShroudIsStatVisible(name) then return nil end
  return v
end

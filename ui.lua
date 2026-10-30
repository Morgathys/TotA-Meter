-- TotA Meter: the HUD and the main window (tabs: Meter, Build Tester, Export, HUD).
-- Pages are built the first time they are opened (the game limits how many
-- elements can be created at once); refreshes only change texts.

local M = TotaMeter
local UI = Shroud.UI
local Model = M.Model
local View = {}
M.View = View

-- ---------------------------------------------------------------------------
-- Small building blocks
-- ---------------------------------------------------------------------------

local GOLD = "@gold"
local CLEAR = "#00000000"
local STRIPE = "#ffffff08"

local function label(text, cls, style) return UI.Label{ text = text or "", class = cls or "text", style = style } end

-- An icon picture (see M.MetricIcon / M.SkillIcon); nil when there is no icon.
local function iconImage(spec, size, style)
  if not spec then return nil end
  local st = style or { marginRight = 6 }
  return UI.Image{ texture = spec.tex, uv = spec.uv, width = size, height = size, style = st }
end

-- Shows `spec` in `img`; `holder` remembers what it shows so nothing changes
-- needlessly. A texture the game no longer knows (an id from another session)
-- is refused once, then the metric icon `fallback` is shown instead and that
-- id is not tried again. Returns false when `spec` was refused.
local badTextures = {}
local function setIcon(holder, img, spec, fallback)
  if not img or not spec then return true end
  if badTextures[spec.tex] and fallback then spec = fallback end
  if holder.iconKey == spec.key then return true end
  local ok = pcall(img.SetTexture, img, spec.tex)
  if not ok then
    badTextures[spec.tex] = true
    if fallback and fallback ~= spec then return setIcon(holder, img, fallback) and false end
    return false
  end
  img:SetUV(spec.uv[1], spec.uv[2], spec.uv[3], spec.uv[4])
  holder.iconKey = spec.key
  return true
end

local function heading(text)
  return UI.Label{ text = text, class = "heading", style = { marginTop = 14, marginBottom = 4 } }
end

-- A stat card: caption, big value, small note.
local CARD_GAP = 8
local function card(iconName, last)
  local caption = label("", "dim", { fontSize = 11, whiteSpace = "nowrap" })
  local img = iconImage(M.MetricIcon(iconName), 16, { marginRight = 6 })
  local value = label("-", "bright", { fontSize = 22, whiteSpace = "nowrap", marginTop = 4 })
  local note = label(" ", "dim", { fontSize = 11, whiteSpace = "nowrap" })
  local head = img and UI.Row{ style = { alignItems = "center" }, children = { img, caption } } or caption
  -- 4 cards share a row: the same base width, the rest of the row split evenly
  local box = UI.Column{ class = "inset", style = { width = "23%", flexGrow = 1, flexShrink = 1, minHeight = 82,
    paddingLeft = 12, paddingRight = 12, paddingTop = 10, paddingBottom = 10, marginRight = last and 0 or CARD_GAP },
    children = { head, value, note } }
  return box, { caption = caption, value = value, note = note }
end

-- One row of equal cards (Grid's equal shares don't leave room for gaps).
local function cardRow(icons)
  local boxes, cards = {}, {}
  for i, name in ipairs(icons) do boxes[i], cards[i] = card(name, i == #icons) end
  return UI.Row{ style = { alignItems = "stretch", marginBottom = CARD_GAP }, children = boxes }, cards
end

-- A table: cols = { { title, width, align } }, n rows. Returns container, rows.
local ICON_SIZE = 18
local function grid(cols, n, withIcons)
  local icons = withIcons and M.Sheet() ~= nil
  local function row(cls, stripe, header)
    local cells = {}
    local lead = nil
    if icons then
      lead = header and label("", "dim", { width = ICON_SIZE, marginRight = 6 }) or iconImage(M.MetricIcon("rune"), ICON_SIZE)
    end
    for i, c in ipairs(cols) do
      cells[i] = UI.Label{ text = "", class = cls, style = { width = c[2], textAlign = c[3] or "right", whiteSpace = "nowrap",
        marginLeft = 0, marginRight = 6, fontSize = 13 } }
    end
    local kids = cells
    if lead then
      kids = { lead }
      for _, c in ipairs(cells) do kids[#kids + 1] = c end
    end
    local r = UI.Row{ style = { paddingTop = 3, paddingBottom = 3, paddingLeft = 6, alignItems = "center",
      backgroundColor = stripe and STRIPE or CLEAR }, children = kids }
    return r, cells, (not header) and lead or nil
  end
  local head, headCells = row("dim", false, true)
  for i, c in ipairs(cols) do headCells[i]:SetText(c[1]) end
  local children, rows = { head }, {}
  for i = 1, n do
    local r, cells, img = row("text", i % 2 == 0, false)
    r:SetVisible(false)
    rows[i] = { row = r, cells = cells, icon = img }
    children[#children + 1] = r
  end
  return UI.Column{ class = "inset", style = { paddingTop = 4, paddingBottom = 4 }, children = children }, rows
end

local function fillGrid(rows, data, cellsOf, iconOf)
  for i, r in ipairs(rows) do
    local item = data[i]
    if item then
      local cells = cellsOf(item, i)
      for j, c in ipairs(r.cells) do c:SetText(cells[j] or "") end
      if r.icon and iconOf then setIcon(r, r.icon, iconOf(item), M.MetricIcon("rune")) end
    end
    r.row:SetVisible(item ~= nil)
  end
end

-- Key / value lines (Details).
local function kvBlock(keys)
  local children, values = {}, {}
  for i, k in ipairs(keys) do
    values[i] = label("", "text", { whiteSpace = "wrap", flexGrow = 1, flexShrink = 1 })
    children[i] = UI.Row{ style = { marginTop = 3 }, children = { label(k, "dim", { width = 140, whiteSpace = "nowrap" }), values[i] } }
  end
  return UI.Column{ children = children }, values, children
end

local function button(text, fn, style) return UI.Button{ text = text, onClick = fn, style = style } end

-- ---------------------------------------------------------------------------
-- Shared texts
-- ---------------------------------------------------------------------------

local SKILL_COLS = { { "Skill / attack", 150, "left" }, { "Damage", 78 }, { "Share", 50 }, { "Max hit", 62 }, { "Uses", 44 },
  { "Uses/min", 62 }, { "Crit", 46 }, { "Glancing", 60 }, { "Ultraslay", 62 }, { "Focus/cast", 70 } }

local function skillCells(k)
  return { (k.owner == "Pet" and "Pet: " or "") .. k.name, M.Num(k.damage), M.Pct(k.share, 1), M.Num(k.max), M.Num(k.uses),
    (k.uses > 0) and M.Dec(k.perMinute) or "-", M.Pct(k.critRate, 1), M.Pct(k.glancingRate, 1), M.Pct(k.ultraslayRate, 1),
    (k.owner == "You" and k.focus) and M.Num(k.focus) or "-" }
end

local function joinList(list, sep) return #list > 0 and table.concat(list, sep or ", ") or "-" end

-- Details of a summary (+ the session for the start snapshot and notes).
local DETAIL_KEYS = { "Damage by type", "Combos", "Other effects", "Decks", "At the start", "Notes" }
local function detailTexts(sum, s)
  local types, combos, others, decks = {}, {}, {}, {}
  for _, t in ipairs(sum.types) do types[#types + 1] = t.type .. " " .. M.Pct(t.share, 1) end
  for _, c in ipairs(sum.combos) do
    local text = c.name .. " x" .. c.uses .. " (" .. M.Num(c.damage) .. ")"
    if c.other then others[#others + 1] = text else combos[#combos + 1] = text end
  end
  local secs = 0
  for _, d in ipairs(sum.decks) do secs = secs + d.seconds end
  for _, d in ipairs(sum.decks) do
    decks[#decks + 1] = d.name .. ": " .. M.Num(d.damage) .. " (" .. M.Pct(d.damage, sum.damage) .. ")" ..
      (secs > 0 and (", " .. M.Pct(d.seconds, secs) .. " of the time") or "")
  end
  local snap = s and s.snap or {}
  local st = {}
  local function stat(name, v, pct) if type(v) == "number" then st[#st + 1] = name .. " " .. (pct and (M.Dec(v * 100) .. "%") or M.Dec(v)) end end
  stat("Attack speed", snap.AttackSpeed)
  stat("Melee/ranged crit", snap.WeaponCritBonus, true)
  stat("Spell crit", snap.SpellCriticalChanceBonus, true)
  stat("Rune focus cost", snap.GlyphFocusCost, true)
  if snap.pet then
    stat("Pet crit", snap.pet.CriticalHit and snap.pet.CriticalHit / 100, true)
    stat("Pet attack speed", snap.pet.AttackSpeed)
  end
  if sum.petAttackInterval then st[#st + 1] = "Pet attacks every " .. M.Dec(sum.petAttackInterval) .. " s" end
  local notes = {}
  if snap.consumables and #snap.consumables > 0 then notes[#notes + 1] = "Potions/food active: " .. table.concat(snap.consumables, ", ") end
  if s and s.ignored > 0 then notes[#notes + 1] = M.Num(s.ignored) .. " lines from others ignored" end
  if s and s.dropped > 0 then notes[#notes + 1] = "the game dropped some combat lines (over 50 at once): totals may be low" end
  if s and s.nameMismatch > 0 then notes[#notes + 1] = s.nameMismatch .. " of your lines named someone else" end
  return { joinList(types), joinList(combos), joinList(others), joinList(decks, "; "), joinList(st), joinList(notes, "; ") }
end

-- ---------------------------------------------------------------------------
-- HUD
-- ---------------------------------------------------------------------------

local hud = nil
local H = {}               -- HUD elements
local hudLayoutKey = nil
local HUD_X, HUD_Y = 40, 300
local HUD_SKILL_POOL = 8
local HUD_STATS = { { "dps", "DPS", "dps" }, { "peak", "Peak", "peak" }, { "total", "Total", "total" }, { "crit", "Critical", "crit" } }
local HUD_COLS = { { "share", "Share" }, { "max", "Max" }, { "perMinute", "/min" } }

-- The session the HUD shows: a Build Tester run in progress, else the fight.
local function hudSession()
  local t = M.tester
  if t and not t.ended then return t, "tester" end
  if M.fight and M.fight.start then return M.fight, "fight" end
  if t then return t, "tester" end
  return nil, "none"
end

local function testerStatus(t, now)
  if not t.start then return "waiting for your first hit" end
  local elapsed = Model.Duration(t, now)
  if t.ended then return (t.stopped and "stopped at " or "done, ") .. M.Clock(elapsed) end
  local nextAt = t.checkpoints[t.nextCheckpoint]
  return M.Clock(elapsed) .. (nextAt and (" (next snapshot " .. M.Clock(nextAt) .. ")") or "")
end

local function hudTitle(s, kind, now)
  if kind == "tester" then return "Build Tester " .. testerStatus(s, now) end
  if kind == "fight" then return (Model.InCombat(s) and "In combat " or "Meter ") .. M.Clock(Model.Duration(s, now)) end
  return "TotA Meter " .. M.VERSION
end

local function hudRow(key, iconName)
  local k = label(key, "dim", { fontSize = 12, width = 64, whiteSpace = "nowrap" })
  local v = label("", "bright", { fontSize = 12, flexGrow = 1, textAlign = "right", whiteSpace = "nowrap" })
  local img = iconImage(M.MetricIcon(iconName), 14, { marginRight = 6 })
  return UI.Row{ style = { marginTop = 1, alignItems = "center" }, children = img and { img, k, v } or { k, v } }, v
end

function View.BuildHud()
  H = { stats = {}, skills = {}, cols = {} }
  local title = label("TotA Meter " .. M.VERSION, "bright", { fontSize = 12, flexGrow = 1, whiteSpace = "nowrap" })
  local menu = button("Menu", function() View.Toggle() end,
    { fontSize = 11, paddingLeft = 8, paddingRight = 8, paddingTop = 1, paddingBottom = 1, marginLeft = 6 })
  H.title = title
  local headRow = { title, menu }
  local icon = M.Icon()
  if icon then
    table.insert(headRow, 1, UI.Image{ texture = icon, width = 20, height = 20, style = { marginRight = 6 } })
  end
  local children = { UI.Row{ style = { alignItems = "center", marginBottom = 4 }, children = headRow } }
  for i, st in ipairs(HUD_STATS) do
    local row, value = hudRow(st[2], st[3])
    H.stats[i] = { key = st[1], row = row, value = value }
    children[#children + 1] = row
  end
  -- skills: name + up to three columns
  local headCells = { label("Skill", "dim", { fontSize = 11, flexGrow = 1, whiteSpace = "nowrap" }) }
  for i, c in ipairs(HUD_COLS) do
    H.cols[i] = { key = c[1], head = label(c[2], "dim", { fontSize = 11, width = 50, textAlign = "right", whiteSpace = "nowrap" }) }
    headCells[#headCells + 1] = H.cols[i].head
  end
  H.skillHead = UI.Row{ style = { marginTop = 6 }, children = headCells }
  children[#children + 1] = H.skillHead
  for i = 1, HUD_SKILL_POOL do
    local name = label("", "text", { fontSize = 12, flexGrow = 1, flexShrink = 1, whiteSpace = "nowrap" })
    local img = iconImage(M.MetricIcon("rune"), 16, { marginRight = 6 })
    local cells = img and { img, name } or { name }
    local values = {}
    for j = 1, #HUD_COLS do
      values[j] = label("", "text", { fontSize = 12, width = 50, textAlign = "right", whiteSpace = "nowrap" })
      cells[#cells + 1] = values[j]
    end
    local row = UI.Row{ style = { alignItems = "center", marginTop = 1 }, children = cells }
    row:SetVisible(false)
    H.skills[i] = { row = row, name = name, values = values, icon = img }
    children[#children + 1] = row
  end
  -- Loot of note at the bottom: the last artifact / crown / blueprint; hovering
  -- it shows the game's tooltip with the last 20 (owner, 2026-10-28).
  -- One thin line, as tall as the item's icon (owner, 2026-10-28): no title,
  -- no counts. Always there (dim "No artifact yet" until something drops).
  local L = { tip = nil }
  L.img = iconImage(M.MetricIcon("total"), 20, { marginRight = 6 })
  L.name = label("", "bright", { fontSize = 12, whiteSpace = "nowrap", flexShrink = 1, flexGrow = 1 })
  L.row = UI.Row{ style = { alignItems = "center", marginTop = 6, height = 20 }, tooltip = M.LootTooltip(),
    children = L.img and { L.img, L.name } or { L.name } }
  L.section = L.row
  H.loot = L
  children[#children + 1] = L.section
  -- The panel keeps its natural height (no flexGrow), so GetSize() reports what
  -- its lines really need and the frame is fitted to it (see fitHud).
  H.panel = UI.Column{ style = { backgroundColor = "#0b0e0de6", borderColor = "#c7a66c55", borderWidth = 1, borderRadius = 4,
    paddingLeft = 10, paddingRight = 10, paddingTop = 6, paddingBottom = 8, alignSelf = "stretch" }, children = children }
  H.w, H.h = 260, 200
  hud = UI.HudFrame{ id = "tm_hud", x = HUD_X, y = HUD_Y, width = H.w, height = H.h, children = { H.panel } }
  hud:SetVisible(M.settings.hud)
  hudLayoutKey = nil
end

-- Shows the chosen lines and sizes the frame to them.
local function layoutHud(skillCount)
  local show = M.settings.hudShow
  local cols = 0
  for _, c in ipairs(H.cols) do
    c.head:SetVisible(show[c.key] == true)
    if show[c.key] then cols = cols + 1 end
  end
  local rows = 0
  for _, st in ipairs(H.stats) do
    st.row:SetVisible(show[st.key] == true)
    if show[st.key] then rows = rows + 1 end
  end
  local skills = cols > 0 and skillCount or 0
  H.skillHead:SetVisible(skills > 0)
  local loot = show.loot == true
  H.loot.section:SetVisible(loot)
  local key = rows .. ":" .. cols .. ":" .. skills .. ":" .. tostring(loot)
  if key ~= hudLayoutKey then
    hudLayoutKey = key
    -- A generous first guess (lines are about 28 px tall in game); fitHud then
    -- sets the height the game actually laid out.
    H.w = math.max(260, 190 + cols * 56)
    H.h = 60 + rows * 30 + (skills > 0 and (30 + skills * 30) or 0) + (loot and 30 or 0)
    hud:SetSize(H.w, H.h)
  end
  return cols
end

-- Fits the frame to the panel's laid-out height (GetSize is nil before the
-- first layout). The game clips whatever doesn't fit a HUD frame.
local function fitHud()
  if not H.panel then return end
  local ok, _, h = pcall(H.panel.GetSize, H.panel)
  if not ok or type(h) ~= "number" or h <= 0 then return end
  local want = math.ceil(h) + 2
  if math.abs(want - H.h) > 1 then
    H.h = want
    hud:SetSize(H.w, H.h)
  end
end

local function refreshHud(now)
  if not hud or not M.settings.hud then return end
  fitHud()   -- the layout of the previous refresh is known by now
  local s, kind = hudSession()
  H.title:SetText(hudTitle(s, kind, now) .. ((M.errorCount or 0) > 0 and "  (!) /tota errors" or ""))
  local started = s and s.start
  for _, st in ipairs(H.stats) do
    local v = "-"
    if started then
      if st.key == "dps" then
        local live = (kind == "tester" and not s.ended) or (kind == "fight" and Model.InCombat(s))
        local recent = live and Model.Recent(s, now) or nil
        v = M.Num(Model.Dps(s, now)) .. (recent and ("  (now " .. M.Num(recent) .. ")") or "")
      elseif st.key == "peak" then v = M.Num(Model.Peak(s, now))
      elseif st.key == "total" then v = M.Num(s.total)
      elseif st.key == "crit" then v = M.Pct(s.crits, s.damageLines) end
    end
    st.value:SetText(v)
  end
  local list = started and Model.Skills(s, now) or {}
  local count = math.min(#list, M.settings.hudSkills, HUD_SKILL_POOL)
  local cols = layoutHud(count)
  for i, r in ipairs(H.skills) do
    local k = list[i]
    local on = cols > 0 and k ~= nil and i <= count
    if on then
      r.name:SetText((k.owner == "Pet" and "Pet: " or "") .. k.name)
      setIcon(r, r.icon, M.SkillIcon(k), M.MetricIcon("rune"))
      for j, c in ipairs(H.cols) do
        local text = ""
        if c.key == "share" then text = M.Pct(k.share, 1)
        elseif c.key == "max" then text = M.Num(k.max)
        elseif c.key == "perMinute" then text = (k.uses > 0) and M.Dec(k.perMinute) or "-" end
        r.values[j]:SetText(text)
        r.values[j]:SetVisible(M.settings.hudShow[c.key] == true)
      end
    end
    r.row:SetVisible(on)
  end
  if M.settings.hudShow.loot then
    local L = H.loot
    local last = M.loot.items[1]
    if last then
      L.name:SetText(last.name .. (last.quantity > 1 and ("  x" .. last.quantity) or ""))
      local spec = last.icon and { tex = last.icon, uv = { 0, 0, 1, 1 }, key = "i:" .. last.icon } or M.MetricIcon("total")
      if not setIcon(L, L.img, spec, M.MetricIcon("total")) then last.icon = nil end
    else
      L.name:SetText("No artifact yet")
      setIcon(L, L.img, M.MetricIcon("total"))
    end
    if (last ~= nil) ~= L.lit then
      L.lit = last ~= nil
      if L.lit then L.name:RemoveClass("dim"); L.name:AddClass("bright") else L.name:RemoveClass("bright"); L.name:AddClass("dim") end
    end
    local tip = M.LootTooltip()
    if tip ~= L.tip then L.row:SetTooltip(tip); L.tip = tip end
  end
end

function View.SetHudShown(on)
  M.settings.hud = on == true
  M.SaveSettings()
  if hud then hud:SetVisible(M.settings.hud) end
  hudLayoutKey = nil
end

function View.MoveHud(dx, dy)
  if not hud then return end
  if dx == nil then hud:SetPosition(HUD_X, HUD_Y) return end
  local x, y = hud:GetPosition()
  hud:SetPosition((x or HUD_X) + dx, (y or HUD_Y) + dy)
end

-- ---------------------------------------------------------------------------
-- Main window and tabs
-- ---------------------------------------------------------------------------

local win = nil
local host = nil
local tabs = {}
local pages = {}
local current = nil
local P = { meter = {}, tester = {}, export = {}, hud = {} }   -- page elements

local TABS = { { "meter", "Meter" }, { "tester", "Build Tester" }, { "export", "Export" }, { "hud", "Setup" } }

-- Meter --------------------------------------------------------------------

local METER_CARDS = { "DPS", "Peak DPS (5 s)", "Total damage", "Combat time", "Critical", "Casts / min", "Pet share", "Missed" }

local function buildMeter()
  local e = P.meter
  e.title = label("Meter", "title", { fontSize = 16 })
  e.state = label("", "dim", { fontSize = 12, marginLeft = 10 })
  e.since = label("Cumulative until you reset it", "dim", { fontSize = 12, flexGrow = 1, marginLeft = 10 })
  local top = UI.Row{ style = { alignItems = "center", marginBottom = 10 }, children = { e.title, e.state, e.since,
    button("Reset meter", function() M.ResetFight() end) } }
  local g1, c1 = cardRow({ "dps", "peak", "total", "duration" })
  local g2, c2 = cardRow({ "crit", "casts", "pet", "missed" })
  e.cards = {}
  for i, c in ipairs(c1) do e.cards[i] = c end
  for i, c in ipairs(c2) do e.cards[4 + i] = c end
  for i, c in ipairs(e.cards) do c.caption:SetText(METER_CARDS[i]) end
  local tbl, rows = grid(SKILL_COLS, 12, true)
  e.rows = rows
  e.more = label("", "dim", { marginTop = 4 })
  local det, values = kvBlock(DETAIL_KEYS)
  e.details = values
  e.empty = label("Nothing recorded yet: hit something and the meter starts on its own. It keeps adding every fight until you reset it.", "dim", { whiteSpace = "wrap", marginTop = 6 })
  e.body = UI.Column{ children = { g1, g2, heading("Skills and attacks"), tbl, e.more, heading("Details"), det } }
  return UI.Column{ children = { top, e.empty, e.body,
    label("Counts only you and your pet. Focus per cast is estimated from the focus you lose just before each hit.",
      "dim", { whiteSpace = "wrap", marginTop = 12, fontSize = 12 }) } }
end

local function fillCards(cards, sum, live)
  local v = {
    M.Num(sum.dps), M.Num(sum.peakDps), M.Num(sum.damage), M.Clock(sum.seconds),
    M.Pct(sum.critRate, 1), M.Dec(sum.castsPerMinute), M.Pct(sum.pet, sum.damage), M.Pct(sum.missRate, 1),
  }
  local fights = sum.fights and (sum.fights .. (sum.fights == 1 and " fight" or " fights")) or " "
  local notes = { live and ("now " .. M.Num(live)) or " ", "best 5 seconds", "you " .. M.Num(sum.you) .. (sum.pet > 0 and ("  ·  pet " .. M.Num(sum.pet)) or ""),
    fights, " ", " ", sum.pet > 0 and ("pet " .. M.Num(sum.pet)) or " ", " " }
  for i, c in ipairs(cards) do c.value:SetText(v[i]); c.note:SetText(notes[i]) end
end

local function refreshMeter(now)
  local e = P.meter
  local s = M.fight
  local started = s ~= nil and s.start ~= nil
  e.empty:SetVisible(not started)
  e.body:SetVisible(started)
  e.state:SetVisible(started)
  if not started then return end
  local live = Model.InCombat(s)
  e.state:SetText(live and "In combat" or "Out of combat")
  e.state:RemoveClass(live and "dim" or "good")
  e.state:AddClass(live and "good" or "dim")
  local sum = Model.Summary(s, now)
  sum.fights = s.segments
  fillCards(e.cards, sum, live and Model.Recent(s, now) or nil)
  fillGrid(e.rows, sum.skills, skillCells, M.SkillIcon)
  e.more:SetText(#sum.skills > #e.rows and ("... and " .. (#sum.skills - #e.rows) .. " more") or "")
  e.more:SetVisible(#sum.skills > #e.rows)
  local d = detailTexts(sum, s)
  for i, l in ipairs(e.details) do l:SetText(d[i]) end
end

-- Build Tester -----------------------------------------------------------------

local CHECK_LABELS = { "1 min", "3 min", "5 min" }

-- KPI table (0.7.0): one row per KPI of kpi.lua, one column per span. The
-- ~300 elements are created a few rows per refresh, since the game refuses
-- elements created faster than ~200 a second.
local KPI_COLS = { { "0-1", "w1" }, { "1-3", "w2" }, { "3-5", "w3" }, { "@1", "c1" }, { "@3", "c3" }, { "@5", "c5" } }
local KPI_NAME_W, KPI_CELL_W = 170, 92
local SKILL_SPAN_COLS = { { "Skill / attack", 150, "left" }, { "Damage", 74 }, { "Share", 48 }, { "Avg hit", 60 }, { "Avg crit", 62 },
  { "Crit power", 70 }, { "Crit rate", 60 }, { "Uses", 42 }, { "Focus/cast", 70 }, { "Dmg/focus", 70 } }
local KPI_ROWS_PER_REFRESH = 7
local spanPick = nil   -- the span shown in the skills table (nil = the latest)

function View.SelectSnapshot(i) spanPick = nil end

local function kpiRowsList()
  local list = {}
  for _, g in ipairs(M.Kpi.GROUPS) do
    list[#list + 1] = { heading = g[1] }
    for _, k in ipairs(g[2]) do list[#list + 1] = { id = k[1], name = k[2], tip = k[3], cell = k[4] } end
  end
  return list
end

local function kpiHeader(e)
  local cells = { label("", "dim", { width = ICON_SIZE, marginRight = 6 }), label("KPI", "dim", { width = KPI_NAME_W, fontSize = 12 }) }
  e.kpiHead = {}
  for i, c in ipairs(KPI_COLS) do
    e.kpiHead[i] = label(c[1], "dim", { width = KPI_CELL_W, textAlign = "right", fontSize = 12, whiteSpace = "nowrap", marginRight = 4 })
    cells[#cells + 1] = e.kpiHead[i]
  end
  return UI.Row{ style = { paddingTop = 3, paddingBottom = 3, paddingLeft = 6, alignItems = "center" }, children = cells }
end

-- Adds the next KPI rows (up to KPI_ROWS_PER_REFRESH) to the table.
local function growKpiRows(e)
  local made = 0
  while e.kpiNext <= #e.kpiList and made < KPI_ROWS_PER_REFRESH do
    local item = e.kpiList[e.kpiNext]
    if item.heading then
      e.kpiBox:Add(label(item.heading, "title", { fontSize = 13, marginTop = 8, marginBottom = 2, paddingLeft = 6 }))
    else
      local cells = {}
      local icon = M.KpiIcon(item.id)
      cells[#cells + 1] = icon and iconImage(icon, ICON_SIZE) or label("", "dim", { width = ICON_SIZE, marginRight = 6 })
      cells[#cells + 1] = label(item.name, "text", { width = KPI_NAME_W, fontSize = 13, whiteSpace = "nowrap" })
      item.values = {}
      for i = 1, #KPI_COLS do
        item.values[i] = label("", "bright", { width = KPI_CELL_W, textAlign = "right", fontSize = 13, whiteSpace = "nowrap", marginRight = 4 })
        cells[#cells + 1] = item.values[i]
      end
      e.kpiStripe = not e.kpiStripe
      e.kpiBox:Add(UI.Row{ tooltip = item.name .. ": " .. item.tip, style = { paddingTop = 2, paddingBottom = 2, paddingLeft = 6,
        alignItems = "center", backgroundColor = e.kpiStripe and STRIPE or CLEAR }, children = cells })
    end
    e.kpiNext = e.kpiNext + 1
    made = made + 1
  end
end

local function buildTester()
  local e = P.tester
  e.status = label("", "title", { fontSize = 16, flexGrow = 1 })
  e.start = button("Start", function() M.TesterStart() end)
  e.reset = button("Reset", function() M.TesterReset() end, { marginLeft = 6 })
  local top = UI.Row{ style = { alignItems = "center" }, children = { e.status, e.start, e.reset } }
  e.bar = UI.Bar{ value = 0, color = GOLD, style = { height = 6, marginTop = 8 } }
  local marks = UI.Row{ style = { justifyContent = "space-between", marginTop = 2 }, children = {
    label("0:00", "dim", { fontSize = 11 }), label("1:00", "dim", { fontSize = 11 }), label("3:00", "dim", { fontSize = 11 }),
    label("5:00", "dim", { fontSize = 11 }) } }
  e.kpiList = kpiRowsList()
  e.kpiNext = 1
  e.kpiBox = UI.Column{ class = "inset", style = { paddingTop = 4, paddingBottom = 6 }, children = { kpiHeader(e) } }
  e.pick = {}
  local pickRow = { label("Skills for", "dim", { marginRight = 8 }) }
  for i, c in ipairs(KPI_COLS) do
    e.pick[i] = button(c[1], function() spanPick = c[2]; View.Refresh(M.Now()) end,
      { borderWidth = 1, borderColor = CLEAR, marginRight = 4, paddingLeft = 8, paddingRight = 8 })
    pickRow[#pickRow + 1] = e.pick[i]
  end
  local tbl, rows = grid(SKILL_SPAN_COLS, 12, true)
  e.rows = rows
  e.unused = label("", "dim", { whiteSpace = "wrap", marginTop = 4, fontSize = 12 })
  local det, values = kvBlock(DETAIL_KEYS)
  e.details = values
  e.history = {}
  local hist = {}
  for i = 1, 5 do e.history[i] = label("", "text", { whiteSpace = "nowrap", marginTop = 2 }); hist[i] = e.history[i] end
  e.noHistory = label("No finished run yet.", "dim")
  e.body = UI.Column{ children = {
    heading("Performance"),
    label("0-1, 1-3, 3-5: each window on its own.  @1, @3, @5: from your first hit to that minute.  Hover a KPI for what it means.",
      "dim", { whiteSpace = "wrap", fontSize = 12, marginBottom = 4 }),
    e.kpiBox,
    UI.Row{ style = { alignItems = "center", marginTop = 14, flexWrap = "wrap" }, children = pickRow }, tbl, e.unused,
    heading("Details"), det } }
  return UI.Column{ children = { top,
    label("Press Start, then hit the Training Dummy. The run starts with your first hit and lasts 5:00: the clock never pauses. Reset cancels a run.",
      "dim", { whiteSpace = "wrap", marginTop = 4, fontSize = 12 }),
    e.bar, marks, e.body, heading("Previous runs"), e.noHistory, UI.Column{ children = hist } } }
end

local function skillSpanCells(k, total)
  local function n(v) return v and M.Num(v) or "-" end
  return { (k.owner == "Pet" and "Pet: " or "") .. k.name, M.Num(k.damage), M.Pct(k.damage, total), n(k.avgHit), n(k.avgCrit),
    k.critPower and ("x" .. M.Dec(k.critPower)) or "-", k.critRate and (M.Num(k.critRate * 100) .. "%") or "-", M.Num(k.uses),
    k.focusPerCast and M.Dec(k.focusPerCast) or "-", k.damagePerFocus and M.Dec(k.damagePerFocus) or "-" }
end

local function refreshTester(now)
  local e = P.tester
  local t = M.tester
  local running = t ~= nil and not t.ended
  e.status:SetText(t and ("Build Tester: " .. testerStatus(t, now)) or "Build Tester")
  e.start:SetEnabled(not running)
  e.reset:SetEnabled(t ~= nil)
  e.bar:SetValue((t and t.start) and math.min(1, Model.Duration(t, now) / t.testLength) or 0)
  local started = t ~= nil and t.start ~= nil
  e.body:SetVisible(started)
  if not started then return end
  growKpiRows(e)
  local elapsed = t.ended and t.testLength or Model.Duration(t, now)
  -- while running, the KPIs are recomputed once a second (not every refresh)
  local out = t.kpis
  if not out or running then
    if e.kpiCache and e.kpiCache.run == t and (running and now - e.kpiCache.at < 1) then out = e.kpiCache.out
    else
      out = M.Kpi.Compute(t.rec, elapsed, t.layouts, t.altDeck)
      e.kpiCache = { run = t, at = now, out = out }
    end
  end
  -- KPI cells; a span still running shows its value so far with "..."
  for i, c in ipairs(KPI_COLS) do
    local r = out[c[2]]
    e.kpiHead[i]:SetText(c[1] .. ((r.live and not r.empty) and " ..." or ""))
  end
  for _, item in ipairs(e.kpiList) do
    if item.values then
      for i, c in ipairs(KPI_COLS) do
        local r = out[c[2]]
        local text = ""
        if not r.empty then
          local ok, v = pcall(item.cell, r)
          text = ok and (v or "") or "?"
        end
        item.values[i]:SetText(text)
      end
    end
  end
  -- skills of the chosen span (default: the latest span with data)
  local key = spanPick
  if not key or out[key].empty then
    key = "c1"
    for _, c in ipairs(KPI_COLS) do if c[2]:sub(1, 1) == "c" and not out[c[2]].empty then key = c[2] end end
  end
  for i, b in ipairs(e.pick) do
    b:SetEnabled(not out[KPI_COLS[i][2]].empty)
    b:SetStyle({ borderColor = (KPI_COLS[i][2] == key) and GOLD or CLEAR })
  end
  local r = out[key]
  fillGrid(e.rows, r.skills or {}, function(k) return skillSpanCells(k, r.damage or 0) end, M.SkillIcon)
  e.unused:SetText((r.unused and #r.unused > 0) and ("Runes in your deck not cast: " .. table.concat(r.unused, ", ")) or "")
  e.unused:SetVisible(r.unused ~= nil and #r.unused > 0)
  -- details: the snapshot at the end of the chosen span, or the live numbers
  local snaps = t.snaps or {}
  local idx = ({ w1 = 1, c1 = 1, w2 = 2, c3 = 2, w3 = 3, c5 = 3 })[key]
  local sum = snaps[idx] or (running and Model.Summary(t, now)) or snaps[#snaps]
  if sum then
    local d = detailTexts(sum, t)
    for i, l in ipairs(e.details) do l:SetText(d[i]) end
  end
  local tests = M.tests or {}
  e.noHistory:SetVisible(#tests == 0)
  for i, l in ipairs(e.history) do
    local h = tests[i]
    if h then
      local parts = {}
      for j, sn in ipairs(h.snapshots or {}) do parts[#parts + 1] = CHECK_LABELS[j] .. " " .. M.Num(sn.dps) .. " DPS" end
      l:SetText(tostring(h.when or "") .. "   " .. table.concat(parts, "   ") .. (h.stopped and "   (stopped)" or ""))
    end
    l:SetVisible(h ~= nil)
  end
end

-- Export -------------------------------------------------------------------

View.NO_ALT = "(no Alt deck)"
View.NO_DECK = "(no deck found)"

local function refreshAlt()
  local e = P.export
  local names = M.Export.DeckNames()
  local combat = e.combat:GetValue()
  local keep = e.alt:GetValue()
  local choices, present = { View.NO_ALT }, {}
  for _, n in ipairs(names) do
    if n ~= combat then choices[#choices + 1] = n; present[n] = true end
  end
  e.alt:SetChoices(choices)
  e.alt:SetValue(present[keep] and keep or View.NO_ALT)
end

local function rememberExport()
  local e = P.export
  local combat, alt = e.combat:GetValue(), e.alt:GetValue()
  M.settings.combatDeck = (combat ~= View.NO_DECK) and combat or nil
  M.settings.altDeck = (alt ~= View.NO_ALT) and alt or nil
  M.settings.includeSkills = e.skills:GetValue() == true
  M.SaveSettings()
end

-- Codes to copy (0.6.0): the game has no clipboard call, so each code sits in
-- a text box the player selects and copies (Ctrl+A, Ctrl+C).
local CODE_BOXES = {
  { "decks", "Decks", "Combat and Alt decks with their exact slots" },
  { "adventurer", "Adventurer XP", "adventurer skill levels, the XP inside them and your total adventurer XP" },
  { "producer", "Producer XP", "producer skill levels, the XP inside them and your total producer XP" },
}

local function setStatus(el, ok, msg)
  el:SetText(msg or "")
  el:RemoveClass(ok and "bad" or "good")
  el:AddClass(ok and "good" or "bad")
  el:SetVisible((msg or "") ~= "")
end

local function setCode(kind, code, note, ok)
  local box = P.export.codes[kind]
  box.value = code or ""
  box.field:SetText(box.value)
  box.note:SetText(note or "")
  box.note:RemoveClass(ok and "bad" or "dim")
  box.note:AddClass(ok and "dim" or "bad")
end

local function makeCodes()
  local e = P.export
  local combat, alt = e.combat:GetValue(), e.alt:GetValue()
  combat = (combat ~= View.NO_DECK) and combat or nil
  alt = (alt ~= View.NO_ALT) and alt or nil
  local d, why = M.Codes.Decks(combat, alt)
  setCode("decks", d, d and (#d .. " characters  ·  " .. (alt and "Combat and Alt decks" or "Combat deck")) or why, d ~= nil)
  local skills = ShroudGetSkills()
  for _, kind in ipairs({ "adventurer", "producer" }) do
    local okCall, code, info = pcall(M.Codes.Xp, kind, skills)
    if not okCall then code, info = nil, tostring(code) end
    if code then
      setCode(kind, code, #code .. " characters  ·  " .. info.skills .. " skills" ..
        ((info.missing > 0 and kind == "adventurer") and ("  ·  " .. info.missing .. " new game skill(s) the site can't take yet") or ""), true)
    else
      setCode(kind, nil, info, false)
    end
  end
  setStatus(e.status, true, "")
end

-- Deck lists change outside the add-on (no event), so they are read on every
-- open. Default: the decks picked last time, else the equipped deck as Combat
-- and the alternate deck (the swap key's) as Alt.
local function pickDecks(useCurrent)
  local e = P.export
  local names, dupes = M.Export.DeckNames()
  local has = {}
  for _, n in ipairs(names) do has[n] = true end
  local choices = (#names > 0) and names or { View.NO_DECK }
  e.combat:SetChoices(choices)
  local want = (not useCurrent and has[M.settings.combatDeck or ""]) and M.settings.combatDeck or M.Export.CurrentDeckName()
  e.combat:SetValue(has[want or ""] and want or choices[1])
  e.alt:SetChoices({ View.NO_ALT })
  e.alt:SetValue(View.NO_ALT)
  refreshAlt()
  local altWant = (not useCurrent and M.settings.altDeck) or M.Codes.AlternateDeckName()
  if altWant then
    for _, c in ipairs(e.alt:GetChoices()) do if c == altWant then e.alt:SetValue(c) end end
  end
  e.skills:SetValue(M.settings.includeSkills)
  e.warn:SetText(#dupes > 0 and ("Several decks share a name (" .. table.concat(dupes, ", ") ..
    "). The game can only tell them apart while one is equipped or set as your alternate deck: rename them in game if a code fails.") or "")
  e.warn:SetVisible(#dupes > 0)
  rememberExport()
end

local function refreshExportChoices()
  pickDecks(false)
  setStatus(P.export.fileStatus, true, "")
  makeCodes()
end

local function doExport()
  local e = P.export
  rememberExport()
  local combat, alt = e.combat:GetValue(), e.alt:GetValue()
  local ok, msg = M.Export.Run((combat ~= View.NO_DECK) and combat or nil, (alt ~= View.NO_ALT) and alt or nil, M.settings.includeSkills)
  setStatus(e.fileStatus, ok, msg)
  M.Say(msg)
end

local function field(caption, control)
  return UI.Column{ style = { marginTop = 10 }, children = { label(caption, "dim", { fontSize = 12, marginBottom = 2 }), control } }
end

local function codeBox(spec)
  local box = { value = "" }
  -- The box shows the code; anything typed in it is put back (copying doesn't change it).
  box.field = UI.TextField{ text = "", maxLength = M.Codes.MAX_LENGTH, placeholder = "Press Make codes",
    style = { width = "100%" }, onChange = function(el, v) if v ~= box.value then el:SetText(box.value) end end }
  box.note = label("", "dim", { fontSize = 11, marginTop = 2, whiteSpace = "wrap" })
  P.export.codes[spec[1]] = box
  return UI.Column{ style = { marginTop = 10 }, children = {
    UI.Row{ style = { alignItems = "center" }, children = {
      label(spec[2], "bright", { fontSize = 13 }),
      label("  " .. spec[3], "dim", { fontSize = 11, flexGrow = 1 }) } },
    box.field, box.note } }
end

local function buildExport()
  local e = P.export
  e.codes = {}
  e.combat = UI.Dropdown{ choices = { View.NO_DECK }, value = View.NO_DECK, onChange = function() refreshAlt(); rememberExport(); makeCodes() end }
  e.alt = UI.Dropdown{ choices = { View.NO_ALT }, value = View.NO_ALT, onChange = function() rememberExport(); makeCodes() end }
  e.skills = UI.Toggle{ text = "Include skill levels, XP and specializations", value = true, onChange = function() rememberExport() end }
  e.warn = UI.Label{ text = "", class = "warning", visible = false, style = { whiteSpace = "wrap", marginTop = 8 } }
  e.status = label("", "text", { whiteSpace = "wrap", marginTop = 8 })
  e.fileStatus = label("", "text", { whiteSpace = "wrap", marginTop = 8 })
  local boxes = {}
  for i, spec in ipairs(CODE_BOXES) do boxes[i] = codeBox(spec) end
  return UI.Column{ children = {
    label("Export to Tools of the Avatar", "title", { fontSize = 16 }),
    label("Copy each code (click in its box, Ctrl+A, then Ctrl+C) and paste it in the same box of Import on your build (its ... menu). " ..
      "Each code replaces only its own part of the build. No character name is included.", "dim",
      { whiteSpace = "wrap", fontSize = 12, marginTop = 2 }),
    UI.Column{ class = "inset", style = { padding = 12, marginTop = 10 }, children = {
      UI.Row{ children = {
        UI.Column{ style = { flexGrow = 1, marginRight = 8 }, children = { field("Combat deck", e.combat) } },
        UI.Column{ style = { flexGrow = 1 }, children = { field("Alt deck (optional)", e.alt) } } } },
      e.warn,
      UI.Row{ style = { marginTop = 12 }, children = {
        button("Make codes", makeCodes), button("Use equipped and alternate decks", function() pickDecks(true); makeCodes() end, { marginLeft = 6 }),
        button("Refresh decks", refreshExportChoices, { marginLeft = 6 }) } },
      boxes[1], boxes[2], boxes[3],
      e.status,
    } },
    UI.Column{ class = "inset", style = { padding = 12, marginTop = 10 }, children = {
      label("Or save a file", "dim", { fontSize = 12 }),
      UI.Row{ style = { alignItems = "center", marginTop = 6 }, children = { e.skills, label("", "dim", { flexGrow = 1 }),
        button("Save tota_export.json", doExport) } },
      label("Saved in your Lua folder (/lua path). On the site: Import, then \"Use the export file instead\".", "dim",
        { whiteSpace = "wrap", fontSize = 11, marginTop = 4 }),
      e.fileStatus,
    } },
  } }
end

-- HUD settings -------------------------------------------------------------

-- The slash commands, one per line: command, then what it does.
local function commandList()
  local rows = { label("Commands", "bright", { fontSize = 13, marginBottom = 4 }) }
  for _, c in ipairs(M.COMMAND_LIST) do
    rows[#rows + 1] = UI.Row{ style = { alignItems = "center", marginTop = 2 }, children = {
      label(c[1], "title", { fontSize = 12, width = 170, whiteSpace = "nowrap" }),
      label(c[2], "text", { fontSize = 12, flexGrow = 1, flexShrink = 1, whiteSpace = "wrap" }) } }
  end
  rows[#rows + 1] = label("Type them in the chat box.", "dim",
    { fontSize = 11, marginTop = 6, whiteSpace = "wrap" })
  return UI.Column{ class = "inset", style = { padding = 12, marginTop = 10 }, children = rows }
end

local function buildHudPage()
  local e = P.hud
  e.shown = UI.Toggle{ text = "Show the HUD", value = M.settings.hud, onChange = function(_, v) View.SetHudShown(v == true) end }
  local toggles = {}
  for _, item in ipairs(M.HUD_ITEMS) do
    toggles[#toggles + 1] = UI.Toggle{ text = item.label, value = M.settings.hudShow[item.key] == true, onChange = function(_, v)
      M.settings.hudShow[item.key] = v == true
      M.SaveSettings()
      hudLayoutKey = nil
      refreshHud(M.Now())
    end }
  end
  local count = UI.Dropdown{ choices = M.HUD_SKILL_CHOICES, value = tostring(M.settings.hudSkills), onChange = function(_, v)
    M.settings.hudSkills = tonumber(v) or 5
    M.SaveSettings()
    hudLayoutKey = nil
    refreshHud(M.Now())
  end }
  local nudge = { fontSize = 12, paddingLeft = 10, paddingRight = 10, marginRight = 4 }
  return UI.Column{ children = {
    label("Setup", "title", { fontSize = 16 }),
    UI.Column{ class = "inset", style = { padding = 12, marginTop = 10 }, children = {
      label("HUD", "bright", { fontSize = 13 }),
      e.shown,
      label("Lines shown", "dim", { fontSize = 12, marginTop = 10 }),
      UI.Grid{ columns = 2, children = toggles },
      UI.Row{ style = { alignItems = "center", marginTop = 10 }, children = { label("Skills listed", "dim", { fontSize = 12, marginRight = 8 }), count } },
    } },
    UI.Column{ class = "inset", style = { padding = 12, marginTop = 10 }, children = {
      label("Position", "dim", { fontSize = 12 }),
      label("Drag the HUD by the small grip at its top-left corner. The grip shows while Lock Status Movement is off (Interface options). Or move it here:",
        "text", { whiteSpace = "wrap", fontSize = 12, marginTop = 2 }),
      UI.Row{ style = { marginTop = 8 }, children = {
        button("Left", function() View.MoveHud(-20, 0) end, nudge), button("Up", function() View.MoveHud(0, -20) end, nudge),
        button("Down", function() View.MoveHud(0, 20) end, nudge), button("Right", function() View.MoveHud(20, 0) end, nudge),
        button("Reset position", function() View.MoveHud(nil, nil) end, nudge) } },
    } },
    commandList(),
  } }
end

local BUILDERS = { meter = buildMeter, tester = buildTester, export = buildExport, hud = buildHudPage }
local REFRESH = { meter = refreshMeter, tester = refreshTester }

local function buildWindow()
  local bar = {}
  local icon = M.Icon()
  if icon then bar[1] = UI.Image{ texture = icon, width = 24, height = 24, style = { marginRight = 10, alignSelf = "center" } } end
  for _, t in ipairs(TABS) do
    tabs[t[1]] = button(t[2], function() View.Select(t[1]) end, { borderWidth = 1, borderColor = CLEAR, marginRight = 4 })
    bar[#bar + 1] = tabs[t[1]]
  end
  host = UI.Column{ style = { paddingLeft = 14, paddingRight = 14, paddingTop = 10, paddingBottom = 14 } }
  bar[#bar + 1] = label("", "dim", { flexGrow = 1 })
  bar[#bar + 1] = label("v" .. M.VERSION, "dim", { fontSize = 12, alignSelf = "center", marginRight = 12 })
  win = UI.Window{ id = "tm_main", title = "TotA Meter " .. M.VERSION, width = 800, height = 620, minWidth = 480, minHeight = 260,
    escCloses = true, children = {
      UI.Row{ style = { paddingLeft = 10, paddingTop = 6, paddingBottom = 6 }, children = bar },
      UI.Scroll{ style = { flexGrow = 1 }, children = { host } },
    } }
end

function View.Select(name)
  if not win then return end
  if not pages[name] then
    local ok, page = pcall(BUILDERS[name])
    if not ok then M.Say("The " .. name .. " page could not be built yet (" .. tostring(page) .. "); try again in a moment.") return end
    pages[name] = host:Add(page)
  end
  for key, page in pairs(pages) do page:SetVisible(key == name) end
  for key, b in pairs(tabs) do
    b:SetStyle({ borderColor = (key == name) and GOLD or CLEAR })
    if key == name then b:AddClass("bright") else b:RemoveClass("bright") end
  end
  current = name
  if name == "export" then refreshExportChoices() end
  View.Refresh(M.Now())
end

function View.Open(name)
  if not win then
    local ok, err = pcall(buildWindow)
    if not ok then win = nil; M.Say("The window could not be built yet (" .. tostring(err) .. "); try again in a moment.") return end
  end
  if not win:IsShown() and not win:Show() then M.Say("The window can't reopen right away; try again in a moment.") return end
  View.Select(name or current or "meter")
end

function View.Toggle()
  if win and win:IsShown() then win:Hide() else View.Open(current) end
end

function View.Refresh(now)
  if not win or not win:IsShown() or not current then return end
  local fn = REFRESH[current]
  if fn and pages[current] then fn(now) end
end

-- The HUD and the open page are refreshed separately, so a problem in one
-- never freezes the other (0.6.2), and an error never reaches the game.
local function guarded(where, fn, now)
  if M.Guard then return M.Guard(where, fn, now) end
  local ok, err = pcall(fn, now)
  if not ok then M.Say("Error in " .. where .. ": " .. tostring(err)) end
  return ok
end
function View.Tick(now)
  guarded("HUD", refreshHud, now)
  guarded("window", View.Refresh, now)
end

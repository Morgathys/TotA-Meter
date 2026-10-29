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

-- Shows `spec` in `img`; `holder` remembers what it shows so nothing changes needlessly.
local function setIcon(holder, img, spec)
  if not img or not spec or holder.iconKey == spec.key then return end
  img:SetTexture(spec.tex)
  img:SetUV(spec.uv[1], spec.uv[2], spec.uv[3], spec.uv[4])
  holder.iconKey = spec.key
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
      if r.icon and iconOf then setIcon(r, r.icon, iconOf(item)) end
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
  H.title:SetText(hudTitle(s, kind, now))
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
      setIcon(r, r.icon, M.SkillIcon(k))
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
      setIcon(L, L.img, last.icon and { tex = last.icon, uv = { 0, 0, 1, 1 }, key = "i:" .. last.icon } or M.MetricIcon("total"))
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

local TABS = { { "meter", "Meter" }, { "tester", "Build Tester" }, { "export", "Export" }, { "hud", "HUD" } }

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
local METRICS = {
  { "DPS", icon = "dps", function(x) return M.Num(x.dps) end },
  { "Peak DPS (best 5 s)", icon = "peak", function(x) return M.Num(x.peakDps) end },
  { "Total damage", icon = "total", function(x) return M.Num(x.damage) end },
  { "Casts per minute", icon = "casts", function(x) return M.Dec(x.castsPerMinute) end },
  { "Critical", icon = "crit", function(x) return M.Pct(x.critRate, 1) end },
  { "Glancing", icon = "glancing", function(x) return M.Pct(x.glancingRate, 1) end },
  { "Ultraslay", icon = "ultraslay", function(x) return M.Pct(x.ultraslayRate, 1) end },
  { "Missed", icon = "missed", function(x) return M.Pct(x.missRate, 1) end },
  { "Focus spent", icon = "focus", function(x) return M.Num(x.focusSpent) end },
  { "Pet share", icon = "pet", function(x) return M.Pct(x.pet, x.damage) end },
}
local selected = nil   -- snapshot index shown in the skills table (nil = latest)

function View.SelectSnapshot(i) selected = i end

local function buildTester()
  local e = P.tester
  e.status = label("", "title", { fontSize = 16, flexGrow = 1 })
  e.start = button("Start", function() M.TesterStart() end)
  e.stop = button("Stop", function() M.TesterStop() end)
  e.reset = button("Reset", function() M.TesterReset() end)
  local top = UI.Row{ style = { alignItems = "center" }, children = { e.status, e.start, e.stop, e.reset } }
  e.bar = UI.Bar{ value = 0, color = GOLD, style = { height = 6, marginTop = 8 } }
  local marks = UI.Row{ style = { justifyContent = "space-between", marginTop = 2 }, children = {
    label("0:00", "dim", { fontSize = 11 }), label("1:00", "dim", { fontSize = 11 }), label("3:00", "dim", { fontSize = 11 }),
    label("5:00", "dim", { fontSize = 11 }) } }
  local cmpCols = { { "", 170, "left" }, { "1 min", 120 }, { "3 min", 120 }, { "5 min", 120 } }
  local cmp, cmpRows = grid(cmpCols, #METRICS, true)
  e.cmp = cmpRows
  e.pick = {}
  local pickRow = { label("Skills at", "dim", { marginRight = 8 }) }
  for i, l in ipairs(CHECK_LABELS) do
    e.pick[i] = button(l, function() selected = i; View.Refresh(M.Now()) end, { borderWidth = 1, borderColor = CLEAR })
    pickRow[#pickRow + 1] = e.pick[i]
  end
  local tbl, rows = grid(SKILL_COLS, 12, true)
  e.rows = rows
  local det, values = kvBlock(DETAIL_KEYS)
  e.details = values
  e.history = {}
  local hist = {}
  for i = 1, 5 do e.history[i] = label("", "text", { whiteSpace = "nowrap", marginTop = 2 }); hist[i] = e.history[i] end
  e.noHistory = label("No finished run yet.", "dim")
  e.body = UI.Column{ children = { heading("Snapshots"), cmp,
    UI.Row{ style = { alignItems = "center", marginTop = 14 }, children = pickRow }, tbl, heading("Details"), det } }
  return UI.Column{ children = { top,
    label("Press Start, then hit the Training Dummy. The run starts with your first hit, keeps counting, records every number at 1, 3 and 5 minutes and stops at 5 minutes.",
      "dim", { whiteSpace = "wrap", marginTop = 4, fontSize = 12 }),
    e.bar, marks, e.body, heading("Previous runs"), e.noHistory, UI.Column{ children = hist } } }
end

local function refreshTester(now)
  local e = P.tester
  local t = M.tester
  local running = t ~= nil and not t.ended
  e.status:SetText(t and ("Build Tester: " .. testerStatus(t, now)) or "Build Tester")
  e.start:SetEnabled(not running)
  e.stop:SetEnabled(running)
  e.reset:SetEnabled(t ~= nil and not running)
  e.bar:SetValue((t and t.start) and math.min(1, Model.Duration(t, now) / t.testLength) or 0)
  local snaps = t and t.snaps or {}
  local liveSum = (running and t.start) and Model.Summary(t, now) or nil
  local liveIndex = running and t.nextCheckpoint or nil
  -- comparison table: reached snapshots, the running column live (dim), the rest "-"
  fillGrid(e.cmp, METRICS, function(m)
    local cells = { m[1] }
    for i = 1, 3 do
      if snaps[i] then cells[i + 1] = m[2](snaps[i])
      elseif liveSum and liveIndex == i then cells[i + 1] = m[2](liveSum) .. " ..."
      else cells[i + 1] = "-" end
    end
    return cells
  end, function(m) return M.MetricIcon(m.icon) end)
  -- skills of the chosen snapshot (or the latest / live)
  local idx = selected
  if not idx or not snaps[idx] then idx = nil end
  local sum = idx and snaps[idx] or liveSum or snaps[#snaps]
  local shownIdx = nil   -- the snapshot button lit (none while the live numbers show)
  if idx then shownIdx = idx elseif not liveSum then shownIdx = #snaps end
  for i, b in ipairs(e.pick) do
    b:SetEnabled(snaps[i] ~= nil)
    b:SetStyle({ borderColor = (shownIdx == i) and GOLD or CLEAR })
  end
  e.body:SetVisible(t ~= nil and t.start ~= nil)
  if sum then
    fillGrid(e.rows, sum.skills, skillCells, M.SkillIcon)
    local d = detailTexts(sum, t)
    for i, l in ipairs(e.details) do l:SetText(d[i]) end
  end
  local tests = M.tests or {}
  e.noHistory:SetVisible(#tests == 0)
  for i, l in ipairs(e.history) do
    local r = tests[i]
    if r then
      local parts = {}
      for j, sn in ipairs(r.snapshots or {}) do parts[#parts + 1] = CHECK_LABELS[j] .. " " .. M.Num(sn.dps) .. " DPS" end
      l:SetText(tostring(r.when or "") .. "   " .. table.concat(parts, "   ") .. (r.stopped and "   (stopped)" or ""))
    end
    l:SetVisible(r ~= nil)
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

-- Deck lists change outside the add-on (no event), so they are read on every open.
local function refreshExportChoices()
  local e = P.export
  local names, dupes = M.Export.DeckNames()
  local choices = (#names > 0) and names or { View.NO_DECK }
  e.combat:SetChoices(choices)
  local want = M.settings.combatDeck
  local ok = false
  for _, n in ipairs(names) do if n == want then ok = true end end
  if not ok then want = M.Export.CurrentDeckName() end
  ok = false
  for _, n in ipairs(names) do if n == want then ok = true end end
  e.combat:SetValue(ok and want or choices[1])
  e.alt:SetChoices({ View.NO_ALT })
  e.alt:SetValue(View.NO_ALT)
  refreshAlt()
  if M.settings.altDeck then
    for _, c in ipairs(e.alt:GetChoices()) do if c == M.settings.altDeck then e.alt:SetValue(c) end end
  end
  e.skills:SetValue(M.settings.includeSkills)
  e.warn:SetText(#dupes > 0 and ("Several decks share a name (" .. table.concat(dupes, ", ") ..
    "). The game can't tell them apart: rename them in game before exporting one of them.") or "")
  e.warn:SetVisible(#dupes > 0)
  e.status:SetText("")
end

local function doExport()
  local e = P.export
  rememberExport()
  local combat, alt = e.combat:GetValue(), e.alt:GetValue()
  local ok, msg = M.Export.Run((combat ~= View.NO_DECK) and combat or nil, (alt ~= View.NO_ALT) and alt or nil, M.settings.includeSkills)
  e.status:SetText(msg)
  e.status:RemoveClass(ok and "bad" or "good")
  e.status:AddClass(ok and "good" or "bad")
  M.Say(msg)
end

local function field(caption, control)
  return UI.Column{ style = { marginTop = 10 }, children = { label(caption, "dim", { fontSize = 12, marginBottom = 2 }), control } }
end

local function buildExport()
  local e = P.export
  e.combat = UI.Dropdown{ choices = { View.NO_DECK }, value = View.NO_DECK, onChange = function() refreshAlt(); rememberExport() end }
  e.alt = UI.Dropdown{ choices = { View.NO_ALT }, value = View.NO_ALT, onChange = function() rememberExport() end }
  e.skills = UI.Toggle{ text = "Include skill levels, XP and specializations", value = true, onChange = function() rememberExport() end }
  e.warn = UI.Label{ text = "", class = "warning", visible = false, style = { whiteSpace = "wrap", marginTop = 8 } }
  e.status = label("", "text", { whiteSpace = "wrap", marginTop = 10 })
  return UI.Column{ children = {
    label("Export to Tools of the Avatar", "title", { fontSize = 16 }),
    label("Saves your decks, and if you like your skill levels and XP, in a file to upload on your build's page.", "dim",
      { whiteSpace = "wrap", fontSize = 12, marginTop = 2 }),
    UI.Column{ class = "inset", style = { padding = 12, marginTop = 10 }, children = {
      field("Combat deck", e.combat),
      field("Alt deck (optional)", e.alt),
      UI.Row{ style = { marginTop = 12 }, children = { e.skills } },
      e.warn,
      UI.Row{ style = { marginTop = 12 }, children = {
        button("Export", doExport), button("Refresh decks", refreshExportChoices, { marginLeft = 6 }) } },
      e.status,
    } },
    label("The file tota_export.json is saved in your Lua folder (type /lua path to open it). It holds no character name.",
      "dim", { whiteSpace = "wrap", marginTop = 10, fontSize = 12 }),
  } }
end

-- HUD settings -------------------------------------------------------------

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
    label("HUD", "title", { fontSize = 16 }),
    UI.Column{ class = "inset", style = { padding = 12, marginTop = 10 }, children = {
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

function View.Tick(now)
  refreshHud(now)
  View.Refresh(now)
end

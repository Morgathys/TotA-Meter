# TotA Meter

DPS meter and Build Tester for **Tools of the Avatar**. It counts only **your** damage and **your pet's**; other players and party members are ignored.

Version 1.0.0 · slug `tota-meter` · minimum Lua API 25.

## Install
1. Create a folder named `tota-meter` in your Lua folder (type `/lua path` in game to find it) and copy
   every file from this `TotA Meter` folder into it. You should have `<Lua folder>/tota-meter/manifest.json`.
   The folder must be named `tota-meter`: the game only loads a package whose folder matches its slug,
   and the icons load from `tota-meter/`.
2. Type `/lua reload`, then switch **TotA Meter** ON in the Add-on Manager.

Open it with the **Menu** button on the HUD (or `/tota`). The window has four tabs: Meter, Build Tester, Export and Setup. The Meter and Build Tester metrics are always shown, with "-" until the first hit.

## Meter
Cumulative until you press **Reset meter**: every fight adds up, and DPS is measured over combat time (the time between fights is not counted). DPS (and the last 5 seconds), peak DPS (best 5 seconds), total damage, combat time and number of fights, critical rate, casts per minute, pet share, missed attacks; per skill and pet attack: damage and share, highest hit, uses and uses per minute, critical, glancing and ultraslay rates, and **focus per cast** (estimate); damage by type, combos, Combat / Alt deck split, your attack speed and crit at the start, and any potion or food active.

## Build Tester
Press **Start**, then hit the Training Dummy. The run starts with your first hit and lasts **5:00**: the clock never pauses, and **Reset** cancels a run. The last 10 runs are kept, with their KPIs.

The **Performance** table shows 29 KPIs, each with its icon (hover a KPI for what it means), for every window on its own (**0-1**, **1-3**, **3-5** minutes) and from your first hit (**@1**, **@3**, **@5**). The minute is for burst (most creatures die in under a minute), 3 minutes for stability once cooldowns run, 5 minutes for focus sustainability. Damage counts you and your pet, combos included.

| Group | KPIs |
|---|---|
| Damage | DPS, Peak Burst, Opener DPS, Ramp-up Time, Kill Clock 10k / 25k / 50k |
| Hit quality | Average Hit, Average Crit, Crit Power, Crit Rate, Crit Gain |
| Rhythm and usability | Tempo, Tempo Efficiency, Cast Gap, Deck Use, Rotation Depth, Locked Share, Alt Deck Share |
| Stability | Consistency, Spread, Downtime, Hold Ratio, Trend |
| Focus and sustainability | Focus Spent, Focus Level, Focus Balance, Focus Runway, Starved Time, Damage per Focus, Focus per Cast |

Under it, the skills table for any span (average hit and crit, crit power and rate, uses, focus per cast, damage per focus), the runes of your deck you never cast, and the details (damage by type, combos, decks, your stats at the start). The formulas are in `build-tester-kpis.md` of the Tools of the Avatar project. Deck Use and Locked Share need the game's Lua API 56. The Alt deck is the one picked in the Export tab, else the one you were not on when you pressed Start.

## Export
The Export tab has one space each for the deck choice, the Decks code, the XP codes, the Build Tester code and the file. It makes three codes for **Import** on Tools of the Avatar (open your build, then its ⋯ menu → Import). The game has no copy button for add-ons, so copy each code from its box: click in it, **Ctrl+A**, then **Ctrl+C**, and paste it in the box of the same name on the site.

| Code | What it replaces on the site | Size |
|---|---|---|
| **Decks** (`TOTA1D:`) | the Combat and Alt decks, with their exact locked and dynamic slots | ~175 characters |
| **Adventurer XP** (`TOTA1A:`) | every adventurer skill's level, the XP inside it, and your total adventurer XP | ~530 characters |
| **Producer XP** (`TOTA1P:`) | the same for producer skills | ~400 characters |

**Build Tester code** (`TOTA1T:`): under the three codes, pick a saved run (the last 10 are kept) and copy its code; a long run comes in **two parts** (copy both). On the site, paste it in your build's Deck Builder page → **Metrics & KPIs** → **Import a test**: every KPI, the 5-second timeline for the charts, your skills and the decks tested. A build keeps its last 5 tests.

Each code replaces only its own part of the build, so you can paste one, two or all three. Goal levels are kept. The Combat deck defaults to your equipped deck and the Alt deck to your alternate deck (the one the swap key switches to); pick others in the dropdowns. No character name is included.

The Decks code needs the game's Lua API 56 or later. **Save tota_export.json** still writes the old file (now with each deck's exact layout); on the site use Import → *Use the export file instead*.

## Setup
Choose its lines (DPS, peak DPS, total damage, critical rate, skill damage share, skill max hit, skill uses per minute) and how many skills it lists. Move it by the grip at its top-left corner (shown while Lock Status Movement is off in the Interface options) or with the buttons on this tab.

## Loot
The HUD's bottom line (as tall as the item's icon) shows the last item of note you looted ("No artifact yet" until one drops), in its colour; hover it for the last 20. The list is kept per character across reloads and relogs until **Reset meter** clears it. Items of note:
- **artifacts, orange**: a name with *common*, *uncommon*, *rare*, *legendary* or *epic* anywhere in it, or containing: Short Glowing Blue Cylinder, Short Glowing Cylinder, Ring of Luck, Cowbell of Reaping, Embry's Harp, Fleet Flute, Flute of Defiance, Glowing Belt Buckle, Harp of Invigoration, Lute of Discordant Notes, Lute of Inspiration;
- **other items, normal colour**: Supply Bundle, Book of Learning, Strip of Thick Troll Skin, Mossy Green Handle, Savage Handle, Torc'Dawl's, Lich Skull, Troll Rib Cage, Troll Pelvic Bones, Unicorn Blood, Unicorn Hair, Shadow Essence;
- **Crown of the Obsidians, yellow**;
- **blueprints, normal colour** (a name starting with *Blueprint*).

Only loot counts (0.8.1): an item is logged when it reaches your bags **and** the chat says "You looted an item (…)" for it within 5 seconds. Items taken out of your bank, a chest or a crafting station have no such line and are left out. The game's tooltips have no colours, so the hover list is plain text.

## Experience
The HUD's top line, under the title, shows **Adv XP** and **Prod XP** side by side: they add up the Adventurer and Producer experience you gained since the last **Reset meter** (kept across reloads and relogs). Switch them on or off in the Setup tab.

## Commands
Type them in the chat box; the Setup tab lists them too.

| Command | What it does |
|---|---|
| `/tota` | Open or close the window |
| `/tota tester start` · `reset` | Start a Build Tester run, or cancel / clear it |
| `/tota export` | Open the Export tab |
| `/tota setup` | Open the Setup tab |
| `/tota hud` | Show or hide the HUD |
| `/tota debug` | Check that the meter receives and counts your combat lines |
| `/tota errors` · `errors clear` | List the errors caught since the last reload, or forget them |

Focus per cast is an estimate: the focus you lose just before each hit.

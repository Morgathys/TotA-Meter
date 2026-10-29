# TotA Meter

DPS meter and Build Tester for **Tools of the Avatar**. It counts only **your** damage and **your pet's**; other players and party members are ignored.

Version 0.5.2 · slug `tota-meter` · minimum Lua API 25.

## Install
1. Create a folder named `tota-meter` in your Lua folder (type `/lua path` in game to find it) and copy
   every file from this `TotA Meter` folder into it. You should have `<Lua folder>/tota-meter/manifest.json`.
   The folder must be named `tota-meter`: the game only loads a package whose folder matches its slug,
   and the icons load from `tota-meter/`.
2. Type `/lua reload`, then switch **TotA Meter** ON in the Add-on Manager.

Open it with the **Menu** button on the HUD (or `/totameter`). The window has four tabs.

## Meter
Cumulative until you press **Reset meter**: every fight adds up, and DPS is measured over combat time (the time between fights is not counted). DPS (and the last 5 seconds), peak DPS (best 5 seconds), total damage, combat time and number of fights, critical rate, casts per minute, pet share, missed attacks; per skill and pet attack: damage and share, highest hit, uses and uses per minute, critical, glancing and ultraslay rates, and **focus per cast** (estimate); damage by type, combos, Combat / Alt deck split, your attack speed and crit at the start, and any potion or food active.

## Build Tester
Press **Start**, then hit the Training Dummy. The run starts with your first hit and keeps counting; every number is recorded at **1, 3 and 5 minutes**, and the run stops at 5 minutes. Compare the three snapshots side by side and open the skills of any of them. **Stop** ends a run early, **Reset** clears it. The last 10 runs are kept.

## Export
Pick your Combat deck and, if you like, your Alt deck; choose whether to include your skill levels, XP and specializations; press **Export**. The file `tota_export.json` is saved in your Lua folder (`/lua path`). On Tools of the Avatar, open your build, then ⋯ → **Import** and choose the file; paste the deck codes copied in game as well to keep the exact slot layout (the game doesn't tell add-ons which slots are locked or dynamic). It holds no character name.

## HUD
Choose its lines (DPS, peak DPS, total damage, critical rate, skill damage share, skill max hit, skill uses per minute) and how many skills it lists. Move it by the grip at its top-left corner (shown while Lock Status Movement is off in the Interface options) or with the buttons on this tab.

## Loot
The HUD's bottom line (as tall as the item's icon) shows the last item of note you got ("No artifact yet" until one drops); hover it for the last 20. The list is kept per character across reloads and relogs until **Reset meter** clears it. Items of note:
- **artifacts**: a name with *common*, *uncommon*, *rare*, *legendary* or *epic*, or containing: Short Glowing Blue Cylinder, Supply Bundle, Book of Learning, Ring of Luck, Cowbell of Reaping, Embry's Harp, Fleet Flute, Flute of Defiance, Glowing Belt Buckle, Harp of Invigoration, Lute of Discordant Notes, Strip of Thick Troll Skin, Short Glowing Cylinder, Lute of Inspiration, Mossy Green Handle, Savage Handle, Torc'Dawl's, Lich Skull, Troll Rib Cage, Troll Pelvic Bones, Unicorn Blood, Unicorn Hair, Shadow Essence;
- **Crown of the Obsidians**;
- **blueprints** (a name starting with *Blueprint*).

Items taken out of your bank or a chest count as gained too: the game reports them the same way.

## Commands
`/totameter` (window) · `tester start|stop|reset` · `export` · `hud`

Focus per cast is an estimate: the focus you lose just before each hit.

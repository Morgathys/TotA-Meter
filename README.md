# TotA Meter

TotA Meter is a DPS meter, with a small HUD that also tracks the XP you gain and the loot you find. Its Build Tester scores your build over a 5-minute run, from burst damage to focus consumption. Export codes bring your decks, skill XP and test results to the [Tools of the Avatar](https://tota.149600000.xyz) website.

An add-on for **Shroud of the Avatar** (game Lua API 25 or later; deck codes need API 56).

## Install

1. Download the latest `tota-meter-<version>.zip` from [Releases](../../releases), or this repository's `tota-meter` folder.
2. Unzip it into your Lua folder (type `/lua path` in game to find it). You should have `<Lua folder>/tota-meter/manifest.json`.
   The folder must be named `tota-meter`, or the game won't load it.
3. Type `/lua reload`, then switch **TotA Meter** ON in the Add-on Manager. Open it with the HUD's **Menu** button or `/tota`.

Full guide: [tota-meter/README.md](tota-meter/README.md).

## Repository

- `tota-meter/`: the add-on, exactly as it goes in the game's Lua folder.
- Moved here from [Morgathys/SotA_LUA](https://github.com/Morgathys/SotA_LUA) with its history (2026-11-01).

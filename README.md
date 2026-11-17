# BeautifulItemTree

German texts, German names and a calmer look for **ItemTree** on **World of Warcraft: Forever**.

> **Unofficial companion.** BeautifulItemTree is not made or supported by ItemTree's author. It needs **ItemTree**, which you install separately from [its own project page](https://www.curseforge.com/wow/addons/itemtree). This addon contains no ItemTree files, art or logo.



## What it does

ItemTree stays exactly as it is; BeautifulItemTree only changes what you see while you play. Every part can be switched off on its own, and if anything is missing or ItemTree changes, that part quietly falls back to the original.

- **German interface** (German client): every text of the ItemTree window, its tooltips and its options page.
- **German names**: instances, zones, wings, bosses, creatures, items, quests and spells, taken from your own game client. Names the client does not know yet are looked up while you play and remembered. A setting shows ItemTree's English name in the tooltip as well.
- **German search**: type a German or an English word, with or without umlauts or part of a word; ItemTree's own results come first, German matches follow.
- **A calmer look**: ItemTree's colours follow a Beautiful theme and your accent colour (light and dark themes, optional EllesmereUI accent and font), with flat tabs, buttons and frames.
- **Options** as a "Beautiful" page under ItemTree in the game settings, or with `/bit`.

The share window ("Help make ItemTree better") works as ItemTree built it: its link, its button and the text it creates stay untouched, so the website can read them.

## Install

1. Install **ItemTree** from its own project page.
2. Install BeautifulItemTree through CurseForge, or copy the `BeautifulItemTree` folder into `World of Warcraft\_forever_\Interface\AddOns`.
3. Start the game. With a German client everything is German; with another client only the look is changed.

## Commands

- `/bit` – open the settings
- `/bit status` – state of every part and the ItemTree version
- `/bit creatures` – state of the German creature names
- `/bit probe`, `/bit legend`, `/bit places` – information for bug reports

## Notes

- ItemTree changes often. BeautifulItemTree checks the version it finds; with a version it has not been tested with, `/bit status` says so and the parts that cannot find what they need switch themselves off.
- Please report problems with BeautifulItemTree in this repository's issues, not to ItemTree's author. Include the output of `/bit status`.

## License

MIT, see `LICENSE`.

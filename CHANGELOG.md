# Changelog

## 0.1.1

- Tested with ItemTree v1.2.6 (v1.2.5 still works): new texts in German (costs, Craftsman's Writs, Back and Forward, gamepad
  keys), and the customer named in a writ's tooltip is shown in German.
- Faster: the layer switches are checked once instead of on every drawn row and texture.
- Faster first search: a large item list is read in slices; German matches that come in later show up by themselves.
- Light look: while the window is open, only new and visible rows are looked at each second, not the whole window.
- A failing German name display now switches off alone with one chat message and shows in /bit status, instead of failing
  silently on every row.
- The cache of translated display texts no longer grows for the whole session.

## 0.1.0

- First release. German interface, German names (instances, zones, bosses, creatures, items, quests, spells), German
  search, a Beautiful look for the ItemTree window and a "Beautiful" settings page under ItemTree.
- Tested with ItemTree v1.2.5.

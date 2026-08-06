# NPC Bubbles

A bubble over the NPCs who actually do something — so the person holding the
Town Map does not look like the person who wants to tell you about ledges.

| Bubble | Means |
| --- | --- |
| `!` | talking to them hands you something |
| `?` | talking to them changes the world |
| smile | their dialogue reacts to your progress |

All three are the engine's own emote sheet — the same `!` a trainer shows
when they spot you, baked through the same OBP0 remap so the bubble's
interior reads white rather than grey.

## Install

Download the `.zip` from
[Releases](https://github.com/ddagent/gen1recomp-npc-bubbles/releases) and
install it in the game: **MODS → Import mod .zip**.

## Test it

```sh
luajit mods/npc_bubbles/tests/npc_bubbles_test.lua   # 21 checks, no ROM needed
python3 tools/modkit.py validate npc_bubbles
```

## How it knows

`OverworldState:talkTo` resolves an interaction in a fixed order, and the
hand-ported scripts are **data** — numbered instruction lists with
conditional jumps:

```lua
{ "check_flag", "EVENT_GOT_TOWN_MAP" },
{ "jump_if_true", 10 },          -- already have it: skip the gift
{ "check_flag", "EVENT_GOT_STARTER" },
{ "jump_if_false", 12 },         -- not eligible yet: skip the gift
{ "give_item", "TOWN_MAP", 1, "_GotMapText" },
```

So the mod walks the same instructions the game would walk, evaluating the
branches against your live save, and reports what a conversation would
produce **right now**. Nothing is executed — commands are only classified.

That is stronger than "this NPC has a gift". Blue's sister is silent before
you have a starter *and* silent once you hold the map, because in both cases
the `give_item` is unreachable. One mechanism covers "already taken" and
"not yet eligible" without either being special-cased.

Bubbles are rebuilt when you enter a map and whenever a flag changes. Since
a gift script sets its flag as its last step, the bubble clears on the same
frame the conversation ends — no polling, no lag.

## Options

| Option | Shows | Default |
| --- | --- | --- |
| `GIFT BUBBLE` | `!` — you receive something | on |
| `EVENT BUBBLE` | `?` — the world changes | on |
| `STORY BUBBLE` | smile — dialogue reacts to you | on |

`STORY BUBBLE` is the broadest and the weakest signal: those NPCs give
nothing and change nothing, their words just differ depending on your flags.
If the smiles become wallpaper, turn that one off first.

## Known limits

- **Not every NPC can be read.** Some `talk` entries are hand-written Lua
  closures rather than instruction lists; those cannot be inspected without
  running them, so those NPCs get no bubble even if they hand you something.
  The count is logged on load. A missing bubble does not prove there is
  nothing there.
- **Item balls, static encounters and trainers are deliberately skipped.**
  A Poké Ball on the ground already looks like a Poké Ball, a static
  encounter is drawn as the mon, and trainers get a real `!` from the engine.
- Only NPCs on the current map are considered.

## Layout

- `manifest.json` — identity, version range, load order, permissions
- `main.lua` — the entry chunk; receives the `mod` object
- `tests/` — the ROM-free suite; excluded from the package

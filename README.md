# NPC Bubbles

> This mod was coded by AI.

Puts a bubble over the NPCs who actually do something, so the person holding
a free TM does not look like the person who wants to tell you about ledges.

| Bubble | Means |
| --- | --- |
| **`!`** | talk to them and you get something, right now |
| **faded `!`** | something here later — you cannot claim it yet |
| **`?`** | talking to them changes something in the world |
| **smile** | they say different things as you progress — worth another word later |

They are the game's own bubbles — the same `!` a trainer shows when they spot
you — and they sit in the same place above the head.

Try it: walk into Viridian City and look for a `!`.

## What it does

A bubble only appears when it is true *now*. Blue's sister has nothing before
you pick a starter, shows a **`!`** once you can take the Town Map, and goes
quiet the moment you are holding it. Nothing lingers after you have taken it.

The **faded `!`** is for people who will have something for you but not yet —
Melanie before your Pikachu likes you enough, the bike shop before you have a
voucher. It turns solid when you can actually claim it.

Bubbles update the instant something changes, so one disappears as you finish
the conversation rather than on the next screen.

Poké Balls on the ground, legendary encounters and trainers are left alone —
they already look like what they are.

## Options

Set these in the in-game mod manager.

| Option | Shows | Default |
| --- | --- | --- |
| `GIFT BUBBLE` | `!` — you get something now | on |
| `EVENT BUBBLE` | `?` — the world changes | on |
| `STORY BUBBLE` | smile — they say new things as you progress | on |
| `LATER BUBBLE` | faded `!` — something here later | on |
| `LATER FADE %` | how solid the faded `!` looks | 75 |

If the smiles feel like too much, turn `STORY BUBBLE` off first — it is the
broadest one.

## Notes

- **No bubble does not always mean nothing.** A few interactions are written
  in a way the mod cannot read; those fall back to the smile, but the cover
  is not perfect.
- **"Later" can mean much later.** Some gifts are behind badges you will not
  have for hours, so a faded `!` may sit there a long time. Turn
  `LATER BUBBLE` off if that bothers you.
- Works on Red, Blue and Yellow.

## Install

Download the `.zip` from
[Releases](https://github.com/ddagent/gen1recomp-npc-bubbles/releases) and
install it from the game: **MODS → Import mod .zip**. After that the launcher
offers **Update** whenever a new version appears.

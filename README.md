# NPC Bubbles

> This mod was coded by AI.

Puts a bubble over the NPCs who actually do something, so the person holding
a free TM does not look like the person who wants to tell you about ledges.

![An NPC in town with a solid ! bubble over their head](docs/screenshot-town.png)

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

The **smile** is for people worth another word later — they say different
things as you progress. It goes once they have nothing new left: the gym
guide loses his the moment you beat the leader, because the advice he was
offering is behind you.

![Two NPCs in the bike shop, each with a smile bubble](docs/screenshot-bikeshop.png)

Bubbles update the instant something changes, so one steps down as you finish
the conversation rather than on the next screen.

Signs get them too, where a sign has something for you: each of the Fuchsia
zoo placards shows a **`!`** until that Pokémon is in your Pokédex.

Poké Balls on the ground are left alone — they already look like what they
are. So are ordinary trainers, who announce themselves. A gym leader keeps a
**`!`** until you have both their badge and the TM they hand over afterwards.

## Options

**START → OPTIONS → NPC BUBBLES..**, near the top of the list. It holds the
guide and every setting below. They are also on the mod manager's page —
either place works, and both change the same setting.

| Option | Shows | Default |
| --- | --- | --- |
| `! BUBBLE` | `!` — you get something now | on |
| `FADED ! BUBBLE` | faded `!` — something here later | on |
| `? BUBBLE` | `?` — the world changes | on |
| `SMILE BUBBLE` | smile — they say new things as you progress | on |
| `CLEAR AFTER TALK` | a smile clears once you have heard what they say, and returns when they say something new | off |
| `HIDDEN BY WALLS` | hides a bubble whose NPC is behind a roof, in first and third person | off |
| `LATER FADE` | how solid the faded `!` looks | 50 |

If the smiles feel like too much, turn `SMILE BUBBLE` off first — it is the
broadest one. `CLEAR AFTER TALK` is the gentler version: instead of hiding
them all, each one goes as you hear it, and comes back if that person starts
saying something new. Only smiles are affected — a `!` never hides because
you spoke to someone.

The guide inside that page draws the four bubbles at the size they appear
over an NPC, so you can see which is which.

## How much is left

The guide opens with a count: how many people and signs still have something
for you, out of everyone who ever did, and the same count for wherever you
are standing. A town is counted together with its buildings, so PEWTER CITY
covers the gym, the mart and the museum.

Each place breaks down by building, so a town lists its gym, its mart and
its museum on separate lines with their own counts. Standing inside one of
them shows the same list — the town you are in, not the room.

Under that is everywhere you have been, one line each, so you can see at a
glance where there is most still to do. It only lists places you have
actually been, so it never names somewhere you have not found yet — towns,
routes and caves alike.

Only jobs count. The hundreds of people with nothing to offer are left out,
and so are smiles — a smile means someone is worth another word later, not
that you have something to do. Somebody who has finished with you and left
town still counts, and counts as done — the old man outside Viridian does
not vanish from the tally when he packs up. Somebody who has not shown up
yet is not counted until they do, so the total grows a little as the game
opens up. It never goes down, so finishing something can only ever move the
score forwards.

## Notes

- **No bubble does not always mean nothing.** A few interactions are written
  in a way the mod cannot read; those fall back to the smile, but the cover
  is not perfect.
- **A few people say something different every time you ask** — the POKéMON
  beside the trainer in Cerulean, the chef on the S.S. ANNE. Hearing them
  once counts as hearing them, so `CLEAR AFTER TALK` does not leave their
  bubble flickering.
- **"Later" can mean much later.** Some gifts are behind badges you will not
  have for hours, so a faded `!` may sit there a long time. Turn
  `LATER BUBBLE` off if that bothers you.
- **Mods that add their own people.** Where another mod writes its NPCs as
  instruction lists they get markers like anyone else. Where it writes them
  as code, they fall back to the smile — working out what they hold would
  mean running their script, and that is theirs to run, not ours.
- Works on Red, Blue and Yellow.

## Install

Download the `.zip` from
[Releases](https://github.com/ddagent/gen1recomp-npc-bubbles/releases) and
install it from the game: **MODS → Import mod .zip**. After that the launcher
offers **Update** whenever a new version appears.

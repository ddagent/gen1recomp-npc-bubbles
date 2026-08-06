# Changelog

Format: [keep a changelog](https://keepachangelog.com/en/1.1.0/).
Version headings match `manifest.json`'s `version`.

## 1.4.0

### Fixed

- **Probing could have touched your game.** Not every closure is a builder:
  the bike shop clerk pushes its own text boxes and reaches into the bag
  (`data/scripts/story2.lua`), and a probe handed it the live game. A pcall
  does not help there, because a text box appearing is a success, not an
  error. Probes now get a copy of the save and a stack that swallows
  pushes, so an imperative closure spends itself harmlessly on the stub.

### Changed

- An NPC whose script cannot be read now shows the smile rather than
  nothing. A closure exists precisely because the interaction did not fit
  the command rows — the bike shop clerk, Misty, the badge house — so
  "cannot read this" is itself a signal that something bespoke happens here.
  Ordinary NPCs have no script at all and stay bare.

## 1.3.0

### Changed

- The come-back-later `!` was too faint to read at 45%. It is now a
  `LATER FADE %` dial, default 75, read at draw time so it moves as you turn
  it. Where the line sits between "clearly subordinate" and "invisible"
  depends on the renderer and how bright the ground is, so it should not
  have been a constant.

## 1.2.1

### Fixed

- Gifts you have to accept were invisible. `ask` is a yes/no prompt answered
  at the time, not read off the save, and the walker left the last condition
  false — so `jump_if_false` skipped straight past the gift. It was silently
  deciding you had *declined* every gift that asks first, which is why
  Melanie never showed anything. `ask`, `choice` and `give_*` now take the
  branch a player who wants the thing would take.
- A closure whose prerequisite is unmet writes no gift row at all, so there
  was nothing for the come-back-later check to find. Closures are now
  rebuilt a second time against a best-case save, which reveals whether a
  gift exists at all.
- That second build could then leave a faded `!` over a gift you had already
  claimed, forever. A claimed gift is now recognised by the flag that build
  would *set* already being on — the only workable receipt for a closure,
  whose own check lives in Lua rather than in the rows.

## 1.2.0

### Added

- A faded `!` for "there is something here, but not yet" — Melanie before
  Pikachu is happy enough, the bike shop before you hold a voucher. The same
  exclamation crop at lower opacity rather than a new symbol: nothing to
  hand-draw, and it reads as the important kind of NPC without claiming to
  be actionable.
- `LATER BUBBLE` toggle, on by default.

### Note

Telling "not yet" from "already taken" is what lets this exist without the
stale bubbles coming back. A claimed gift is blocked by the very flag its
script set when it gave it to you; a prerequisite is anything else — an
item, a happiness threshold, a badge. Of the 29 gift programs, 14 guard
themselves that way and 15 are gated by something else, so both halves are
real. It is a judgement, not a proof: a script gating its gift on another
script's flag would read as "later" indefinitely.

## 1.1.0

### Fixed

- A smiley appeared over almost every NPC. The tier-3 rule assigned itself
  to any command that was not a gift or a world change, so it meant "has a
  script at all" rather than "reacts to your progress" — 116 of 173 smileys
  were over people who say one fixed line. Tier 3 now requires a
  `check_flag` / `check_item` / `check_dex_owned` somewhere in the program.
  Total bubbles across the game drop from 250 to 134.

### Added

- Closure talk entries are now read too. They are not opaque logic: they
  read your save, build the rows the conversation would run, and hand them
  to `ow.runner:run` as their last act. The mod calls them with a runner
  that captures instead of running, and walks the program that falls out —
  so Melanie's Bulbasaur is classified like any other, and vanishes once you
  hold it. Nothing is executed; a closure that does not fit the pattern is
  caught and left unclassified exactly as before.

## 1.0.2

### Fixed

- Bubbles appeared several tiles east of their NPC. The overworld has two
  draw paths: a flat blit, and a tilt/billboard one (the voxel diorama) that
  wraps each sprite in its own transform and reaches the engine's emote
  through an `at(...)` helper. Drawing once per frame from outside meant
  reproducing whichever transform was live, and the flat coordinates landed
  wrong under tilt.
- The bubble is now drawn inside `NPC.draw`, immediately after that NPC's
  own sprite, so it inherits whatever transform the sprite was drawn under
  and is correct in both modes. One class-level wrap covers every NPC on
  every map, so nothing needs re-attaching on a map change.

## 1.0.1

### Fixed

- No bubbles appeared anywhere. The mod decorated `OverworldState:draw`,
  but that is `beginWorldPass / drawWorld / endWorldPass / drawUI` — so the
  bubbles were drawn after the world pass had already ended, outside the
  space `npc.px - cam.x` is measured in. They now go inside `drawWorld`,
  where the engine draws its own sighting bubble.
- Placement matches the engine exactly: `+4` across and `-14` up from the
  sprite's origin, the same offsets `fxEmote` uses, so a mod bubble sits at
  the same height as a trainer's.

## 1.0.0

### Added

- A bubble over NPCs whose conversation would actually do something:
  `!` for a gift, `?` for a world change, the smile for story dialogue.
- `GIFT BUBBLE`, `EVENT BUBBLE` and `STORY BUBBLE` toggles, all on.

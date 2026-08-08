# Changelog

Format: [keep a changelog](https://keepachangelog.com/en/1.1.0/).
Version headings match `manifest.json`'s `version`.

## 2.2.2

### Fixed

- **`CLEAR AFTER TALK` now reaches every smile in the game.** Some people
  never push a line of their own -- they hand the whole scene over to be
  played out, your rival on POKeMON TOWER 2F among them -- and the mod was
  listening only for the first kind. It reads both now. Swept the game
  again: no smile is left that talking cannot clear.

## 2.2.1

### Fixed

- **A cleared smile came back on its own.** The CERULEAN SLOWBRO, ELECTRODE
  and COOLTRAINER each pick one of four lines at random, and the SS ANNE chef
  rolls his main course, so the next look usually found something different
  and decided they had new to say. Talking to them repeatedly, or stepping
  in and out of a building, made it flicker. The mod now asks twice more with
  nothing changed in between: two different answers prove somebody varies on
  their own, and from then on any line from them counts as heard.
- **Probing an NPC could turn them round.** The two CERULEAN POKeMON open by
  facing the player, and they were being handed the real object rather than a
  stand-in -- so working out what bubble to draw physically turned them. It
  never touched the save, which is why the save check never caught it.

## 2.2.0

### Added

- **`CLEAR AFTER TALK`**, off by default. A smile clears once you have heard
  what that person has to say, and comes back the moment they say something
  new -- beat BROCK and the PEWTER gym guide's smile returns, because his
  advice has changed. Only smiles: a `!`, a `?` or a faded `!` is never hidden
  because you spoke to somebody.
- It remembers every line it has heard, not just the last one. The SS ANNE
  chef picks his main course at random, so he goes quiet once you have heard
  all of his -- which takes a few visits.
- Turning it back off restores every smile it had cleared. Nothing is lost by
  changing your mind.

## 2.1.0

### Changed

- **An NPC with nothing left to say no longer keeps a smile.** Two cases.
  Someone who handed their gift over and can never offer another -- the ROUTE
  1 POTION man, COPYCAT, OAK's aides, the TM givers -- goes quiet. And someone
  whose dialogue is settled for good goes quiet too: once BROCK is beaten, the
  PEWTER gym guide's advice branch is unreachable forever, so the line he says
  now is the last one he will ever say. A branch decided by a flag that is
  already true can never decide differently -- only three flags in the whole
  game are ever cleared. A flag that is still FALSE, or an item check, keeps
  the bubble, because either can still change.

### Fixed

- **The CELADON MART roof girl offers her TMs properly.** She swaps three
  drinks for three TMs, and read as small talk in every state -- including
  standing there holding all three. She now shows a `!` when you are carrying
  a drink she will trade for, a faded `!` when you are not but she still owes
  you one, and nothing once all three are done.

## 2.0.1

### Added

- **Signs can carry a bubble.** They are not NPCs -- they live in
  `map.signs` and are answered by `signAtCell` -- so nothing iterated them
  and nothing drew them. The six FUCHSIA dex placards, the only signs in
  the game that hand you anything, had no marker at all. Only the `!` ones
  are drawn: a smile on a sign could never clear, because the game writes
  down nothing when you read one.
- **Gym leaders show a `!` while they still owe you a badge or a TM.**
  Sight engagement skips anyone carrying a talk script and every leader has
  one, so nothing announces them -- and their scripts cannot say so either,
  since the rewards are paid from `data/scripts/victories.lua` rather than
  from any row. All eight, and each goes quiet once both receipts are in.
- **A POKeMON handed over counts as a gift.** The watcher only read the
  bag, so the MAGIKARP salesman, the GAME CORNER's mon counters and the
  SILPH worker's LAPRAS all looked like they did nothing.
- **Menus get answered.** The probe already said yes to a yes/no; a list it
  could not answer just sat there unpicked, which is why the CELADON
  vending machines -- shops -- read as small talk.

### Changed

- `LATER FADE` defaults to 50 rather than 75. Three quarters opacity was
  close enough to solid that a come-back-later `!` was hard to tell from a
  real one on the handheld.

### Fixed

- **The VIRIDIAN MART clerk stopped wearing a permanent `!`.** Opening a
  shop is no longer counted as receiving something -- buying is not being
  given, and a shop never runs out, so no flag could ever clear him. He now
  shows a `!` for the one thing he really does hand over, OAK's PARCEL, and
  a smile once he is just a shop. Healing is untouched: that is given, not
  sold, so MOM and the SILPH nurse keep theirs.
- **A gift behind a battle is visible before the fight.** The row after a
  battle asks "did you LOSE?", and that was answered with whatever stale
  reading the last flag check left behind -- so the walk took the losing
  path and never saw what came after. The CERULEAN thief's TM28 sat behind
  exactly that, leaving him unmarked until after he was beaten, by which
  point the TM had already been handed over in the same breath. The walk now
  assumes you win, for the same reason it assumes yes to an `ask`.
- **A finished trade stops asking.** A trade names the flag it sets as its
  own third argument, and nothing was reading it, so all six in-game trades
  kept their `!` for the rest of the save.


- **A bubble over somebody with nothing to give.** `jump "end"` is the
  engine's reserved halt (ScriptRunner), not a label anyone declares. The
  walker read it as an unresolvable label and fell through to the next
  line -- straight into the branch the script had just decided to skip.
  MOM's `heal_party` sits immediately after the `jump "end"` that ends the
  no-starter path, so a brand new save showed a `!` over her; OAK did the
  same after the rival battle. 25 scripts use that halt.
- **A gift that hands itself over kept its `!`.** `flag.changed` is emitted
  by `Flags.set`, and the shared `gift()` helper assigns
  `save.flags[...] = true` directly, so nothing told the mod anything had
  happened -- the ROUTE 1 POTION man stayed marked until the map changed.
  The A press is noticed instead and settled once the world has the player
  back: no box on the stack, no script running, input unlocked. It
  deliberately does not settle mid-conversation.



- **A probe could write into the real save.** `give_pokemon` calls
  `Party.add(save.party, mon)`, and the sandbox read `party` straight
  through to the player's own list: probing a seller put a MAGIKARP in the
  party and probing the day care raised a real POKeMON's level. Every probe
  now reads from the rebuild's deep copy, so a write at any depth lands
  there -- which also closed leaks nobody had named, including the object
  toggles a `hide_object` writes. There is a test that serialises the whole
  save before and after and fails on any difference.
- **A dex sign stops asking once you have the entry.** `mark_seen` counted
  as a gift unconditionally, which would have left the FUCHSIA placards
  marked forever; and if you met the species in the wild first, the sign
  never speaks up at all.
- **A gift behind a world gate is found.** Both MT MOON fossils sit behind
  `superNerdBeaten(ow)`, and the best-case probe was handed an empty world,
  so the call threw and the fossil behind it was never seen. They now read
  as come-back-later while he is standing and a solid `!` once he is not.
- **A gift survives a script that throws after handing it over.** The
  museum scientist gives the OLD AMBER and then hides the exhibit, which
  needs a real map; the run was discarded on that error and the giver came
  out a smile.
- Money and coins are stood in for while probing, so a shop reads as a shop
  whether or not you can afford it today -- matching `open_mart`, which was
  already unconditional.

## 1.9.0

### Added

- **A guide**, in START > OPTIONS under `NPC BUBBLES`. It draws the four
  bubbles themselves -- the real crops from the emote sheet, at the size
  they appear over an NPC, with the faded one drawn at whatever your
  `LATER FADE` is set to. Words can say "SMILE"; only a picture answers
  "what did the faded one look like again". Wraps and scrolls.
- `HIDDEN BY WALLS`, off by default: on the first- and third-person rungs, a
  bubble whose NPC is behind a roof is hidden with him. The arena leaves
  NPCs to honest occlusion -- only the player gets a see-through silhouette
  -- so a bubble over a roof whose NPC is correctly hidden was wrong.
- It reads the arena's own per-tile height field, which is why a fence at 10
  hides nothing and a roof at 28 does. A real depth test is not reachable
  from a mod: the depth buffer exists only while the arena's pass is open
  and no pipeline hook runs inside it. So it is an approximation, it is off
  unless asked for, and every uncertainty draws the bubble.

### Changed

- The toggles name the symbol they switch -- `! BUBBLE`, `FADED ! BUBBLE`,
  `? BUBBLE`, `SMILE BUBBLE` -- with the two exclamation marks together, so
  the faded one is read against the solid one.

### Fixed

- `LATER FADE %` had a `%` in it, which the Game Boy charmap has no glyph
  for, so it has been printing as a blank gap ever since the option
  existed. It is `LATER FADE` now.

## 1.8.0

### Fixed

- **Up close in first person the bubble shrank and sank to the floor.** The
  size and the 30-pixel offset were both quoted in screen pixels, which is
  right when the camera orbits above -- every NPC is about the same distance
  away, and the engine uses one flat number for its own field effects for
  exactly that reason. Standing among them it stops being true: an NPC a
  step away is ten times the size of one across the room, so a screen-sized
  bubble offset a screen-sized 30 pixels lands by his feet, tiny.
- On the free-cam rungs the size and offsets now come from the
  magnification **measured at that NPC**: project his feet, project a point
  one tile above them, and see how far apart they land. That is the same
  magnification the arena drew his sprite at, so the bubble keeps pace with
  him. The orbiting camera is untouched, and where depth is uniform the two
  agree.
- This is not project()'s third return. That is `focusW/cw`, and in first
  person the focus point IS the player, so `focusW` collapses towards zero
  and takes every bubble down with it -- which is why an earlier attempt at
  perspective scaling made them smaller as you approached rather than
  larger.
- Clamped either side of the flat scale so a near-plane reading cannot
  produce an invisible or screen-filling bubble.

## 1.7.2

### Changed

- **`NPC BUBBLES 3D` is gone from START > OPTIONS.** It was never a display
  mode to choose between -- it is how this mod draws when something else
  owns the world pass, and the only thing switching it off achieved was
  bubbles disappearing in 3D. Having the mod enabled is already that toggle.
- Drawing over an arena's world pass does require registering a pipeline,
  and the menu lists every pipeline there is. So the row is dropped on its
  way to the menu through `ui.options.rows`, the hook the options list is
  passed through for exactly this. Every other row is untouched.
- Anyone who had already switched it off is put back on when the save
  loads, since there is no longer a control to switch it back with.

## 1.7.1

### Fixed

- **1.7.0 moved the bubble off the NPC.** It projected the head at a world
  height instead of the ground point, which slides the anchor a tile or two
  under a tilted camera. The offsets are back to the ground point -- and
  they are not eyeballed, they are what the engine's own emote works out to.
  In the pipeline path `OverworldController` anchors an emote at
  `(px + 8, py + 16)` and hands the flat closure a transform that cancels
  with `fxEmote`'s own `(+4, -14)` to exactly `sx - 4*scale, sy - 30*scale`.
- **1.7.0 shrank the bubble with distance**, which made it tiny in first
  person and disagreed with the game's own emote bubble standing beside it.
  The engine is explicit about this for every field effect: "Deliberately
  unscaled by depth, like `:billboard`: an effect keeps its crisp authored
  size and only its anchor moves." So it no longer scales.
- **1.7.0 made bubbles vanish at some distances.** A sight line walked over
  the tile grid clipped wall corners and signposts and blinked bubbles out
  while you walked. It is gone. There is no depth test to be had here --
  the depth buffer exists only while the arena's own pass is open and no
  pipeline hook runs inside it -- and the arena's own emotes draw through
  walls too, so this matches the game.

### Changed

- The arena is found by **whoever registered the `voxel` pipeline**, read
  from the registry's `_owners`, rather than by hardcoded name. A fork or a
  rename now works; the original name remains the fallback.

### Note

The `NPC BUBBLES 3D` row cannot be hidden. `Pipelines.rows()` builds a row
for every registered pipeline with no filter, and the pass has to be its own
pipeline: attaching it to the arena's would run it at priority 20, ahead of
T-SHIFT at 10, and the bubbles would come out inside the blur. It is on by
default, so it needs no attention.

## 1.7.0

### Fixed

- **Bubbles drifted down and right when anti-aliasing was on.** The arena
  renders into a canvas 2x or 4x the window and folds it back down at the
  end, so `project()` answers in the big space while this overlay draws on
  the folded one. The AA factor is now read from the voxel mod and divides
  the projected position back down.
- Only the position. `project()`'s third return is `focusW/cw` -- one number
  off the camera matrix divided by another -- so it is a ratio with no
  pixels in it and anti-aliasing cannot touch it. Dividing that as well
  would halve every bubble at 2X and quarter it at 4X.
- **Bubbles sat wrong under a low camera.** The mod anchored on the NPC's
  feet and moved a flat 30 pixels up the screen for the head, which is only
  right at one camera pitch -- in first person it barely cleared the knees.
  It now projects the head itself, at a world height of 32, so the pitch
  cannot break it.
- **Bubbles were all one size.** `project()` reports how much the camera
  magnifies a point and that was being thrown away. It now scales the
  bubble, clamped between a quarter and four times flat size: the ratio
  runs away at the near plane, and an NPC one step in front of a
  first-person camera would otherwise get a bubble taller than the screen.
- The sideways offset is measured from the sprite's **centre**, which is
  what this path projects (`px + 8`). The flat path's `+4` is measured from
  the sprite's left edge, so the same place is `-4` here.

### Added

- **A wall between you and an NPC now hides the bubble**, on the first- and
  third-person rungs. Those are the rungs where the camera stands with the
  player, so a line drawn from the player is the line the camera sees along.
  The default tilted view looks over walls on purpose and is unchanged.
- Water does not hide one. It stops you walking, not looking.

### Note

This is a sight line over the cell grid, not a depth test. A real one is not
reachable from a mod here: the depth buffer exists only while the voxel
mod's own pass is open, and none of the pipeline hooks run inside it. The
arena's own emote bubbles have the same limitation.

## 1.6.1

### Changed

- Rewrote the description shown in the mod manager. It predated the faded
  `!`, so one of the four symbols was not mentioned at all, and the smile
  was described by what it means rather than what to do about it.

## 1.6.0

### Fixed

- **No bubbles while T-SHIFT was on.** `worldPresent` folds in descending
  priority, so T-SHIFT (priority 10) runs first and hands on a *new*,
  blurred canvas. The bubbles were being drawn through the arena's
  `beginOverlay`, which binds its own scene canvas — no longer the image
  anyone would use. They now draw onto the canvas `worldPresent` is handed,
  which is correct whatever else folded before, and leaves them sharp on top
  of the blur rather than inside it.

### Changed

- The save copy a closure probe runs against is made once per rebuild rather
  than once per NPC. A save carries the party, the boxes, the bag and every
  flag, and a map with several closure NPCs was paying for a full copy each,
  on every flag change. It is keyed on the game it was built from and
  cleared on every rebuild, so it can never answer for state it was not
  built from.
- `flag.changed` marks the map stale rather than rebuilding immediately. A
  script setting three flags fired three full rebuilds; now the next draw
  settles it once.
- The bubble toggles and fade are read once per frame instead of once per
  NPC per frame.

## 1.5.0

### Fixed

- **No bubbles at all in voxel mode.** DRAMATIC_SHAPE supplies its own
  `drawWorld`, and the engine skips the entire flat entity pass when a
  pipeline renders the world — `NPC.draw`, where the bubbles are drawn, sits
  inside the skipped branch. Nothing was wrong with the drawing; the
  function it lives in never ran.
- The mod now also registers a presentation-only render pipeline
  (`worldPresent`, no `drawWorld`) that folds over the finished world image
  and projects each bubble into it, riding the same seam the engine's own
  trainer `!` uses there. Position comes from the voxel mod's public
  `project()`; the overlay canvas from its `beginOverlay()`.
- The two paths cannot both fire: `worldPresent` only runs when a pipeline
  produced a world canvas, which is exactly when `NPC.draw` is skipped.

### Note

Placement in the arena is derived from reading the voxel mod's source rather
than from seeing it run. Position should be exact; the bubble's **size** is
inferred from the canvas against the world view, and may need adjusting.

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

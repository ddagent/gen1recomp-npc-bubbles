# Plan: clearing a smile by talking

Not built. Written down so the reasoning survives.

## The idea

A smile means "they say different things as you progress". Today it clears
only when the mod can prove the dialogue is settled for good. The proposal is
to let the player clear it too: talk to someone, and their smile goes.

Off by default. With the toggle off, nothing changes.

## Why the naive version is wrong

"Talked to = cleared forever" loses information. Talk to the PEWTER gym guide
before BROCK, his smile clears; beat BROCK, and he starts saying something
new -- but he stays silent, and you never find out.

## The version worth building

Record what they *said*, not that you spoke. The smile returns when what they
would say now differs from what you last heard.

That makes the smile mean something sharper than it does today: **this person
has a line you have not heard**. It is self-correcting -- no bookkeeping about
which events matter, because the text is the signal.

## What it needs

1. **Know who was spoken to.** `world.interacted` fires with
   `{ mapId, x, y, kind, target }`, `kind = "npc"` and `target` the NPC. Note
   it fires when the A press lands, before the conversation runs, so the
   signature has to be taken after the world has the player back -- the same
   moment `settle()` already waits for.

2. **A signature of what they would say.** Not the rendered string: the text
   *identifier*. A rendered line can change for unrelated reasons (a name, a
   translation) and every smile in the game would reappear at once.
   - readable scripts: the `show_text` ids the walker reaches. Already known.
   - hand-written ones: the probe already captures each box's text and throws
     it away. Keep it.

3. **Storage.** `mod.save:get/set`, namespaced per mod and per save slot --
   the same bucket battle_dex uses for its met roll. One entry per NPC talked
   to, keyed by map id + text const, value the signature.

4. **The check.** In `rebuild`, when a tier comes out as 3, compare the
   current signature against the stored one. Equal -> draw nothing.

## How it sits with what is already there

Complementary, not a replacement. The settled rule silences people you have
never met who can never change; this silences people you have heard. Keeping
both means you do not have to visit every gym guide once just to quiet them.

## Risks

- **It grows the save.** First thing here that scales with play, and the first
  that persists something the mod invented rather than something the game
  already tracks. Cap it, or store a short hash rather than the ids.
- **A wrong signature is the worst failure mode.** If it moves for unrelated
  reasons, smiles reappear at random, which is more irritating than never
  clearing them.
- **Branching dialogue.** Someone whose line depends on a yes/no has more than
  one possible text and the probe walks one path. Signature should cover the
  path actually taken, and a different path should count as new.

## Test before shipping

- talk to the PEWTER gym guide pre-badge: smile clears
- beat BROCK: smile returns (new line)
- talk again: clears again
- an NPC with one fixed line: clears once, never returns
- toggle off: nothing clears, and nothing already stored leaks into the
  classification
- the save-serialisation test still passes: this writes to the mod's own
  bucket, never to the game's save

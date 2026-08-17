# npc_bubbles

Puts a bubble over the NPCs worth talking to, and keeps a checklist of how
much of each place is left. To decide a bubble it RUNS that NPC's talk
script, which is where all the difficulty lives.

## The one command

    bash mods/npc_bubbles/.devtools/gate.sh

The three standard checks plus a mutation runner and a check on what the zip
actually contains. All of it must be green before anything ships.

**A test that cannot fail is worse than no test.** Twelve tests here have
passed while proving nothing, so `.devtools/mutate.py` breaks the mod on
purpose and expects the suite to notice. Add an entry whenever a bug is
fixed; when one survives, read the code before writing a test, because the
rule may be unreachable rather than untested.

## Further reading

- Running someone else's script safely, and what bites -- `docs/probe.md`
- Handing the screens to Gen1 Modern UI and friends -- `docs/presenting.md`
- Why `CLEAR AFTER TALK` works the way it does -- `docs/plan-talk-clearing.md`

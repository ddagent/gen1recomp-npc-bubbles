# Running someone else's script safely

Working out what an NPC has for you means running their talk script. A row
list can be read; a closure has to be executed. Everything below exists
because executing somebody's script must not touch the real game.

## The closure runs twice, and the two passes protect differently

`programFor` runs it first, with a sandboxed save, a **noop stack** and a
shadowed npc -- but the real global `require`. If that captures no rows,
`observedGift` runs it again, and that is the only place `require` is swapped
so `src.core.Sound`, `src.core.Music`, `src.battle.BattleState` and
`src.world.PikachuFollower` come back inert.

So pass 1 has a live `require` and a dead stack; pass 2 has a working stack
and a sealed `require`. Neither can make a noise, because every audible call
in the game's scripts sits behind a callback the noop stack never fires --
the PEWTER escort fetches the real `Music` and then pushes a text box that
goes nowhere. This was checked across all 208 rooms with real map data, with
every entry point on both audio modules recorded: 79 closures run, 0 audible
calls.

## Never run another mod's closure

`safeToRun` asks `MapScripts.talkSource` who owns the script. A closure with
a `modId` is left alone and falls back to the smile. Kanto Ascendant's sailor
vanished and warped the player because we ran their script to see what it
did. Rows are data and stay safe to read.

## The traps, each of which cost a day

**`pairs()` walks own keys only.** The sandbox deep-copies a save with
`pairs()`, so any metatable-based save arrives inside the probe **empty**.
`freshBaseline` copies keys deliberately and never inherits -- reaching the
real save through `__index` is a mutation in the list for a reason.

**`mod.world` is bound to the LIVE game.** WorldAPI's `warpTo`, `removeNpc`,
`toggleObject` and `setFlag` bypass any substituted `game`, and
`game.overworld` falls through to the real overworld. Substituting `game` is
not enough on its own.

**The caches are keyed on the maps table.** `tracked` is reused between
calls, so anything written onto its items must be cleared at the top of each
pass rather than only written. A new maps table -- not maps added in place --
is what invalidates it.

**A rebuild that cannot answer must say so.** `rebuild` clears its dirty flag
only after it has a map to work with. Settling early left a new game with no
bubbles at all until the player saved and reloaded, because nothing else asks
for a rebuild.

## What the count may include

Only jobs that can be finished. A receipt is a `set_flag`, a trade's third
slot, a `mark_seen`, a victory payment, or being able to leave the map. A
shop is never finishable -- and a shop gated on an item is invisible to the
baseline, whose inventory is empty, so `recordable` reads both the baseline
program and the live one.

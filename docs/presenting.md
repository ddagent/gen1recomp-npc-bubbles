# Handing the screens to whatever draws the menus

The checklist and the guide draw themselves. A UI mod can draw them instead,
and the mod offers them to **anything that can present** rather than to one
named mod: `adapterHosts` scans the loader's exports for a mod publishing
`registerAdapter`, the same way the voxel side reads who owns the pipeline
rather than naming DRAMATIC_SHAPE. A fork or a rename is still found.

## Their contract, and the parts that bite

Read off **gen1_modern_ui 0.8.4** -- it is their API, not ours, so check it
still holds before trusting any of this against a later release.

`apiVersion = 1`, and each screen carries `match`, `model`, `actions` and
`canSuppressNative`.

**`match` takes ONE argument.** They call `pcall(screen.match, state)` -- the
state alone -- while `model` and `actions` take `(game, state)`. A matcher
written as `function(_, state)` can never fire, and a test that calls it with
the assumed arity passes while the bug ships. It did.

**A model may contain no functions.** Their side rejects one that does, so
nothing of ours can run inside theirs. The suite walks the model looking for
callables.

**Their model is rebuilt every frame it draws.** `modelFor` memoises nothing,
and one caller sits inside a draw function. So anything expensive inside a
model is paid per frame: four GPU canvases per frame for the guide's bubble
pictures took it from opening instantly to a minute of dead input on a
handheld. Bake once, key the cache on anything baked in -- the faded bubble's
alpha comes from `LATER FADE` and has to still move.

## Saying the same list twice without writing it twice

`checklistLines` returns the lines **and** a `marks` table saying what each
line is: `head` for the name of the place you are in, `rule` for the line
under it, `tally` for a count belonging to the line above, `cont` for the
rest of a name too long for our box.

Our screen draws all four literally. A presenter with real headings and a
right-hand column says the same thing its own way: `rule` lines are dropped
because their heading draws its own divider, `cont` joins onto the row above,
`tally` becomes that row's value. One description, so the two cannot drift --
and `CINNABAR ISLAND`, the one real place name that wraps, stays one row.

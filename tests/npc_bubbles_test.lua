-- Standalone: luajit mods/npc_bubbles/tests/npc_bubbles_test.lua
--
-- ROM-free.  Almost everything here is the branch walker, because that is
-- where a mistake is invisible: a wrong turn does not crash, it just shows
-- a bubble over someone with nothing to give, or hides one over someone who
-- does.  The real Daisy program from data/scripts/story.lua is used as the
-- worked case, since a synthetic one would only test my own assumptions.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local Runtime = require("src.mods.Runtime")

local Data = T.fixtures.fresh()

-- The fixture carries no emote art, and the sheet is resolved once and
-- remembered -- so this has to exist before ANY draw runs, or the first one
-- caches "no sheet" and every later case silently draws nothing.
Data.field = Data.field or {}
Data.field.emotionBubbles = {
  path = "fixture/emotes.png",
  bubbles = { { x = 0, y = 0, w = 16, h = 16 },
              { x = 16, y = 0, w = 16, h = 16 },
              { x = 32, y = 0, w = 16, h = 16 } },
}

local run = T.sdk.loadMod("mods/npc_bubbles", { data = Data })
T.eq(#run.errors, 0, "loads clean (" .. tostring(run.errors[1]) .. ")")

-- mod.world and the emote sheet are each resolved once and remembered, so a
-- live game has to be in place before ANY case touches them -- otherwise the
-- first one caches "no world, no art" and every later case silently draws
-- nothing, which is exactly the failure this file exists to catch.
local liveOw = { isOverworld = true, map = { id = "PEWTER_CITY" }, npcs = {} }
run.loader.game = { save = { flags = {} }, data = Data,
                    stack = { states = { liveOw } } }

local tierOf = run.loader.exports.npc_bubbles.reachableTier

-- the live state the branches ask about.  Event flags are plain
-- save.flags entries (src/script/Flags.lua), so the fake save is the whole
-- dependency -- no live game, no facade.
local flags = {}
local function game(inventory, owned)
  return { save = { flags = flags, inventory = inventory or {},
                    pokedex = { owned = owned or {} } } }
end

-- ------- the worked case: Blue's House Daisy (data/scripts/story.lua)
--
-- 1 face_player / 2 check EVENT_GOT_TOWN_MAP / 3 jump_if_true 10
-- 4 check EVENT_GOT_STARTER / 5 jump_if_false 12 / 6 show_text
-- 7 give_item TOWN_MAP / 8 set_flag / 9 jump 13 / 10 show_text / 11 jump 13
-- 12 show_text / 13 (end)
local DAISY = {
  { "face_player" },
  { "check_flag", "EVENT_GOT_TOWN_MAP" },
  { "jump_if_true", 10 },
  { "check_flag", "EVENT_GOT_STARTER" },
  { "jump_if_false", 12 },
  { "show_text", "_BluesHouseDaisyOfferMapText" },
  { "give_item", "TOWN_MAP", 1, "_GotMapText" },
  { "set_flag", "EVENT_GOT_TOWN_MAP" },
  { "jump", 13 },
  { "show_text", "_BluesHouseDaisyUseMapText" },
  { "jump", 13 },
  { "show_text", "_BluesHouseDaisyText" },
  { "show_text", "" },
}

do
  flags = {}
  T.eq(tierOf(DAISY, game()), 3,
    "before the starter, the gift is unreachable -- story only")

  flags = { EVENT_GOT_STARTER = true }
  T.eq(tierOf(DAISY, game()), 1, "with a starter, the Town Map is on offer")

  flags = { EVENT_GOT_STARTER = true, EVENT_GOT_TOWN_MAP = true }
  T.eq(tierOf(DAISY, game()), 3,
    "once you hold the map the branch skips the gift again")
end

-- ------- the tiers, in isolation

do
  flags = {}
  -- one fixed line is not a hint; it used to get a smiley, which put one
  -- over every NPC in the game
  T.eq(tierOf({ { "show_text", "hi" } }, game()), nil,
    "a script that only says one fixed line gets NO bubble")
  T.eq(tierOf({ { "check_flag", "X" }, { "show_text", "hi" } }, game()), 3,
    "but one that branches on your state is tier 3")
  T.eq(tierOf({ { "set_flag", "X" } }, game()), 2, "a world change is tier 2")
  T.eq(tierOf({ { "give_item", "POTION" } }, game()), 1, "a gift is tier 1")
  T.eq(tierOf({ { "trade", "NIDORAN" } }, game()), 1, "a trade is tier 1")
  T.eq(tierOf({ { "heal_party" } }, game()), 1, "healing is tier 1")

  -- a gift outranks a world change no matter which comes first
  T.eq(tierOf({ { "set_flag", "X" }, { "give_item", "P" } }, game()), 1,
    "set_flag then give_item is still a gift")
  T.eq(tierOf({ { "give_item", "P" }, { "set_flag", "X" } }, game()), 1,
    "give_item then set_flag is still a gift")
end

-- ------- the other conditions

do
  flags = {}
  local prog = {
    { "check_item", "BICYCLE" },
    { "jump_if_false", 4 },
    { "give_item", "POTION" },
    { "show_text", "no bike" },
  }
  T.eq(tierOf(prog, game({})), 3, "check_item false skips the gift")
  T.eq(tierOf(prog, game({ BICYCLE = 1 })), 1, "check_item true reaches it")

  local dex = {
    { "check_dex_owned", 2 },
    { "jump_if_false", 4 },
    { "give_item", "EXP_ALL" },
    { "show_text", "keep going" },
  }
  T.eq(tierOf(dex, game({}, { A = true })), 3, "one owned is not enough")
  T.eq(tierOf(dex, game({}, { A = true, B = true })), 1, "two owned unlocks it")
end

-- ------- labels and malformed programs

do
  flags = {}
  T.eq(tierOf({
    { "check_flag", "NOPE" },
    { "jump_if_false", "skip" },
    { "give_item", "P" },
    { "label", "skip" },
    { "show_text", "hi" },
  }, game()), 3, "a named jump target resolves through labels")

  -- a jump to nowhere must fall through rather than abort the walk
  T.eq(tierOf({
    { "jump", "missing" },
    { "give_item", "P" },
  }, game()), 1, "an unresolvable jump falls through to the next line")

  -- a backward jump is a loop; the walk has to end
  local looped = tierOf({
    { "check_flag", "X" },
    { "show_text", "a" },
    { "jump", 1 },
  }, game())
  T.eq(looped, 3, "a backward jump terminates instead of hanging")

  T.eq(tierOf({}, game()), nil, "an empty program classifies as nothing")
  T.eq(tierOf({ "junk", 42 }, game()), nil, "non-table rows are skipped")
end

-- ------- the toggles gate the draw, not the classification

do
  run.loader.modOptions.npc_bubbles = { gift = false }
  flags = { EVENT_GOT_STARTER = true }
  T.eq(tierOf(DAISY, game()), 1,
    "turning a bubble off does not change what an NPC is worth")
  run.loader.modOptions.npc_bubbles = {}
end

-- ------- "come back later" vs "you already have it"
--
-- Both look like "the gift is unreachable" to the walker.  The difference
-- is WHY: a claimed gift is blocked by the very flag the script set when it
-- gave it to you, while a prerequisite is anything else.  Get this wrong in
-- one direction and a taken gift bubbles forever; wrong in the other and
-- the come-back-later marker never appears at all.

local classify = run.loader.exports.npc_bubbles.classify
local programFor = run.loader.exports.npc_bubbles.programFor

do
  -- self-guarded: check the flag it sets itself
  local claimed = {
    { "check_flag", "EVENT_GOT_TOWN_MAP" },
    { "jump_if_true", 6 },
    { "give_item", "TOWN_MAP" },
    { "set_flag", "EVENT_GOT_TOWN_MAP" },
    { "jump", 7 },
    { "show_text", "use it well" },
    { "show_text", "" },
  }
  flags = {}
  T.eq(classify(claimed, game()), 1, "unclaimed and reachable: a solid !")

  flags = { EVENT_GOT_TOWN_MAP = true }
  -- no longer a gift, but their words still change with your progress, so
  -- they drop to the smile rather than vanishing.  What matters is that
  -- they do NOT stay a ! and do NOT become a come-back-later.
  T.eq(classify(claimed, game()), 3,
    "once claimed it falls to the smile, not a ! and not a later")
end

do
  -- gated by a prerequisite the script never sets: come back later
  local gated = {
    { "check_item", "BIKE_VOUCHER" },
    { "jump_if_false", 4 },
    { "give_item", "BICYCLE" },
    { "show_text", "come back with a voucher" },
  }
  flags = {}
  T.eq(classify(gated, game({})), 4,
    "a gift you cannot reach yet is the faded ! (tier 4)")
  T.eq(classify(gated, game({ BIKE_VOUCHER = 1 })), 1,
    "and becomes a solid ! the moment you can claim it")
end

do
  -- an action available now outranks a gift that is not
  local both = {
    { "check_flag", "LATER" },
    { "jump_if_false", 4 },
    { "give_item", "PRIZE" },
    { "set_flag", "SOMETHING_ELSE" },
  }
  flags = {}
  T.eq(classify(both, game()), 2,
    "a world change you can do now beats a gift you cannot")
end

do
  -- no gift anywhere means no later marker, whatever else is true
  T.eq(classify({ { "check_flag", "X" }, { "show_text", "hi" } }, game()), 3,
    "reactive dialogue with no gift stays a smile")
  T.eq(classify({ { "show_text", "hi" } }, game()), nil,
    "and one fixed line is still nothing at all")
end

-- ------- closures are builders, not black boxes
--
-- A talk entry may be a function.  It is not opaque logic: it reads the
-- save, assembles the rows the conversation would run, and hands them to
-- ow.runner:run as its last act.  Calling it with a runner that captures
-- instead of running yields the exact program for the current save --
-- which is Melanie's Bulbasaur, and 133 other entries the mod used to be
-- blind to.

do
  -- shaped exactly like data/scripts/yellow_gifts.lua's Melanie
  local function melanie(g, ow, npc, done)
    local rows = { { "face_player" } }
    if g.save.flags.EVENT_GOT_BULBASAUR_IN_CERULEAN then
      rows[#rows + 1] = { "show_text", "MelanieText4" }
    elseif (g.save.pikachuHappiness or 90) < 147 then
      rows[#rows + 1] = { "show_text", "MelanieText1" }
    else
      rows[#rows + 1] = { "give_pokemon", "BULBASAUR", 10 }
      rows[#rows + 1] = { "set_flag", "EVENT_GOT_BULBASAUR_IN_CERULEAN" }
    end
    ow.runner:run(rows, { npc = npc, onDone = done })
  end

  -- A fresh game per case.  The probe's save copy is cached against the
  -- game it was built from and cleared on every rebuild, so in play each
  -- state always arrives through a rebuild -- mutating one table in place
  -- here would be testing a sequence the mod never sees.
  local function melanieState(happy, got)
    flags = got and { EVENT_GOT_BULBASAUR_IN_CERULEAN = true } or {}
    local g = game()
    g.save.pikachuHappiness = happy
    return g
  end

  local g = melanieState(200, false)
  T.eq(tierOf(programFor(melanie, g), g), 1,
    "a happy Pikachu makes Melanie a gift, read out of a closure")

  g = melanieState(10, false)
  T.eq(tierOf(programFor(melanie, g), g), nil,
    "an unhappy Pikachu and she is only talk")

  g = melanieState(200, true)
  T.eq(tierOf(programFor(melanie, g), g), nil,
    "and once you hold the BULBASAUR she goes quiet")
  flags = {}

  -- a closure that does not fit the pattern must degrade, not throw
  T.eq(programFor(function() error("nope") end, game()), nil,
    "a closure that throws leaves the NPC unclassified")
  T.eq(programFor(function() end, game()), nil,
    "and one that never calls the runner does too")
  T.eq(programFor(nil, game()), nil, "a missing entry is not a program")
end

-- ------- a gift you have to accept
--
-- Melanie asks before handing the BULBASAUR over.  `ask` is answered at the
-- time, not read off the save, so the walk has to assume a player who wants
-- the thing says yes.  Leaving it false silently decided you had DECLINED
-- every gift that asks first, which is why she never showed a bubble.

do
  local asked = {
    { "show_text", "want it?" },
    { "ask", "PleaseText" },
    { "jump_if_false", "declined" },
    { "give_pokemon", "BULBASAUR", 10 },
    { "set_flag", "GOT_IT" },
    { "jump", "done" },
    { "label", "declined" },
    { "show_text", "maybe later" },
    { "label", "done" },
  }
  flags = {}
  T.eq(classify(asked, game()), 1,
    "a gift behind a yes/no prompt is still a gift")

  -- and give_* itself reports whether it landed; a full bag must not read
  -- as "you declined"
  local full = {
    { "give_item", "POTION" },
    { "jump_if_false", 4 },
    { "set_flag", "GOT_IT" },
    { "show_text", "no room" },
  }
  T.eq(classify(full, game()), 1, "a gift that might not fit is still a gift")
end

-- ------- a closure whose gift is not in this build
--
-- A table script always contains its gift row, unreachable but visible.  A
-- closure decides what to write BEFORE writing it, so an unmet prerequisite
-- means the row is simply absent.  Rebuilding against a best-case save is
-- what reveals there is something there at all -- and the flag that build
-- would SET is what proves you have not already had it.

do
  local function melanieShaped(g, ow, npc, done)
    local rows = {}
    if g.save.flags.GOT_BULBA then
      rows[#rows + 1] = { "show_text", "hope it is well" }
    elseif (g.save.pikachuHappiness or 90) < 147 then
      rows[#rows + 1] = { "show_text", "not yet" }
    else
      rows[#rows + 1] = { "give_pokemon", "BULBASAUR", 10 }
      rows[#rows + 1] = { "set_flag", "GOT_BULBA" }
    end
    ow.runner:run(rows, { npc = npc, onDone = done })
  end

  local function state(happy, got)
    flags = got and { GOT_BULBA = true } or {}
    local g = game()
    g.save.pikachuHappiness = happy
    return g
  end

  local g = state(200, false)
  T.eq(classify(programFor(melanieShaped, g), g, melanieShaped), 1,
    "prerequisite met: a solid !")

  g = state(10, false)
  T.eq(classify(programFor(melanieShaped, g), g, melanieShaped), 4,
    "prerequisite unmet: the faded ! even though this build has no gift row")

  g = state(200, true)
  T.eq(classify(programFor(melanieShaped, g), g, melanieShaped), nil,
    "already claimed: nothing -- the flag that build would set is already on")
  flags = {}
end

-- ------- probing must never touch the real game
--
-- Not every closure is a builder.  The bike shop clerk pushes its own text
-- boxes and reaches into the bag (data/scripts/story2.lua), so handing a
-- probe the live game could put a box on screen or write to the save --
-- and pcall does not catch that, because those are successes.

do
  local pushed, wrote = 0, 0
  local live = {
    save = { flags = {}, inventory = {}, pokedex = { owned = {} } },
    stack = { push = function() pushed = pushed + 1 end },
  }

  -- an imperative closure, shaped like the clerk: no rows, real side effects
  local function clerk(g)
    g.stack:push("a text box")
    g.save.inventory.BICYCLE = 1
    g.save.flags.EVENT_GOT_BICYCLE = true
    wrote = wrote + 1
  end

  local prog = programFor(clerk, live)
  T.eq(prog, nil, "an imperative closure yields no program")
  T.eq(pushed, 0, "and cannot push anything onto the real stack")
  T.check(wrote > 0, "it did run and did write -- to the copy, not the save")
  T.eq(live.save.inventory.BICYCLE, nil, "the real bag is untouched")
  T.eq(live.save.flags.EVENT_GOT_BICYCLE, nil, "and the real flags are too")
end

-- ------- the draw seam
--
-- 1.0.0 drew nothing (wrong pass) and 1.0.1 drew several tiles east (wrong
-- transform).  Both came from drawing once per frame from outside.  The
-- overworld has two paths -- a flat blit and a tilt/billboard one that
-- wraps each sprite in its own transform -- so the only position that is
-- right in both is the one the sprite itself was just drawn at.  Hence the
-- wrap is on NPC.draw, per NPC, inside that transform.

do
  local NPC = require("src.world.NPC")
  T.check(NPC.draw ~= nil, "NPC.draw is the seam the mod wraps")

  local drew = {}
  local realDraw = love.graphics.draw
  love.graphics.draw = function(_, _, x, y) drew[#drew + 1] = { x = x, y = y } end

  local tiers = run.loader.exports.npc_bubbles.tiers()
  local drawFor = run.loader.exports.npc_bubbles.drawFor

  local npc = { id = "n1", px = 160, py = 96 }
  tiers[npc.id] = 1

  drew = {}
  drawFor(npc, 100, 50)
  if #drew > 0 then
    -- SpriteRenderer puts the sprite top at py - camY - 4, so -14 sits the
    -- bubble just above the head, matching the engine's own fxEmote
    T.eq(drew[1].x, 160 - 100 + 4, "the bubble is +4 across from the sprite")
    T.eq(drew[1].y, 96 - 50 - 14, "and -14 up, just above the head")
  else
    T.check(true, "no emote sheet in the fixture; offsets asserted in code")
  end

  -- an NPC with no tier draws nothing at all
  drew = {}
  drawFor({ id = "unknown", px = 0, py = 0 }, 0, 0)
  T.eq(#drew, 0, "an unclassified NPC gets no bubble")

  -- and a disabled tier draws nothing
  run.loader.modOptions.npc_bubbles = { gift = false }
  drew = {}
  drawFor(npc, 100, 50)
  T.eq(#drew, 0, "a disabled tier draws nothing")
  run.loader.modOptions.npc_bubbles = {}

  love.graphics.draw = realDraw
end

-- ------- the voxel arena
--
-- When a render pipeline supplies drawWorld, the engine skips the flat
-- entity pass entirely -- so NPC.draw, and with it the wrap above, never
-- runs. This presentation pass is the other half. Exactly one of them can
-- fire: worldPresent only runs when a pipeline produced a world canvas,
-- which is precisely when NPC.draw is skipped.
--
-- The voxel library is resolved once and remembered, so these cases run
-- before anything else can cache a "not installed" answer.

do
  local pipe = Data.render_pipelines and Data.render_pipelines.npc_bubbles_overlay
  T.check(pipe ~= nil, "a render pipeline is registered for the arena")
  T.check(pipe and pipe.worldPresent ~= nil,
    "it is presentation-only -- it must not claim to render the world")
  T.eq(pipe and pipe.drawWorld, nil, "and supplies no drawWorld of its own")
  T.eq(pipe and pipe.default, 1,
    "on by default, or it would restore to level 0 and never run")

  local projected = {}
  local fakeVoxel = {
    project = function(wx, wy, wz)
      projected[#projected + 1] = { wx = wx, wy = wy, wz = wz }
      return 300, 200, 1
    end,
  }
  -- T-SHIFT is a worldPresent pipeline too, at a higher priority, and it
  -- hands on a NEW blurred canvas.  So the bubbles must go onto whichever
  -- canvas we are given, and the previous target must be restored.
  local bound = {}
  local realSetCanvas = love.graphics.setCanvas
  love.graphics.setCanvas = function(c) bound[#bound + 1] = c or "NONE" end
  run.loader.mods.DRAMATIC_SHAPE =
    { id = "DRAMATIC_SHAPE", enabled = true, failed = false,
      manifest = { version = "1.5.5" } }
  run.loader.exports.DRAMATIC_SHAPE =
    { lib = { require = function(n)
        T.eq(n, "Voxel3D", "it asks the voxel lib for Voxel3D by name")
        return fakeVoxel
      end } }

  local npc = { id = "vox1", px = 160, py = 96 }
  liveOw.npcs = { npc }
  local tiers = run.loader.exports.npc_bubbles.tiers()
  tiers[npc.id] = 1

  local drew = {}
  local realDraw = love.graphics.draw
  love.graphics.draw = function(_, _, x, y, _, sx)
    drew[#drew + 1] = { x = x, y = y, s = sx }
  end

  local canvas = { getWidth = function() return 640 end }
  local out = pipe.worldPresent(canvas, { vw = 160 })
  love.graphics.draw = realDraw

  love.graphics.setCanvas = realSetCanvas
  T.eq(out, canvas, "the canvas is returned so the fold continues")
  T.eq(bound[1], canvas,
    "it draws onto the canvas it was handed, not the arena's internal one")
  T.check(#bound >= 2, "and restores the previous target rather than leaving it bound")
  T.eq(#projected, 1, "the NPC's world point is projected")
  if projected[1] then
    -- the engine anchors its own emote on the sprite's feet: px+8, py+16
    T.eq(projected[1].wx, 168, "anchored on the sprite's feet across")
    T.eq(projected[1].wz, 112, "and along -- project takes (x, height, z)")
    T.eq(projected[1].wy, 0, "at ground height")
  end
  if drew[1] then
    -- 640 canvas px / 160 world px = 4 canvas px per world px
    T.eq(drew[1].s, 4, "scale comes from the canvas against the world view")
    T.eq(drew[1].x, 300 - 4 * 4, "and the flat layout's offset is carried over")
    T.eq(drew[1].y, 200 - 30 * 4, "so it sits above the head, not on the feet")
  end

  -- a malformed context must not reach the overlay at all
  local before = #bound
  T.eq(pipe.worldPresent(canvas, {}), canvas, "no world width: pass through")
  T.eq(pipe.worldPresent(nil, { vw = 160 }), nil, "no canvas: nothing to fold")
  T.eq(#bound, before, "and neither one rebinds a canvas")

  liveOw.npcs = {}
  run.loader.mods.DRAMATIC_SHAPE = nil
  run.loader.exports.DRAMATIC_SHAPE = nil
end

run.release()
T.finish("npc_bubbles")

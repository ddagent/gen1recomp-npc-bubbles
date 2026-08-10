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
  -- Claimed, and the branch that skipped the gift is decided for good: the
  -- flag is true and nothing in the game clears it, so the line they say now
  -- is the last one they will ever say.  The smile means "worth another word
  -- later" and there is no later, so they fall silent rather than keeping it.
  T.eq(classify(claimed, game()), nil,
    "once claimed, and with nothing left that can change, no bubble at all")
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
  -- It builds no rows, so the first probe sees nothing -- but it DOES put a
  -- BICYCLE in the bag, and that is a gift.  The second probe watches the
  -- copied bag and hands back the give_item row the closure never wrote, so
  -- the same walker everything else uses can read it.
  T.check(type(prog) == "table", "an imperative gift is still found")
  T.eq(prog[1] and prog[1][1], "give_item", "as a give_item row")
  T.eq(prog[1] and prog[1][2], "BICYCLE", "naming what it actually handed over")

  T.eq(pushed, 0, "and cannot push anything onto the real stack")
  T.check(wrote > 0, "it did run and did write -- to the copy, not the save")
  T.eq(live.save.inventory.BICYCLE, nil, "the real bag is untouched")
  T.eq(live.save.flags.EVENT_GOT_BICYCLE, nil, "and the real flags are too")
end

do
  -- a closure that gives nothing must still yield nothing: the second probe
  -- is for finding gifts, not for turning every unreadable NPC into one
  local live = { save = { flags = {}, inventory = {}, pokedex = { owned = {} } },
                 stack = { push = function() end } }
  local chatty = function(g) g.stack:push("just talking") end
  T.eq(programFor(chatty, live), nil, "a closure that gives nothing yields nothing")
end

do
  -- ------- a gift that throws AFTER handing it over
  --
  -- Both Mt Moon fossils and the museum scientist do the same thing: put the
  -- item in the bag, then tidy the world up -- hide the exhibit, walk an NPC
  -- away.  That tidying needs a real map, so against a probe it throws.
  -- Checking whether the run succeeded threw away a gift that had already
  -- landed, and every one of those givers came out a smile.
  local live = { save = { flags = {}, inventory = {}, pokedex = { owned = {} } },
                 stack = { push = function() end } }
  local giveThenDie = function(g)
    g.save.inventory.BICYCLE = 1
    error("hide_object: attempt to index field 'map' (a nil value)")
  end
  local prog = programFor(giveThenDie, live)
  T.check(type(prog) == "table", "a gift is still found when the script throws after it")
  T.eq(prog[1] and prog[1][2], "BICYCLE", "naming what reached the bag before the throw")
  T.eq(live.save.inventory.BICYCLE, nil, "and the real bag is still untouched")

  -- rows already handed to the runner survive the same way
  local rowsThenDie = function(_, ow)
    ow.runner:run({ { "give_item", "POTION" } })
    error("boom")
  end
  local rows = programFor(rowsThenDie, live)
  T.eq(rows and rows[1] and rows[1][2], "POTION",
    "rows already given to the runner survive a later throw")
end

do
  -- ------- a gate that lives in the WORLD, not in the save
  --
  -- The fossil shape: a trainer stands between you and the gift, and the
  -- check reads the overworld rather than a flag.  The bare stub has no
  -- trainerDefeated at all, so the call threw and the gift behind it was
  -- never seen -- both fossils read as a smile.  The best-case probe now
  -- gets a world that answers, the same willing path an `ask` already takes.
  local live = { save = { flags = {}, inventory = {}, pokedex = { owned = {} } },
                 stack = { push = function() end } }
  local guarded = function(g, ow)
    if not ow:trainerDefeated(ow:npcByIndex(1)) then return end
    g.save.inventory.BICYCLE = 1
  end
  -- today: no world given, so the guard cannot be answered and nothing is found
  T.eq(programFor(guarded, live), nil, "with no world to ask, no gift is claimed")

  -- today, with the real world: the guard answers truthfully
  local beaten = false
  local realOw = { trainerDefeated = function() return beaten end,
                   npcByIndex = function(_, i) return { id = "n", def = { index = i } } end }
  T.eq(programFor(guarded, live, nil, realOw), nil,
    "the trainer still standing means no gift today")
  beaten = true
  local now = programFor(guarded, live, nil, realOw)
  T.eq(now and now[1] and now[1][2], "BICYCLE",
    "once he is beaten the gift is takeable now, not later")
end

do
  -- ------- the probe must not write into the world it is reading
  --
  -- npcByIndex has to hand back the REAL object -- trainerDefeated keys on
  -- its id -- so a script that turns an NPC to face it could turn one in the
  -- world.  It comes back shadowed: reads pass through, writes go nowhere.
  local live = { save = { flags = {}, inventory = {}, pokedex = { owned = {} } },
                 stack = { push = function() end } }
  local realNpc = { id = "guard", def = { index = 1 }, facing = "down" }
  local realOw = { trainerDefeated = function() return true end,
                   npcByIndex = function() return realNpc end }
  local rude = function(g, ow)
    local n = ow:npcByIndex(1)
    T.eq(n.facing, "down", "the shadow reads the real NPC through")
    n.facing = "right"                  -- must not reach the world
    g.save.inventory.BICYCLE = 1
  end
  programFor(rude, live, nil, realOw)
  T.eq(realNpc.facing, "down", "a probe cannot turn an NPC in the world")
end

do
  -- ------- the gift that only happens after the box is closed
  --
  -- The shape every hand-written giver uses: say a line, and hand the item
  -- over in the "when the player closes this" callback.  A probe that
  -- swallows the box never reaches the second half, which is why a free HM
  -- read exactly like a remark about the weather.
  local live = { save = { flags = {}, inventory = {}, pokedex = { owned = {} } },
                 stack = { push = function() end } }
  local deferred = function(g)
    local TextBox = require("src.render.TextBox")
    g.stack:push(TextBox.new(g, "here you go", function()
      require("src.inventory.Bag").add(g.save, "HM_FLY", 1)
    end))
  end
  local prog = programFor(deferred, live)
  T.check(type(prog) == "table", "a gift inside a callback is still found")
  T.eq(prog[1] and prog[1][2], "HM_FLY", "and named correctly")
  T.eq(live.save.inventory.HM_FLY, nil, "without touching the real bag")
end

do
  -- ------- a question is answered, not left hanging
  --
  -- Oak's aides open by asking whether you have caught enough.  A probe that
  -- only closes boxes never answers, so the branch holding the gift never
  -- runs.  YES is the same willing path the walker takes for an `ask` row.
  local live = { save = { flags = {}, inventory = {}, pokedex = { owned = {} } },
                 stack = { push = function() end } }
  local asks = function(g)
    local TextBox = require("src.render.TextBox")
    g.stack:push(TextBox.new(g, "caught enough?", nil, { choice = function(yes)
      if yes then require("src.inventory.Bag").add(g.save, "ITEMFINDER", 1) end
    end }))
  end
  local prog = programFor(asks, live)
  T.check(type(prog) == "table", "a gift behind a yes/no is found")
  T.eq(prog[1] and prog[1][2], "ITEMFINDER", "by answering yes")
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
  -- project() answers in the SUPERSAMPLED canvas's pixels, so x and y grow
  -- with the AA factor.  The third return is focusW/cw, a ratio off the
  -- camera matrix with no pixels in it, so it does NOT.
  local fakeDepth = 1
  -- A point `wy` above the ground lands `wy * fakeMag` further up the
  -- canvas, so fakeMag IS the magnification at this NPC's depth -- which is
  -- what the mod measures by projecting the feet and a point a tile above
  -- them.  A perspective camera makes that number grow as you approach.
  local fakeMag = 4
  local fakeVoxel = {
    project = function(wx, wy, wz)
      projected[#projected + 1] = { wx = wx, wy = wy, wz = wz }
      return 300, 200 - (wy or 0) * fakeMag, fakeDepth
    end,
  }
  local fakeAAFactor = 1
  local fakeAA = { factor = function() return fakeAAFactor end }
  -- engaged() is true only on the free-cam rungs, where the camera stands
  -- with the player and a sight line from the player is the camera's own
  local fakeEngaged = false
  local fakeFP = { engaged = function() return fakeEngaged end }
  -- the arena's per-tile height field: tile id -> how tall the world is
  -- there.  wall is 16, roof 28, a fence only 10.
  local tileHeights = {}
  local fakeTS = {
    forMap = function() return { fixture = true } end,
    at = function(_, _, tile) return { h = tileHeights[tile] or 0 } end,
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
        if n == "AntiAlias" then return fakeAA end
        if n == "FirstPerson" then return fakeFP end
        if n == "TileShape" then return fakeTS end
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
    -- Ground height, matching the engine: in the pipeline path
    -- OverworldController anchors an emote at (px+8, py+16) and projects
    -- THAT, sliding the flat offset on afterwards.  Projecting the head
    -- instead moves the anchor a tile or two under a tilted camera.
    T.eq(projected[1].wy, 0, "at ground height, like the engine's own emote")
  end
  if drew[1] then
    -- 640 canvas px / 160 world px = 4 canvas px per world px
    T.eq(drew[1].s, 4, "scale comes from the canvas against the world view")
    -- The flat path's +4 is from the sprite's LEFT edge; this projects
    -- px+8, the sprite's CENTRE, so the same place is 4 - 8 = -4.  Carrying
    -- the flat number across unchanged put every bubble half a tile right.
    -- Not chosen by eye.  drawFx.at translates by
    -- (sx/scale - (px+8-cam.x), sy/scale - (py+16-cam.y)) and fxEmote then
    -- draws at (px-cam.x+4, py-cam.y-14); the two cancel to
    -- (sx/scale - 4, sy/scale - 30) inside a scale(scale).
    T.eq(drew[1].x, 300 - 4 * 4, "the engine's own emote offset, across")
    T.eq(drew[1].y, 200 - 30 * 4, "and up")
  end

  -- ------- anti-aliasing moves the POSITION and nothing else
  --
  -- The pass renders into a canvas 2x or 4x the window and folds it back
  -- down, so project() answers in the big space while worldPresent draws on
  -- the resolved one.  Dividing x and y by the factor is the whole fix --
  -- and dividing the depth ratio by it as well, which is tempting because
  -- it arrives from the same call, silently halves every bubble at 2X.
  local function drawOnce()
    drew = {}
    local rd = love.graphics.draw
    love.graphics.draw = function(_, _, x, y, _, sx)
      drew[#drew + 1] = { x = x, y = y, s = sx }
    end
    love.graphics.setCanvas = function(c) bound[#bound + 1] = c or "NONE" end
    pipe.worldPresent(canvas, { vw = 160 })
    love.graphics.draw = rd
    return drew[1]
  end

  fakeAAFactor = 2
  local at2x = drawOnce()
  if at2x then
    T.eq(at2x.x, 300 / 2 - 4 * 4, "2X AA halves the projected position")
    T.eq(at2x.y, 200 / 2 - 30 * 4, "on both axes")
    T.eq(at2x.s, 4, "and the size is untouched -- only the anchor moved")
  end

  fakeAAFactor = 4
  local at4x = drawOnce()
  if at4x then
    T.eq(at4x.x, 300 / 4 - 4 * 4, "4X AA quarters the position")
    T.eq(at4x.s, 4, "and still does not touch the size")
  end

  -- ------- distance does NOT change the size
  --
  -- The engine says it of its own field FX: "Deliberately unscaled by
  -- depth, like :billboard: an effect keeps its crisp authored size and
  -- only its anchor moves."  A bubble that shrank with distance disagreed
  -- with the game's own emote bubble standing next to it, and in first
  -- person it shrank to nothing.
  fakeAAFactor = 1
  for _, d in ipairs({ 0.01, 1, 50, -1 }) do
    fakeDepth = d
    local row = drawOnce()
    if row then
      T.eq(row.s, 4, "depth " .. d .. " draws at the authored size")
    end
  end

  fakeAAFactor, fakeDepth = 1, 1

  -- ------- standing among them, the bubble keeps pace with the NPC
  --
  -- Orbiting above, every NPC is about the same distance away and one flat
  -- number is right.  On a free-cam rung an NPC a step away is many times
  -- the size of one across the room: a screen-sized bubble offset a
  -- screen-sized 30 pixels ends up by his feet, tiny.  So the size and the
  -- offsets come from the magnification measured AT that NPC -- project the
  -- feet, project a tile above them, and see how far apart they land.
  fakeEngaged = true

  fakeMag = 4                      -- same as the flat scale
  local matched = drawOnce()
  if matched then
    T.eq(matched.s, 4, "where depth is uniform it agrees with the flat scale")
    T.eq(matched.y, 200 - 30 * 4, "and so do the offsets")
  end

  fakeMag = 40                     -- an NPC a step in front of you
  local close = drawOnce()
  if close then
    T.eq(close.s, 40, "up close the bubble grows with the NPC")
    T.eq(close.x, 300 - 4 * 40, "the sideways offset grows with it")
    T.eq(close.y, 200 - 30 * 40, "and it stays above the head, not by the feet")
  end

  fakeMag = 1                      -- across the room
  local far = drawOnce()
  if far then T.eq(far.s, 1, "far away it shrinks with him") end

  -- a degenerate near-plane reading must not make it vanish or fill the
  -- screen; the flat scale is the anchor for both bounds
  fakeMag = 0
  local degenerate = drawOnce()
  if degenerate then T.eq(degenerate.s, 4, "a zero reading falls back to flat") end
  fakeMag = 10000
  local huge = drawOnce()
  if huge then T.eq(huge.s, 4 * 16, "a runaway reading is clamped") end

  -- first person AND anti-aliasing at once: the measurement is taken from
  -- two supersampled projections, so it carries the factor and has to be
  -- divided by it exactly like the position is
  fakeAAFactor, fakeMag = 2, 40
  local both = drawOnce()
  if both then
    T.eq(both.s, 20, "the measured scale is in resolved pixels, not big ones")
    T.eq(both.y, 200 / 2 - 30 * 20, "and the offset follows it")
  end
  fakeAAFactor = 1

  -- and the orbiting camera is left exactly as it was
  fakeEngaged, fakeMag = false, 40
  local orbit = drawOnce()
  if orbit then
    T.eq(orbit.s, 4, "orbiting, the flat scale is used however deep the NPC is")
    T.eq(orbit.y, 200 - 30 * 4, "with the engine's own flat offsets")
  end
  fakeMag = 4

  -- ------- a roof hides the bubble; a fence does not
  --
  -- The arena leaves NPCs to honest occlusion -- only the player gets a
  -- see-through silhouette -- so a bubble floating over a roof whose NPC is
  -- correctly hidden is wrong.  There is no depth buffer to consult from
  -- here, so the line from the eye to the NPC's head is walked against the
  -- arena's own per-tile height field.  Being a height field and not a
  -- boolean is the point: you see over a fence and not through a wall.
  do
    -- eye at x=0, z=0, 32 above the ground; NPC 12 tiles east at ground
    -- level, so the sight line sags from 32 down to his head at 16
    fakeVoxel.eye = { 0, 32, 0 }
    npc.px, npc.py = 96 - 8, 0 - 16   -- head lands at (96, 16, 0)
    liveOw.map = {
      tileAt = function(_, tx, ty) return tx .. "," .. ty end,
    }
    fakeEngaged = true

    -- off by default: it reads tile heights rather than the depth buffer, so
    -- it is an approximation, and one nobody asked for should be opt-in
    tileHeights = { ["6,0"] = 32 }
    run.loader.modOptions.npc_bubbles = {}
    T.check(drawOnce() ~= nil, "off by default, a roof hides nothing")
    run.loader.modOptions.npc_bubbles = { hide_walls = true }

    tileHeights = {}
    T.check(drawOnce() ~= nil, "open ground: the bubble shows")

    -- a wall 16 tall halfway along, where the line is about 24 up
    tileHeights["6,0"] = 16
    T.check(drawOnce() ~= nil, "a low wall the line clears does not hide it")

    -- a roof at 28 in the same place does reach the line
    tileHeights["6,0"] = 28
    T.check(drawOnce() == nil, "a roof standing in the way hides it")

    -- ...and the same roof means nothing on the orbiting camera, which
    -- looks over the town by design
    fakeEngaged = false
    T.check(drawOnce() ~= nil, "orbiting above, nothing is ever hidden")
    fakeEngaged = true

    -- the NPC's own tile is the end of the line, not an obstacle on it
    -- his head is at x=96, which is tile 12; the walk stops short of it
    tileHeights = { ["12,0"] = 32 }
    T.check(drawOnce() ~= nil, "the NPC's own tile does not hide him")

    -- fail open: no height field at all (another arena) means no hiding
    tileHeights = { ["6,0"] = 32 }
    local realTS = fakeTS.forMap
    fakeTS.forMap = function() error("no shapes here") end
    T.check(drawOnce() ~= nil, "a throwing height field fails open")
    fakeTS.forMap = realTS

    -- and a map that cannot answer at all
    liveOw.map = {}
    T.check(drawOnce() ~= nil, "a map with no tileAt fails open")

    liveOw.map, fakeVoxel.eye = nil, nil
    tileHeights = {}
    fakeEngaged = false
    npc.px, npc.py = 160, 96
    run.loader.modOptions.npc_bubbles = {}
  end

  -- a malformed context must not reach the overlay at all
  local before = #bound
  T.eq(pipe.worldPresent(canvas, {}), canvas, "no world width: pass through")
  T.eq(pipe.worldPresent(nil, { vw = 160 }), nil, "no canvas: nothing to fold")
  T.eq(#bound, before, "and neither one rebinds a canvas")

  liveOw.npcs = {}
  run.loader.mods.DRAMATIC_SHAPE = nil

  -- ------- the 3D pass is not a display mode, so it is not in OPTIONS
  --
  -- Drawing over an arena's world pass means registering a pipeline, and
  -- the options menu lists every pipeline unfiltered.  But switching this
  -- one off only makes bubbles vanish in 3D -- having the mod enabled is
  -- already the toggle -- so the row is dropped on its way to the menu.
  do
    local incoming = {
      { id = "tilt", label = "TILT" },
      { id = "pipeline:voxel", label = "VOXEL" },
      { id = "pipeline:npc_bubbles_overlay", label = "NPC BUBBLES 3D" },
      { id = "pipeline:tiltshift", label = "T-SHIFT" },
    }
    local out = Runtime.call("ui.options.rows",
      function(_, rows) return rows end, nil, incoming)
    T.check(type(out) == "table", "the hook hands back a row list")
    local ids = {}
    for _, row in ipairs(out) do ids[row.id] = true end
    T.check(not ids["pipeline:npc_bubbles_overlay"],
      "our own pipeline row is gone from START > OPTIONS")
    -- and nothing else is collateral: another mod's rows have to survive
    T.check(ids["tilt"] and ids["pipeline:voxel"] and ids["pipeline:tiltshift"],
      "every other row is left exactly where it was")

    -- the same hook adds our own row in its place
    T.check(ids["npc_bubbles_settings"], "and our own row is added in its place")
    T.eq(#out, #incoming, "one row out, one row in")
    local ours
    for _, row in ipairs(out) do
      if row.id == "npc_bubbles_settings" then ours = row end
    end
    T.check(type(ours.activate) == "function", "the row opens something")
    T.eq(ours.label, "NPC BUBBLES..",
      "and says so: the trailing dots are the game's own word for it")
    T.check(Data.screens and Data.screens.npc_bubbles_settings ~= nil,
      "and the screen it opens is registered")
    T.check(Data.screens and Data.screens.npc_bubbles_guide ~= nil,
      "with the guide still registered, opened from inside it")

    -- A mod's rows land at the END of this list by default, thirty rows
    -- past the top in a menu that shows four at a time. Being near the
    -- front is the whole point of the change; being FIRST is not claimed,
    -- since whichever mod's hook runs last takes that.
    T.eq(out[1] and out[1].id, "npc_bubbles_settings",
      "placed at the front rather than buried at the end")

    -- The count reads every map in the game, so nothing on the way TO the
    -- guide may ask for it. Reported on this row it would be paid for by
    -- anyone who opened OPTIONS for the sound volume.
    T.eq(ours.value, nil, "the row reports no count -- it only opens")
  end

  -- ------- the page that row opens
  do
    local loader = run.loader
    local game = loader.game
    -- what the engine hands a screen: the loader lives on game.mods, which
    -- is where both the declared schema and the live values are read from
    game.mods = loader
    game.save.options = game.save.options or {}
    local factory = Data.screens.npc_bubbles_settings
    local made, page = pcall(function()
      local f = type(factory) == "table" and factory.new or factory
      return f(game)
    end)
    T.check(made and page, "the settings page constructs (" .. tostring(page) .. ")")

    if made and page then
      local labels, byLabel = {}, {}
      for _, row in ipairs(page.rows) do
        labels[#labels + 1] = row.label
        byLabel[row.label] = row
      end
      T.eq(labels[1], "CHECKLIST..",
        "the checklist is first -- the one worth another look as you play")
      T.eq(labels[2], "GUIDE..", "then the guide, read once and remembered")

      -- The count reads every map in the game, so nothing on the way TO the
      -- guide is allowed to ask for it. On a row it would be paid for by
      -- anyone opening OPTIONS for the sound volume, and again on the way
      -- past this page -- twice over before anybody asked to see it.
      T.eq(page.rows[1].value, nil, "the checklist row reports nothing")
      T.eq(page.rows[2].value, nil, "and neither does the guide row")

      -- Built from the declaration rather than a second list written out
      -- here: an option added at the top of the mod appears on this page
      -- without anybody remembering to add it twice.
      local schema = loader.optionSchemas and loader.optionSchemas.npc_bubbles
      if type(schema) == "table" then
        T.eq(#page.rows, #schema + 2,
          "one row per declared option, plus the checklist and the guide")
        for _, entry in ipairs(schema) do
          T.check(byLabel[entry.label] ~= nil,
            "'" .. tostring(entry.label) .. "' is on the page")
        end
      end
      for _, l in ipairs(labels) do
        T.check(#l <= 17, "'" .. l .. "' fits the label line")
      end
      -- it is the engine's own row renderer, so this is mostly a check that
      -- every row hands it what it asks for: a label and a value function
      -- Gen1 Modern UI adopts a screen built on the engine's OptionRows
      -- helper if it carries a screen id alongside the rows, cursor, update
      -- and draw. Everything but the id was already here.
      T.eq(type(page.screenId), "string", "the page names itself")
      T.check(page.screenId:match("Settings$") or page.screenId:match("Options$"),
        "with an id another mod's presenter will recognise: " .. page.screenId)
      T.check(type(page.rows) == "table" and type(page.index) == "number"
        and type(page.update) == "function" and type(page.draw) == "function",
        "and the rest of the shape it looks for")

      T.check(pcall(page.draw, page), "the page draws")
      page.index = #page.rows + 1          -- BACK, one past the last row
      T.check(pcall(page.draw, page), "and draws with BACK selected")

      -- The promise of having it in two places: changing it HERE has to
      -- land where mod.options:get reads it and where the file is written
      -- from, or this page and the mod manager's page would each answer
      -- with their own value and the player would be told two things.
      local heard = byLabel["CLEAR AFTER TALK"]
      T.check(heard ~= nil, "the smile-clearing toggle is on the page")
      if heard then
        T.eq(heard.value(), "OFF", "off to begin with, as declared")
        heard.step(game, 1)
        T.eq(heard.value(), "ON", "and the row shows the change")
        T.eq(loader.modOptions and loader.modOptions.npc_bubbles
             and loader.modOptions.npc_bubbles.heard, true,
          "it reached the copy mod.options:get reads")
        T.eq(game.save.options.modOptions
             and game.save.options.modOptions.npc_bubbles
             and game.save.options.modOptions.npc_bubbles.heard, true,
          "and the copy the save is written from")
        heard.step(game, 1)
        T.eq(heard.value(), "OFF", "and it goes back")
      end

      -- A dial wraps rather than sticking at its end
      local fade = byLabel["LATER FADE"]
      if fade then
        for _ = 1, 40 do fade.step(game, 1) end
        local n = tonumber(fade.value())
        T.check(n ~= nil and n >= 20 and n <= 100,
          "the fade dial stays inside its bounds (" .. fade.value() .. ")")
      end
    end
    run.loader.modOptions.npc_bubbles = {}
    game.save.options.modOptions = nil
  end

  -- ------- the toggles name the symbol they switch
  --
  -- No legend row: a row stepping through four sentences to say what a
  -- picture says at a glance competed with the guide rather than helping.
  do
    local schema = run.loader.optionSchemas
      and run.loader.optionSchemas.npc_bubbles
    if type(schema) == "table" then
      local labels = {}
      for _, row in ipairs(schema) do
        labels[row.key] = row.label
        T.check(row.key ~= "legend", "the text legend is gone")
      end
      T.eq(labels.gift, "! BUBBLE", "the gift toggle names its symbol")
      T.eq(labels.later, "FADED ! BUBBLE", "and so does the faded one")
      T.eq(labels.event, "? BUBBLE", "and the question one")
      T.eq(labels.story, "SMILE BUBBLE", "and the smile")
      for _, row in ipairs(schema) do
        T.check(#tostring(row.label) <= 17,
          "'" .. tostring(row.label) .. "' fits the label line")
      end
    else
      T.check(true, "option schema not exposed by the loader in this build")
    end
  end

  -- ------- the guide draws every bubble it explains
  do
    local Screens2 = require("src.ui.Screens")
    Screens2.invalidate()
    local factory = Data.screens.npc_bubbles_guide
    local made, inst = pcall(function()
      local f = type(factory) == "table" and factory.new or factory
      return f(run.loader.game)
    end)
    T.check(made and inst, "the guide screen constructs (" .. tostring(inst) .. ")")
    if made and inst then
      local drew = {}
      local realDraw = love.graphics.draw
      love.graphics.draw = function(_, q) drew[#drew + 1] = q end
      local ok, err = pcall(inst.draw, inst)
      love.graphics.draw = realDraw
      T.check(ok, "and draws: " .. tostring(err))
      T.check(#drew > 0, "with the real crops, not words for them")

      -- Wrapped, so nothing runs through the right border: the box's inside
      -- edge is x=152 and the text starts at x=40, which is 14 characters.
      for _, entry in ipairs(inst.entries) do
        for _, line in ipairs(entry.lines) do
          T.check(#line <= 14,
            "'" .. line .. "' fits inside the border")
        end
      end

      -- and wrapping means it no longer fits on one screen, so it scrolls
      T.check(inst:maxScroll() > 0, "there is more than one screenful")
      local first = #drew
      inst.scroll = inst:maxScroll()
      drew = {}
      love.graphics.draw = function(_, q) drew[#drew + 1] = q end
      pcall(inst.draw, inst)
      love.graphics.draw = realDraw
      T.check(#drew > 0, "the bottom of the list draws once scrolled to")

      -- scrolling is clamped at both ends
      inst.scroll = 0
      inst.game = { input = { wasPressed = function(_, b) return b == "up" end },
                    stack = { pop = function() end } }
      inst:update()
      T.eq(inst.scroll, 0, "UP at the top does not scroll past it")
      inst.scroll = inst:maxScroll()
      inst.game.input.wasPressed = function(_, b) return b == "down" end
      inst:update()
      T.eq(inst.scroll, inst:maxScroll(), "and DOWN at the end stays put")

      -- The screen has to answer with its OWN palette.  Game.lua walks down
      -- the stack for the first screen that does, so a screen with none
      -- wears whatever was underneath it -- which is how the faded ! came
      -- out in the overworld's purple.
      T.check(type(inst.sgbPalettes) == "function",
        "the guide names its own palette rather than inheriting one")

      -- and the faded bubble is exempted from the recolour, because a
      -- part-alpha blend falls between the four DMG shades and the palette
      -- pass has to round it to one of them
      local marked = 0
      local PaletteFX = require("src.render.PaletteFX")
      local realMark = PaletteFX.markTrueColor
      PaletteFX.markTrueColor = function() marked = marked + 1 end
      inst.scroll = 0
      pcall(inst.draw, inst)
      PaletteFX.markTrueColor = realMark
      T.check(marked > 0, "every bubble drawn is exempted from the recolour")

      -- and it can be closed
      local popped = false
      inst.game = { input = { wasPressed = function(_, b) return b == "b" end },
                    stack = { pop = function() popped = true end } }
      inst:update()
      T.check(popped, "B closes it")
    end
  end

  -- ------- the arena is found by what it OWNS, not by its name
  --
  -- The merge records which mod registered each pipeline under _owners, so a
  -- fork or a rename is still found.  Hardcoding one name meant the mod only
  -- ever worked with one arena, spelled exactly one way.
  local ownerOf = run.loader.exports.npc_bubbles.voxelOwner
  T.check(type(ownerOf) == "function", "the owner lookup is testable")

  T.eq(ownerOf({ render_pipelines = { _owners = { voxel = "SOME_FORK" } } }),
    "SOME_FORK", "whoever owns the voxel pipeline is the arena")
  T.eq(ownerOf({ render_pipelines = { _owners = { tiltshift = "X" } } }),
    "DRAMATIC_SHAPE", "no voxel owner recorded: fall back to the original")
  T.eq(ownerOf({ render_pipelines = {} }), "DRAMATIC_SHAPE",
    "a registry with no provenance falls back too")
  T.eq(ownerOf({}), "DRAMATIC_SHAPE", "and so does one with no pipelines")
  T.eq(ownerOf({ render_pipelines = { _owners = { voxel = "" } } }),
    "DRAMATIC_SHAPE", "an empty owner is not a mod id")
  run.loader.exports.DRAMATIC_SHAPE = nil
end

-- ------- all three battle verbs are world changes
--
-- static_battle and rival_battle always were; start_battle was the odd one
-- out, which left Oak's post-game rematch and the Fan Club chief resting on
-- their set_flag alone to be worth anything.
do
  flags = {}
  T.eq(tierOf({ { "static_battle", "VOLTORB" } }, game()), 2,
    "a static battle is a world change")
  T.eq(tierOf({ { "rival_battle", "OPP_RIVAL1" } }, game()), 2,
    "so is a rival battle")
  T.eq(tierOf({ { "start_battle", "OPP_PROF_OAK" } }, game()), 2,
    "and so is a plain trainer battle")

  -- Oak's shape: the rematch is behind the champion flag, so before the
  -- post-game he is not worth crossing the map for and after it he is
  local oak = {
    { "check_flag", "EVENT_BEAT_CHAMPION_RIVAL" },
    { "jump_if_false", 6 },
    { "check_flag", "EVENT_BEAT_PROF_OAK" },
    { "jump_if_true", 6 },
    { "start_battle", "OPP_PROF_OAK" },
    { "show_text", "hey, wait" },
  }
  T.eq(tierOf(oak, game()), 3, "before the champion, Oak is only talking")
  flags = { EVENT_BEAT_CHAMPION_RIVAL = true }
  T.eq(tierOf(oak, game()), 2, "post-game the rematch is reachable: a ?")
  flags = { EVENT_BEAT_CHAMPION_RIVAL = true, EVENT_BEAT_PROF_OAK = true }
  T.eq(tierOf(oak, game()), 3, "once beaten he drops back to talking")
  flags = {}
end

-- ------- a POKeMON is a gift, and the probe must not keep it
--
-- give_pokemon calls Party.add(save.party, mon), which inserts into
-- whatever list it is handed.  The shadow save read save.party straight
-- through to the player's own, so probing a seller put a MAGIKARP in the
-- real party and probing the day care raised a real member's level.
do
  local realParty = { { species = "PIKACHU", level = 5 } }
  local live = { save = { flags = {}, inventory = {}, party = realParty,
                          pokedex = { owned = {} } },
                 stack = { push = function() end } }
  local seller = function(g)
    table.insert(g.save.party, { species = "MAGIKARP", level = 5 })
    g.save.party[1].level = 99          -- the day care edits an existing mon
  end
  local prog = programFor(seller, live)
  T.eq(prog and prog[1] and prog[1][1], "give_pokemon",
    "a POKeMON handed over is found, though it never touches the bag")
  T.eq(prog and prog[1] and prog[1][2], "MAGIKARP", "naming which one")
  T.eq(#realParty, 1, "and the real party did not grow")
  T.eq(realParty[1].level, 5, "nor was a real POKeMON edited")
end

-- ------- menus get answered, and a shop is a shop when you are broke
do
  local live = { save = { flags = {}, inventory = {}, party = {}, money = 0,
                          pokedex = { owned = {} } },
                 stack = { push = function() end } }
  -- the vending machine's shape: a priced list, and the purchase lives in
  -- the callback the list never got to run
  local machine = function(g)
    local ListMenu = require("src.ui.ListMenu")
    g.stack:push(ListMenu.new(g, "VENDING MACHINE", {
      { label = "FRESH WATER", value = { id = "FRESH_WATER", price = 200 } },
      { label = "NO THANKS" },
    }, { onChoose = function(item)
      if g.save.money < item.value.price then return end
      g.save.money = g.save.money - item.value.price
      g.save.inventory[item.value.id] = 1
    end }))
  end
  local prog = programFor(machine, live)
  T.eq(prog and prog[1] and prog[1][2], "FRESH_WATER",
    "a list menu is answered, so the purchase behind it is found")
  T.eq(live.save.money, 0, "with the real wallet untouched")

  -- the trailing "NO THANKS" carries no value and must not be picked
  local onlyExit = function(g)
    local ListMenu = require("src.ui.ListMenu")
    g.stack:push(ListMenu.new(g, "MENU", { { label = "NO THANKS" } },
      { onChoose = function() g.save.inventory.NOPE = 1 end }))
  end
  T.eq(programFor(onlyExit, live), nil, "a menu with no real row picks nothing")
end

-- ------- a leader's badge and TM are not in their script at all
--
-- Sight engagement skips anyone carrying a talk script, and every leader has
-- one, so nothing announces them -- and the rewards are paid from the
-- victories table, so no row can be read to find them either.
do
  local MapScripts = require("src.script.MapScripts")
  MapScripts.attachBase("PEWTER_CITY",
    { talk = { LEADER = { { "show_text", "post-battle advice" } } } })
  MapScripts.invalidate("PEWTER_CITY")

  -- an earlier case parks liveOw.map at nil to prove the draw survives it
  liveOw.map = { id = "PEWTER_CITY" }
  local save = run.loader.game.save
  save.inventory = save.inventory or {}
  save.pokedex = save.pokedex or { owned = {}, seen = {} }
  save.flags = {}
  liveOw.npcs = { { id = "brock", px = 0, py = 0, cellX = 0, cellY = 0,
                    def = { text = "LEADER", name = "PEWTERGYM_BROCK",
                            index = 1, trainerClass = "OPP_BROCK",
                            trainerParty = 1 } } }
  local function tierNow()
    run.loader.events:emit("map.entered", { map = "PEWTER_CITY" })
    return run.loader.exports.npc_bubbles.tiers().brock
  end
  T.eq(tierNow(), 1, "a leader still owing a badge is a !")

  save.flags.EVENT_BEAT_BROCK = true
  T.eq(tierNow(), 1, "beaten but the TM not handed over is still a !")

  save.flags.EVENT_GOT_TM34 = true
  T.eq(tierNow(), nil, "badge and TM both collected: nothing left to say")

  -- someone with a trainer header but no rewards of their own
  liveOw.npcs[1].def.trainerClass = "OPP_LANCE"
  save.flags = {}
  T.eq(tierNow(), nil, "a trainer whose victory pays nothing stays quiet")

  liveOw.npcs = {}
  save.flags = {}
end

-- ------- nothing a probe does may reach the real save, at any depth
--
-- Not a list of fields I remembered to shadow -- that list is exactly what
-- went wrong.  hide_object writes save.objectToggles[map][name], mark_seen
-- writes save.pokedex.seen[species], a hidden item writes save.hiddenTaken,
-- and none of those were named anywhere.  The barrier is that every probe
-- reads from the rebuild's deep copy, so a write at any depth lands there.
-- This serialises the whole save before and after and compares.
do
  local function dump(v, out, seen)
    if type(v) ~= "table" then out[#out+1] = type(v) .. ":" .. tostring(v) return end
    if seen[v] then out[#out+1] = "<cycle>" return end
    seen[v] = true
    local keys = {}
    for k in pairs(v) do keys[#keys+1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    out[#out+1] = "{"
    for _, k in ipairs(keys) do
      out[#out+1] = tostring(k) .. "="
      dump(v[k], out, seen)
      out[#out+1] = ","
    end
    out[#out+1] = "}"
    seen[v] = nil
  end
  local function snapshot(v) local o = {}; dump(v, o, {}); return table.concat(o) end

  local realSave = {
    player = { name = "ASH" }, money = 4893, coins = 250,
    flags = { EVENT_GOT_STARTER = true },
    inventory = { POTION = 5, COIN_CASE = 1 },
    party = { { species = "PIKACHU", level = 12, moves = { "THUNDERSHOCK" } } },
    boxes = { { { species = "RATTATA", level = 3 } }, {} },
    pokedex = { seen = { PIKACHU = true }, owned = { PIKACHU = true } },
    objectToggles = { VIRIDIAN_CITY = { OLD_MAN = false } },
    hiddenTaken = { ["ROUTE_1_5_5"] = true },
    daycare = { species = "PIKACHU", level = 12 },
    safari = { steps = 300, balls = 20 },
  }
  local before = snapshot(realSave)
  local live = { save = realSave, stack = { push = function() end } }

  -- everything a real script has been seen to do, all at once
  local hostile = function(g)
    local s = g.save
    s.money = 0
    s.coins = 0
    s.inventory.POTION = 99
    s.inventory.MASTER_BALL = 99
    s.flags.EVENT_GOT_STARTER = false
    s.flags.EVENT_BEAT_LANCE = true
    s.pokedex.seen.MEWTWO = true                      -- mark_seen
    s.pokedex.owned.MEWTWO = true
    s.objectToggles.VIRIDIAN_CITY.OLD_MAN = true      -- hide_object, depth 2
    s.objectToggles.NEW_MAP = { THING = false }
    s.hiddenTaken["ROUTE_2_1_1"] = true
    s.daycare.level = 99                              -- depth 2 on a record
    s.safari.balls = 0
    s.party[1].level = 99                             -- a real POKeMON
    table.insert(s.party, { species = "MAGIKARP", level = 5 })
    table.insert(s.boxes[1], { species = "ZUBAT", level = 9 })
    s.boxes[2][1] = { species = "ODDISH", level = 4 }
    s.player.name = "HACKED"
  end

  programFor(hostile, live)
  T.eq(snapshot(realSave), before,
    "a probe cannot write into the real save, at any depth")

  -- and the same closure through the best-case probe, which is built from
  -- metatables rather than a copy
  local classify2 = classify
  local prog = programFor(hostile, live)
  if prog then classify2(prog, live, hostile) end
  T.eq(snapshot(realSave), before, "nor through the best-case probe")
end

-- ------- a gift that writes its own flag still clears the bubble
--
-- flag.changed comes from Flags.set, and the shared gift() helper assigns
-- game.save.flags[...] straight out, so nothing tells the mod anything
-- happened.  The ROUTE 1 POTION man kept his ! after handing it over until
-- the map changed.  The A press is remembered and settled once the world
-- has the player back.
do
  liveOw.map = { id = "PEWTER_CITY" }
  local MapScripts = require("src.script.MapScripts")
  local save = run.loader.game.save
  save.flags = {}
  save.inventory = save.inventory or {}
  save.pokedex = save.pokedex or { owned = {}, seen = {} }

  MapScripts.attachBase("PEWTER_CITY", { talk = { SNEAK = {
    { "check_flag", "EVENT_GOT_IT" },
    { "jump_if_true", 6 },
    { "give_item", "POTION" },
    { "set_flag", "EVENT_GOT_IT" },
    { "jump", "end" },
    { "show_text", "generic chat" },
  } } })
  MapScripts.invalidate("PEWTER_CITY")

  liveOw.npcs = { { id = "man", px = 0, py = 0, cellX = 0, cellY = 0,
                    def = { text = "SNEAK", name = "MAN", index = 1 } } }
  liveOw.player = { inputLocked = false }
  liveOw.runner = { isRunning = function() return false end }
  run.loader.game.stack = run.loader.game.stack or {}
  run.loader.game.stack.top = function() return liveOw end

  run.loader.events:emit("map.entered", { map = "PEWTER_CITY" })
  T.eq(run.loader.exports.npc_bubbles.tiers().man, 1, "unclaimed: a !")

  -- the conversation happens: the flag is written WITHOUT Flags.set, so no
  -- flag.changed is emitted -- exactly what gift() does
  save.flags.EVENT_GOT_IT = true
  T.eq(run.loader.exports.npc_bubbles.tiers().man, 1,
    "nothing has told the mod yet, so the stale ! is still there")

  -- the A press is what tells it, once the world is idle again
  run.loader.events:emit("world.interacted",
    { mapId = "PEWTER_CITY", kind = "npc" })
  run.loader.exports.npc_bubbles.drawFor(liveOw.npcs[1], 0, 0)
  T.eq(run.loader.exports.npc_bubbles.tiers().man, nil,
    "after the talk settles the bubble clears, without leaving the map")

  -- and it must NOT settle while the conversation is still up
  save.flags.EVENT_GOT_IT = nil
  run.loader.events:emit("map.entered", { map = "PEWTER_CITY" })
  T.eq(run.loader.exports.npc_bubbles.tiers().man, 1, "a ! again")
  local box = { isBox = true }
  run.loader.game.stack.top = function() return box end
  run.loader.events:emit("world.interacted",
    { mapId = "PEWTER_CITY", kind = "npc" })
  save.flags.EVENT_GOT_IT = true
  run.loader.exports.npc_bubbles.drawFor(liveOw.npcs[1], 0, 0)
  T.eq(run.loader.exports.npc_bubbles.tiers().man, 1,
    "with a box still open it waits rather than rebuilding mid-conversation")
  run.loader.game.stack.top = function() return liveOw end
  run.loader.exports.npc_bubbles.drawFor(liveOw.npcs[1], 0, 0)
  T.eq(run.loader.exports.npc_bubbles.tiers().man, nil,
    "and settles as soon as the box is gone")

  liveOw.npcs = {}
  save.flags = {}
end

-- ------- three gifts that never went out
do
  flags = {}

  -- A shop is not a gift.  open_mart never stops being true, so the one
  -- clerk who opens one wore a ! for the rest of the save.
  T.eq(tierOf({ { "check_flag", "X" }, { "open_mart", "SHOP" } }, game()), 3,
    "opening a shop is not receiving something")
  T.eq(tierOf({ { "heal_party" } }, game()), 1,
    "but healing still is -- it is given, not sold")

  -- A trade names the flag it sets as its own third argument, and nothing
  -- was reading it.
  local swap = { { "trade", 1, "EVENT_TRADED_IT" } }
  T.eq(tierOf(swap, game()), 1, "an unfinished trade is a !")
  flags.EVENT_TRADED_IT = true
  T.eq(tierOf(swap, game()), nil, "a finished one is not")
  flags = {}

  -- A battle's outcome is decided at the time, like an `ask`.  The row
  -- after it asks "did you LOSE?", and answering that with a stale flag
  -- reading walked the losing path and never saw the reward.
  local thief = {
    { "check_flag", "EVENT_BEAT_HIM" },
    { "jump_if_true", 6 },
    { "start_battle", "trainer", "OPP_ROCKET", 5 },
    { "jump_if_false", "end" },
    { "give_item", "TM_DIG" },
    { "show_text", "already done" },
  }
  T.eq(tierOf(thief, game()), 1,
    "the walk assumes you win, so the TM behind the battle is found")

  -- a static battle is still a world change, not a person to fight
  T.eq(tierOf({ { "static_battle", "VOLTORB" } }, game()), 2,
    "a static battle stays a world change")
end

-- ------- a smile you have already heard, and what brings it back
--
-- Off by default, so every case above ran with this switched off -- which is
-- how two bugs in it survived a full suite: `alreadyHeard` and `saidNow` were
-- both called before they were defined, and the second sat inside a pcall so
-- it failed silently and simply did nothing.  Nothing here is reachable
-- unless the toggle is on.
do
  local MapScripts = require("src.script.MapScripts")
  MapScripts.attachBase("PEWTER_CITY", { talk = {
    -- says one thing while you are carrying the ITEM and another when you are
    -- not.  An item check never settles -- you can use or toss one -- so the
    -- settled rule cannot silence him and this rule is visible on its own.
    CHATTY = {
      { "check_item", "BICYCLE" },
      { "jump_if_false", 5 },
      { "show_text", "_WithTheBike" },
      { "jump", "end" },
      { "show_text", "_WithoutTheBike" },
    },
  } })
  MapScripts.invalidate("PEWTER_CITY")

  liveOw.map = { id = "PEWTER_CITY" }
  liveOw.player = { inputLocked = false }
  liveOw.runner = { isRunning = function() return false end }
  local save = run.loader.game.save
  save.flags, save.inventory = {}, {}
  save.pokedex = save.pokedex or { owned = {}, seen = {} }
  run.loader.game.stack = run.loader.game.stack or {}
  run.loader.game.stack.top = function() return liveOw end

  local man = { id = "man", px = 0, py = 0, cellX = 0, cellY = 0,
                def = { text = "CHATTY", name = "MAN", index = 1 } }
  liveOw.npcs = { man }

  local function tierNow()
    run.loader.events:emit("map.entered", { map = "PEWTER_CITY" })
    return run.loader.exports.npc_bubbles.tiers().man
  end
  local function talkTo()
    run.loader.events:emit("world.interacted",
      { mapId = "PEWTER_CITY", kind = "npc", target = man })
    run.loader.exports.npc_bubbles.drawFor(man, 0, 0)
  end

  -- with the toggle OFF, talking changes nothing
  run.loader.modOptions.npc_bubbles = { heard = false }
  T.eq(tierNow(), 3, "a reactive NPC is a smile")
  talkTo()
  T.eq(tierNow(), 3, "and stays one while the toggle is off")

  -- but the conversation was still recorded, so switching it on does not
  -- make you re-visit everybody you have already spoken to
  run.loader.modOptions.npc_bubbles = { heard = true }
  T.eq(tierNow(), nil, "switching it on clears a smile already heard")

  -- their line changes: the smile comes back
  save.inventory.BICYCLE = 1
  T.eq(tierNow(), 3, "when they start saying something new it returns")
  talkTo()
  T.eq(tierNow(), nil, "and clears again once that is heard too")

  -- and turning it off restores everything, rather than only stopping new
  -- clearing -- nothing is lost by changing your mind
  run.loader.modOptions.npc_bubbles = { heard = false }
  T.eq(tierNow(), 3, "turning it off brings every cleared smile back")

  -- a gift is never hidden by it, however often you talk
  run.loader.modOptions.npc_bubbles = { heard = true }
  MapScripts.attachBase("PEWTER_CITY", { talk = {
    GIVER = { { "give_item", "POTION" } },
  } })
  MapScripts.invalidate("PEWTER_CITY")
  local giver = { id = "giver", px = 0, py = 0, cellX = 0, cellY = 0,
                  def = { text = "GIVER", name = "GIVER", index = 2 } }
  liveOw.npcs = { giver }
  run.loader.events:emit("map.entered", { map = "PEWTER_CITY" })
  T.eq(run.loader.exports.npc_bubbles.tiers().giver, 1, "a gift is a !")
  run.loader.events:emit("world.interacted",
    { mapId = "PEWTER_CITY", kind = "npc", target = giver })
  run.loader.exports.npc_bubbles.drawFor(giver, 0, 0)
  run.loader.events:emit("map.entered", { map = "PEWTER_CITY" })
  T.eq(run.loader.exports.npc_bubbles.tiers().giver, 1,
    "and talking to them does not hide it -- only smiles are cleared")

  run.loader.modOptions.npc_bubbles = {}
  liveOw.npcs = {}
  save.flags, save.inventory = {}, {}
end

-- ------- how much is left
--
-- Every case here is a bug this actually had.  The count reads every map in
-- the game against two different saves, and each of the mistakes below
-- produced a plausible number rather than an error -- which is exactly why
-- a plausible number is not evidence.
do
  local MapScripts = require("src.script.MapScripts")
  local E = run.loader.exports.npc_bubbles
  local save = run.loader.game.save
  save.inventory = {}
  save.pokedex = { owned = {}, seen = {} }
  save.flags = {}
  save.player = { name = "ASH" }
  save.party = { { species = "PIKACHU", level = 5 } }
  save.objectToggles = {}
  save.itemsTaken = {}
  save.defeatedTrainers = {}

  -- The baseline is the denominator: a save with the progress taken out.
  -- It has to blank what you have DONE while keeping what you ARE, because
  -- the sandbox deep-copies a save with pairs() -- anything reached through
  -- a metatable arrives inside the probe missing, and a script that reads a
  -- name off the nil dies before it can say what it would have given you.
  do
    local baseline = E.freshBaseline(run.loader.game)
    T.eq(next(baseline.save.flags), nil, "the baseline clears the flags")
    T.eq(next(baseline.save.pokedex.owned), nil, "and the pokedex")
    T.eq(rawget(baseline.save, "player") ~= nil, true,
      "but keeps the player as its OWN key, not through a metatable")
    T.eq(rawget(baseline.save, "party") ~= nil, true,
      "and the party, for the same reason")
    T.eq(baseline.save.player.name, "ASH", "with the real values intact")
    save.flags.EVENT_SOMETHING = true
    T.eq(E.freshBaseline(run.loader.game).save.flags.EVENT_SOMETHING, nil,
      "a flag set in the real save never reaches the baseline")
    T.eq(save.flags.EVENT_SOMETHING, true, "and blanking it left yours alone")
    save.flags = {}
  end

  -- one small world, built by hand: a giver, a flavour NPC and a smile
  local GIVER = { { "check_flag", "EVENT_TOOK_IT" },
                  { "jump_if_true", 6 },
                  { "give_item", "POTION" },
                  { "set_flag", "EVENT_TOOK_IT" },
                  { "jump", "end" },
                  { "show_text", "nothing more" } }
  MapScripts.attachBase("VIRIDIAN_CITY", { talk = {
    GIVER   = GIVER,
    FLAVOUR = { { "show_text", "I like ledges" } },
    MOODY   = { { "check_flag", "EVENT_ELSEWHERE" },
                { "jump_if_true", 4 },
                { "show_text", "before" },
                { "jump", "end" },
                { "show_text", "after" } },
  } })
  MapScripts.invalidate("VIRIDIAN_CITY")

  local function obj(name, text, extra)
    local o = { name = name, text = text, index = 1, x = 1, y = 1 }
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
  end
  local function world(objects, signs)
    Data.maps = { VIRIDIAN_CITY = { objects = objects, signs = signs or {},
                                    warps = {}, tileset = "OVERWORLD" } }
  end
  local function count()
    return E.completion()
  end

  do
    world({ obj("A_GIVER", "GIVER"), obj("A_TALKER", "FLAVOUR"),
            obj("A_MOODY", "MOODY") })
    liveOw.map = { id = "VIRIDIAN_CITY" }
    local r = count()
    T.eq(r.total, 1, "only the giver is a task -- flavour and a smile are not")
    T.eq(r.done, 0, "and it is not done yet")

    -- doing the thing moves it across, and does NOT drop it from the total:
    -- a denominator that shrinks when you finish something makes the score
    -- go backwards for doing the very thing it counts
    save.flags.EVENT_TOOK_IT = true
    local after = count()
    T.eq(after.total, 1, "the total holds when the gift is claimed")
    T.eq(after.done, 1, "and it counts as done")
    save.flags = {}
  end

  -- Somebody who is not on the map is one of two different things, and the
  -- compiled-in default says which.  BILL is not in his house at the start
  -- and his errand is not yet yours to miss; the VIRIDIAN old man is there
  -- from the beginning and gone once he is finished with you.  Counting
  -- both the same way marks half the game done before it begins.
  do
    world({ obj("VIRIDIANCITY_OLD_MAN_SLEEPY", "GIVER") })
    T.eq(count().total, 1, "present: counted")
    save.objectToggles = { VIRIDIAN_CITY = { VIRIDIANCITY_OLD_MAN_SLEEPY = false } }
    local gone = count()
    T.eq(gone.total, 1, "someone who starts on the map and has left is a task")
    T.eq(gone.done, 1, "-- a finished one")

    world({ obj("NOBODY_YET", "GIVER") })
    save.objectToggles = { VIRIDIAN_CITY = { NOBODY_YET = false } }
    -- nothing trackable at all reports nothing, rather than 0/0
    T.eq(count(), nil,
      "someone who has not turned up yet is not a task you have missed")
    save.objectToggles = {}

    -- The VIRIDIAN old man, and the reason the default table is not enough
    -- on its own.  OLD_MAN2 is hidden by his own script rather than by a
    -- toggle bit, so he appears in no default table at all -- and reading
    -- only that table made him look like somebody who had never turned up.
    -- He dropped out of the total the moment he was finished with, and the
    -- score went from 1/4 to 1/3 for doing the thing it was counting.
    -- His receipt is the thing that says plainly that it happened.
    world({ obj("SCRIPT_HIDDEN_MAN", "GIVER") })
    T.eq(count().total, 1, "on the map and unfinished: a task")
    save.flags.EVENT_TOOK_IT = true
    save.objectToggles = { VIRIDIAN_CITY = { SCRIPT_HIDDEN_MAN = false } }
    local after = count()
    T.check(after ~= nil,
      "hidden by a script with the receipt claimed is still counted")
    T.eq(after and after.total, 1,
      "hidden by a script with the receipt claimed stays in the total")
    T.eq(after and after.done, 1,
      "and counts as done, not as somebody who never came")
    save.flags, save.objectToggles = {}, {}
  end

  -- Whether somebody is on a map at all is the engine's rule, not a second
  -- copy of it living here.  The engine publishes it for reuse, and a mod
  -- that adds a new way to take somebody off a map replaces it -- so this
  -- has to be read at the moment it is asked, not remembered from load.
  do
    world({ obj("A_GIVER", "GIVER") })
    liveOw.map = { id = "VIRIDIAN_CITY" }
    T.eq(count().total, 1, "counted while the engine says they are there")
    local Ow = require("src.world.OverworldController")
    local real = Ow.objectVisible
    Ow.objectVisible = function() return false end
    local hidden = count()
    Ow.objectVisible = real
    T.eq(hidden, nil,
      "and the engine saying otherwise is what takes them out of the count")
    T.eq(count().total, 1, "with the real rule back, so is the count")
  end

  -- Each building in a town gets its own line, rather than the whole town
  -- arriving as one lump.
  do
    Data.maps = {
      VIRIDIAN_CITY = { tileset = "OVERWORLD",
                        objects = { obj("A_GIVER", "GIVER") }, signs = {},
                        warps = { { destMap = "VIRIDIAN_MART" },
                                  { destMap = "VIRIDIAN_GYM" } } },
      VIRIDIAN_MART = { tileset = "HOUSE",
                        objects = { obj("B_GIVER", "GIVER") }, signs = {},
                        warps = { { destMap = "LAST_MAP" } } },
      VIRIDIAN_GYM  = { tileset = "GYM",
                        objects = { obj("C_GIVER", "GIVER"),
                                    obj("C_TALKER", "FLAVOUR") }, signs = {},
                        warps = { { destMap = "LAST_MAP" } } },
    }
    for _, id in ipairs({ "VIRIDIAN_MART", "VIRIDIAN_GYM" }) do
      MapScripts.attachBase(id, { talk = { GIVER = GIVER,
                                           FLAVOUR = { { "show_text", "hi" } } } })
      MapScripts.invalidate(id)
    end
    liveOw.map = { id = "VIRIDIAN_CITY" }
    local r = count()
    T.eq(r.placeTotal, 3, "the town counts its buildings' tasks as well")
    T.eq(#r.areas, 3, "and lists each one separately")
    T.eq(r.areas[1].name, "OUTSIDE",
      "the town's own row does not repeat the heading above it")
    T.eq(r.areas[2].name, "GYM", "then its buildings, without repeating it")
    T.eq(r.areas[2].total, 1, "the gym's own count -- its flavour NPC is out")
    T.eq(r.areas[3].name, "MART", "in a fixed order, so it cannot reshuffle")

    -- standing in the mart reports the same town and the same breakdown
    liveOw.map = { id = "VIRIDIAN_MART" }
    local inside = count()
    T.eq(inside.place, "VIRIDIAN CITY", "from inside, still the town")
    T.eq(#inside.areas, 3, "with the whole town still broken down")
  end

  -- The place line groups a town with the buildings in it.  Warps are the
  -- only link -- but following them wherever they lead walks out of town
  -- through the tunnels and a few hops later the "place" is most of Kanto.
  do
    local maps = {
      PEWTER_CITY  = { tileset = "OVERWORLD",
                       warps = { { destMap = "PEWTER_GYM" },
                                 { destMap = "PEWTER_MART" } } },
      PEWTER_GYM   = { tileset = "HOUSE", warps = { { destMap = "PEWTER_CITY" } } },
      PEWTER_MART  = { tileset = "HOUSE",
                       warps = { { destMap = "PEWTER_CITY" },
                                 { destMap = "TUNNEL" } } },
      TUNNEL       = { tileset = "CAVERN", warps = { { destMap = "FAR_CITY" } } },
      FAR_CITY     = { tileset = "OVERWORLD", warps = { { destMap = "FAR_HOUSE" } } },
      FAR_HOUSE    = { tileset = "HOUSE", warps = { { destMap = "FAR_CITY" } } },
    }
    local place = E.placeAround("PEWTER_CITY", maps)
    T.eq(place.PEWTER_CITY, true, "the town itself")
    T.eq(place.PEWTER_GYM, true, "and the gym in it")
    T.eq(place.PEWTER_MART, true, "and the mart")
    T.eq(place.FAR_CITY, nil, "but the walk stops at the next town")
    T.eq(place.FAR_HOUSE, nil, "and never reaches what is inside it")

    -- standing indoors still names the town, not the room
    local inside, anchor = E.placeAround("PEWTER_GYM", maps)
    T.eq(anchor, "PEWTER_CITY", "from inside, the place is the town outside")
    T.eq(inside.PEWTER_MART, true, "with the rest of the town counted too")

    -- a warp that means "back the way you came" is not a map
    local lastMap = { HOUSE = { tileset = "HOUSE",
                                warps = { { destMap = "LAST_MAP" } } } }
    local ok = pcall(E.placeAround, "HOUSE", lastMap)
    T.eq(ok, true, "LAST_MAP is skipped rather than followed")

    -- The shape most buildings in the game actually have: the door out says
    -- LAST_MAP rather than naming the town, so the only thing joining the
    -- museum to PEWTER CITY is the town's own door pointing in.  Walking
    -- doors forwards alone would leave every such building its own place,
    -- and standing inside one would stop naming the town you are in.
    local realish = {
      VIRIDIAN_CITY = { tileset = "OVERWORLD",
                        warps = { { destMap = "VIRIDIAN_HOUSE" },
                                  { destMap = "VIRIDIAN_GYM" } } },
      VIRIDIAN_HOUSE = { tileset = "HOUSE",
                         warps = { { destMap = "LAST_MAP" } } },
      VIRIDIAN_GYM  = { tileset = "GYM", warps = { { destMap = "LAST_MAP" } } },
    }
    -- ROUTE 23 and INDIGO PLATEAU are PLATEAU-tileset, which the engine
    -- does not call outdoor. Left that way they are swallowed by whatever
    -- town has a door onto them, instead of being places in their own
    -- right -- and the whole end of the game loses its name. The town map
    -- makes the same exception so INDIGO PLATEAU reaches the fly list.
    --
    -- Checked by MEMBERSHIP, not by the name: a sealed-off block happens to
    -- name itself the same way by falling back, so the name alone cannot
    -- tell the two behaviours apart.
    local plateau = {
      A_TOWN         = { tileset = "OVERWORLD",
                         warps = { { destMap = "INDIGO_PLATEAU" } } },
      INDIGO_PLATEAU = { tileset = "PLATEAU",
                         warps = { { destMap = "A_TOWN" } } },
    }
    local townPlace = E.placeAround("A_TOWN", plateau)
    T.eq(townPlace.INDIGO_PLATEAU, nil,
      "a PLATEAU map is a place of its own, not swallowed by the town next door")
    T.eq(select(2, E.placeAround("INDIGO_PLATEAU", plateau)), "INDIGO_PLATEAU",
      "and it names itself")

    -- Somewhere genuinely sealed off from daylight falls back to naming
    -- itself. Walked with pairs() that was whichever map the hash reached
    -- first, so the same cave named itself differently from one run to the
    -- next -- HALL OF FAME, then LORELEIS ROOM, then somewhere else again.
    --
    -- What is asserted is the guarantee sorting gives: the first name in
    -- order. The failure it prevents cannot be reproduced inside one run --
    -- pairs() is stable within a process and only varies between them --
    -- so this pins the rule rather than catching the old symptom.
    -- joined both ways, as real rooms are: a map nothing warps INTO is
    -- correctly a place of its own, which is not what is being tested here
    local sealed = {
      C_ROOM = { tileset = "CAVERN", warps = { { destMap = "B_ROOM" } } },
      B_ROOM = { tileset = "CAVERN", warps = { { destMap = "A_ROOM" },
                                               { destMap = "C_ROOM" } } },
      A_ROOM = { tileset = "CAVERN", warps = { { destMap = "B_ROOM" } } },
    }
    T.eq(select(2, E.placeAround("C_ROOM", sealed)), "A_ROOM",
      "a sealed-off block names itself after its first map, in order")

    local group, town = E.placeAround("VIRIDIAN_HOUSE", realish)
    T.eq(town, "VIRIDIAN_CITY",
      "a building whose only way out is LAST_MAP still belongs to its town")
    T.eq(group.VIRIDIAN_GYM, true, "and brings the rest of the town with it")
  end

  -- The score is the first thing on the guide page, and the page wraps to a
  -- 14-column box.  A line wider than that runs out through the border.
  do
    world({ obj("A_GIVER", "GIVER"), obj("A_TALKER", "FLAVOUR") })
    liveOw.map = { id = "VIRIDIAN_CITY" }
    require("src.ui.Screens").invalidate()
    local factory = Data.screens.npc_bubbles_guide
    local made, page = pcall(function()
      local f = type(factory) == "table" and factory.new or factory
      return f(run.loader.game)
    end)
    T.check(made and page, "the guide builds (" .. tostring(page) .. ")")
    if made and page then
      -- The legend, and ONLY the legend. The count is on its own screen
      -- now: merged, this page could not be opened without first running
      -- the sweep over every map in the game, to read four lines of
      -- reference text that never change.
      for i, e in ipairs(page.entries) do
        T.check(e.tier ~= nil,
          "guide entry " .. i .. " is a bubble, not a tally")
      end
      T.eq(#page.entries, 4, "one entry per bubble the mod can draw")
      local widest = 0
      for _, e in ipairs(page.entries) do
        for _, line in ipairs(e.lines) do widest = math.max(widest, #line) end
      end
      T.check(widest <= 14,
        "every line fits the box (widest is " .. widest .. ")")
      T.check(pcall(page.draw, page), "and the page draws")
      page.scroll = page:maxScroll()
      T.check(pcall(page.draw, page), "and draws scrolled to the bottom")
    end

    -- and the checklist is the one carrying the count
    local listFactory = Data.screens.npc_bubbles_checklist
    local built, list = pcall(function()
      local f = type(listFactory) == "table" and listFactory.new or listFactory
      return f(run.loader.game)
    end)
    T.check(built and list, "the checklist builds (" .. tostring(list) .. ")")
    if built and list then
      T.eq(list.title, "CHECKLIST", "under its own heading")
      local first = list.entries[1]
      T.eq(first.tier, nil, "its lines carry no bubble of their own")
      T.eq(first.lines[1], "0/1 DONE", "and it opens with the count")
      local widest = 0
      for _, e in ipairs(list.entries) do
        for _, line in ipairs(e.lines) do widest = math.max(widest, #line) end
      end
      T.check(widest <= 14,
        "every line fits the box (widest is " .. widest .. ")")
      T.check(pcall(list.draw, list), "and it draws")
    end

    -- ------- everywhere else you have been
    --
    -- save.visited only ever holds the eleven fly towns -- a route or a cave
    -- sets no flag when you walk into it. What DOES get written down is
    -- anything you beat or picked up, against the map it was on, so those
    -- keys name the places the flag misses. It can only miss somewhere,
    -- never invent one: it will not name a town before you have found it.
    do
      for _, id in ipairs({ "PEWTER_CITY", "CERULEAN_CITY" }) do
        MapScripts.attachBase(id, { talk = { GIVER = GIVER } })
        MapScripts.invalidate(id)
      end
      Data.maps = {
        VIRIDIAN_CITY = { tileset = "OVERWORLD", warps = {}, signs = {}, index = 1,
                          objects = { obj("V_GIVER", "GIVER") } },
        PEWTER_CITY   = { tileset = "OVERWORLD", warps = {}, signs = {}, index = 2,
                          objects = { obj("P_GIVER", "GIVER") } },
        CERULEAN_CITY = { tileset = "OVERWORLD", warps = {}, signs = {}, index = 3,
                          objects = { obj("C_GIVER", "GIVER") } },
      }
      liveOw.map = { id = "CERULEAN_CITY" }
      local f = type(listFactory) == "table" and listFactory.new or listFactory

      local function listed()
        local page = f(run.loader.game)
        local out = {}
        for _, e in ipairs(page.entries) do
          for _, l in ipairs(e.lines) do out[#out + 1] = l end
        end
        return table.concat(out, "\n"), out
      end

      -- CERULEAN is marked visited too, so the only thing that can keep it
      -- off the list is that it is the place you are standing in -- which
      -- is what this is checking. Left unvisited it would be absent anyway
      -- and the check would prove nothing.
      save.visited = { VIRIDIAN_CITY = true, CERULEAN_CITY = true }
      save.defeatedTrainers, save.itemsTaken = {}, {}
      local all = listed()
      T.check(all:find("VIRIDIAN"), "a town you have visited is listed")
      T.check(not all:find("PEWTER"),
        "one you have not been to is not, however much is left in it")
      T.check(not all:match("CERULEAN%s+%d+/%d+"),
        "and the place you are standing in is not repeated below itself")

      -- the part save.visited cannot do: a route or a cave
      save.defeatedTrainers = { PEWTER_CITY_obj_1 = true }
      T.check(listed():find("PEWTER"),
        "somewhere you beat a trainer counts as somewhere you have been")
      save.defeatedTrainers = {}
      save.itemsTaken = { PEWTER_CITY_obj_9 = true }
      T.check(listed():find("PEWTER"), "and so does somewhere you took an item")

      -- A road between two places you have been is a road you have walked.
      -- ROUTE 1 has nobody to fight and nothing to pick up, so nothing is
      -- ever written down against it -- but it is the only way from PALLET
      -- to VIRIDIAN, and the map says so itself.
      do
        MapScripts.attachBase("ROUTE_1", { talk = { GIVER = GIVER } })
        MapScripts.attachBase("ROUTE_9", { talk = { GIVER = GIVER } })
        MapScripts.invalidate("ROUTE_1"); MapScripts.invalidate("ROUTE_9")
        -- A NEW table, not the old one with maps added to it: both the
        -- baseline and the place walk are cached against the table they
        -- were worked out from, so a map added in place is never seen.
        local was = Data.maps
        Data.maps = {
          VIRIDIAN_CITY = was.VIRIDIAN_CITY, PEWTER_CITY = was.PEWTER_CITY,
          CERULEAN_CITY = was.CERULEAN_CITY,
          ROUTE_1 = { tileset = "OVERWORLD", warps = {}, signs = {},
            index = 12, objects = { obj("R1_GIVER", "GIVER") },
            connections = { north = { map = "VIRIDIAN_CITY" },
                            south = { map = "PEWTER_CITY" } } },
          -- a dead end off a town you have been to proves nothing
          ROUTE_9 = { tileset = "OVERWORLD", warps = {}, signs = {},
            index = 13, objects = { obj("R9_GIVER", "GIVER") },
            connections = { west = { map = "VIRIDIAN_CITY" } } },
        }
        save.visited = { VIRIDIAN_CITY = true, PEWTER_CITY = true }
        save.defeatedTrainers, save.itemsTaken = {}, {}
        liveOw.map = { id = "CERULEAN_CITY" }
        local roads = listed()
        T.check(roads:find("ROUTE 1"),
          "a road between two places you have been is listed")
        T.check(not roads:find("ROUTE 9"),
          "a dead end off one of them is not -- it proves nothing")

        -- and one end unknown keeps it off
        save.visited = { VIRIDIAN_CITY = true }
        T.check(not listed():find("ROUTE 1"),
          "nor is a road whose far end you have not reached")
        save.visited = { VIRIDIAN_CITY = true, PEWTER_CITY = true }
        Data.maps = was
      end

      -- A name too long to sit beside its count loses whole words rather
      -- than letters: VIRIDIAN CITY becomes VIRIDIAN, never VIRIDIAN C.
      local _, lines = listed()
      local shortened
      for _, l in ipairs(lines) do
        if l:find("^VIRIDIAN%s+%d+/%d+$") then shortened = l end
      end
      T.check(shortened ~= nil,
        "the listed name drops its last word: " .. table.concat(lines, " | "))

      -- The game's own map numbering, not the names: sorted by name,
      -- ROUTE 10 comes out above ROUTE 2.
      -- The two orders have to DISAGREE here or this proves nothing:
      -- PEWTER sorts before VIRIDIAN by name, so give VIRIDIAN the lower
      -- map number and the answers separate.
      save.visited = { VIRIDIAN_CITY = true, PEWTER_CITY = true }
      save.defeatedTrainers, save.itemsTaken = {}, {}
      liveOw.map = { id = "CERULEAN_CITY" }
      Data.maps.VIRIDIAN_CITY.index, Data.maps.PEWTER_CITY.index = 4, 9
      local _, ordered = listed()
      local seenP, seenV
      for i, l in ipairs(ordered) do
        if l:find("^PEWTER%s") then seenP = i end
        if l:find("^VIRIDIAN%s") then seenV = i end
      end
      T.check(seenP and seenV and seenV < seenP,
        "listed by map number, not by name -- otherwise ROUTE 10 beats ROUTE 2")
      Data.maps.VIRIDIAN_CITY.index, Data.maps.PEWTER_CITY.index = 1, 2

      save.visited = nil
      Data.field.flyOrder = nil
    end
  end

  Data.maps = nil
  save.objectToggles, save.itemsTaken = {}, {}
  save.flags, save.inventory = {}, {}
  liveOw.map = { id = "PEWTER_CITY" }
end

-- ------- never run somebody else's code
--
-- Working out what an NPC has for you means RUNNING their talk script. That
-- is safe for the base game, whose scripts are handed a `game` and touch
-- only what they are given -- the sandbox swaps the save, swallows pushes
-- and captures rows instead of playing them.
--
-- It is not safe for a script another mod wrote. The mod API hands each mod
-- a `mod.world` bound to the LIVE game, so a script written against it never
-- touches the game we pass in: warpTo starts a real warp, removeNpc takes
-- somebody off the real map. KANTO ASCENDANT's PALLET boat does both, and
-- probing it hid the sailor and sailed the player to the outpost -- four
-- times over from one map entry, because the probe answers yes to every
-- question and runs several times per NPC.
--
-- A row list is data and stays readable whoever wrote it. A closure is code.
do
  local MapScripts = require("src.script.MapScripts")
  local CoreData = require("src.core.Data")
  local live = { warps = 0, removed = false }
  local ranRows = false

  CoreData.map_scripts = CoreData.map_scripts or {}
  local chain = { { priority = 2400, talk = {
    -- somebody else's closure, reaching past the game it was handed
    BOAT = function()
      live.removed = true                  -- mod.world:removeNpc(id)
      live.warps = live.warps + 1          -- mod.world:warpTo(...)
    end,
    -- and somebody else's ROWS, which are only ever read
    ROWS = { { "give_item", "POTION" } },
  } } }
  chain.owners = { { modId = "kanto_ascendant" } }
  CoreData.map_scripts.VIRIDIAN_CITY = chain
  MapScripts.invalidate("VIRIDIAN_CITY")

  T.eq((MapScripts.talkSource("VIRIDIAN_CITY", "BOAT") or {}).modId,
    "kanto_ascendant", "the engine reports whose script it is")

  local boat = { id = "boat", px = 0, py = 0, cellX = 1, cellY = 1,
                 def = { text = "BOAT", name = "PALLETTOWN_BOAT", index = 1 } }
  function boat:facePlayer() end
  local rows = { id = "rows", px = 0, py = 0, cellX = 2, cellY = 2,
                 def = { text = "ROWS", name = "ROWS_NPC", index = 2 } }
  function rows:facePlayer() end

  liveOw.map = { id = "VIRIDIAN_CITY" }
  liveOw.npcs = { boat, rows }
  liveOw.player = { inputLocked = false, cellX = 5, cellY = 5,
                    px = 80, py = 80, facing = "down" }
  liveOw.runner = { isRunning = function() return false end }
  run.loader.game.stack.top = function() return liveOw end
  run.loader.events:emit("map.entered", { map = "VIRIDIAN_CITY" })
  local tiers = run.loader.exports.npc_bubbles.tiers()

  T.eq(live.warps, 0, "classifying does not run another mod's closure")
  T.eq(live.removed, false, "so it cannot take their NPC off the map")
  T.eq(tiers.boat, 3, "they get the smile, like any script we cannot read")
  T.eq(tiers.rows, 1,
    "but a mod's ROW list is still read: it is data, and nothing runs")

  -- the other way in: talking to them, which asks again for their wording
  run.loader.modOptions.npc_bubbles = { heard = true }
  run.loader.events:emit("world.interacted",
    { mapId = "VIRIDIAN_CITY", kind = "npc", target = boat })
  pcall(run.loader.exports.npc_bubbles.drawFor, boat, 0, 0)
  T.eq(live.warps, 0, "and neither does talking to them")
  T.eq(live.removed, false, "still on the map")

  run.loader.modOptions.npc_bubbles = {}
  CoreData.map_scripts.VIRIDIAN_CITY = nil
  MapScripts.invalidate("VIRIDIAN_CITY")
  liveOw.npcs = {}
end

-- ------- only characters this font actually has
--
-- The scroll hint used an up arrow, and the game's font has no such glyph.
-- A missing one is not an error: the engine substitutes, and on the
-- handheld it came out as a triangle pointing RIGHT -- an arrow pointing
-- somewhere the page could not go, sitting next to the real one pointing
-- down.  Everything a test could ask said it was fine. It drew without
-- error, every line fitted the box, and the fixture font here is so thin
-- that watching for missing-glyph warnings proves nothing -- it is missing
-- most of the alphabet, and each one is only ever reported once anyway.
--
-- So the check is on the source: the font is built from the ROM and cannot
-- be consulted from here, which leaves the list of exotic characters this
-- mod is allowed to draw. The arrow below the text box is one the game
-- draws itself; an up arrow is not.
do
  local f = io.open("mods/npc_bubbles/main.lua", "r")
  T.check(f ~= nil, "the mod source is readable from the engine root")
  if f then
    local src = f:read("*a"); f:close()
    local ALLOWED = { ["▼"] = true }
    local bad = {}
    for run_ in src:gmatch("[\194-\244][\128-\191]*") do
      if not ALLOWED[run_] then bad[#bad + 1] = run_ end
    end
    T.eq(#bad, 0, "the mod draws no character the game's font lacks ("
      .. table.concat(bad, " ") .. ")")
  end
end

run.release()
T.finish("npc_bubbles")

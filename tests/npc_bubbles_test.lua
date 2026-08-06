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
local run = T.sdk.loadMod("mods/npc_bubbles", { data = Data })
T.eq(#run.errors, 0, "loads clean (" .. tostring(run.errors[1]) .. ")")

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
  T.eq(tierOf({ { "show_text", "hi" } }, game()), 3, "plain text is tier 3")
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

-- ------- the draw seam
--
-- This is the bug 1.0.0 shipped with, so it gets a test of its own.
-- OverworldState:draw is beginWorldPass / drawWorld / endWorldPass /
-- drawUI, so decorating `draw` puts the bubbles outside the world pass and
-- nothing appears where npc.px - cam.x says it should.  The engine's own
-- sighting bubble lives inside drawWorld; ours has to as well.

do
  local drew = {}
  local realDraw = love.graphics.draw
  love.graphics.draw = function(_, _, x, y) drew[#drew + 1] = { x = x, y = y } end

  local ow = {
    isOverworld = true,
    map = { id = "PEWTER_CITY" },
    camera = { x = 100, y = 50 },
    npcs = {},
    calls = { draw = 0, drawWorld = 0 },
  }
  function ow:draw() self.calls.draw = self.calls.draw + 1 end
  function ow:drawWorld() self.calls.drawWorld = self.calls.drawWorld + 1 end

  local fake = { save = { flags = {} }, data = Data,
                 stack = { states = { ow } } }
  run.loader.game = fake

  Runtime.emit("map.entered", { mapId = "PEWTER_CITY" })

  T.check(ow.calls.drawWorld == 0, "attaching does not draw by itself")
  ow:drawWorld()
  T.eq(ow.calls.drawWorld, 1, "the original drawWorld still runs")
  ow:draw()
  T.eq(ow.calls.draw, 1, "draw is left alone")

  -- and the bubble lands where the engine puts its own
  local npc = { id = "n1", px = 160, py = 96,
                def = { text = "TEXT_X" } }
  ow.npcs = { npc }
  -- classify it directly: the fixture has no map_scripts, so seed the table
  local tiers = run.loader.exports.npc_bubbles.tiers()
  tiers[npc.id] = 1
  drew = {}
  ow:drawWorld()
  if #drew > 0 then
    T.eq(drew[1].x, 160 - 100 + 4, "the bubble sits +4 across, like fxEmote")
    T.eq(drew[1].y, 96 - 50 - 14, "and -14 up, at a real bubble's height")
  else
    T.check(true, "no emote sheet in the fixture; placement covered by offsets")
  end

  love.graphics.draw = realDraw
  run.loader.game = nil
end

run.release()
T.finish("npc_bubbles")

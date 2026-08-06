-- npc_bubbles: put a bubble over NPCs who actually do something.
--
-- The hard part is not drawing -- it is knowing, without talking to them,
-- which NPCs are worth talking to.  OverworldState:talkTo resolves an
-- interaction in a fixed order (a hand-ported script, then an item ball,
-- then a static encounter, then plain text), and the hand-ported scripts
-- are DATA: numbered instruction lists with conditional jumps.
--
--   { "check_flag", "EVENT_GOT_TOWN_MAP" },
--   { "jump_if_true", 10 },          -- already have it: skip the gift
--   { "give_item", "TOWN_MAP", 1, "_GotMapText" },
--
-- So this mod walks the same instructions the game would walk, evaluating
-- the branches against the live save, and reports what a conversation would
-- actually produce RIGHT NOW.  That is stronger than "this NPC has a gift":
-- Daisy is silent before you have a starter, and silent again once you hold
-- the map, because in both cases the give_item is unreachable.

local MapScripts = require("src.script.MapScripts")

-- Tier 1: you receive something.
local GIVES = {
  give_item = true, give_pokemon = true, give_money = true,
  trade = true, open_mart = true, heal_party = true,
}

-- Tier 2: the world changes.  These write; tier 3 only reads.
local CHANGES = {
  set_flag = true, hide_object = true, show_object = true,
  replace_block = true, static_battle = true, rival_battle = true,
  warp = true,
}

-- EXCLAMATION_BUBBLE, QUESTION_BUBBLE, SMILE_BUBBLE -- the three 16x16
-- crops of the engine's own emote sheet, in sheet order.
--
-- Tier 4 is "there is something here, but not yet": the same exclamation
-- crop drawn faded.  A new symbol would have to be hand-drawn, and every
-- icon drawn for these mods has lost to the engine's own art; reusing the
-- ! at lower opacity says "the important kind of NPC, not active yet"
-- without inventing anything.  It also reads as provisional, which suits a
-- judgement that can occasionally be wrong.
local BUBBLE = { 1, 2, 3, 1 }
local ALPHA  = { 1, 1, 1, 0.45 }
local TIER_OPTION = { "gift", "event", "story", "later" }

-- The three commands that read your state.  A program containing one is
-- one whose dialogue can differ depending on what you have done -- which is
-- exactly what the smile is for.
local CONDITIONS = { check_flag = true, check_item = true, check_dex_owned = true }

-- a script that jumps backwards could spin forever; no vanilla one does,
-- but this runs every time a flag changes and must not be able to hang
local MAX_STEPS = 400

return function(mod)
  mod.options:define({
    { key = "gift", label = "GIFT BUBBLE", type = "toggle", default = true },
    { key = "event", label = "EVENT BUBBLE", type = "toggle", default = true },
    { key = "story", label = "STORY BUBBLE", type = "toggle", default = true },
    { key = "later", label = "LATER BUBBLE", type = "toggle", default = true },
  })

  -- ------- reading the live state the branches ask about

  -- Read straight off the save rather than through mod.world: event flags
  -- are plain `save.flags[name]` (src/script/Flags.lua), so going via the
  -- facade would add a dependency on a live game for what is a table read.
  local function condition(verb, arg, game)
    if verb == "check_flag" then
      local save = game and game.save
      return (save and save.flags and save.flags[arg]) == true
    elseif verb == "check_item" then
      local bag = game and game.save and game.save.inventory or {}
      return (bag[arg] or 0) > 0
    elseif verb == "check_dex_owned" then
      local dex = game and game.save and game.save.pokedex
      local n = 0
      for _ in pairs(dex and dex.owned or {}) do n = n + 1 end
      return n >= (tonumber(arg) or 0)
    end
    return nil          -- not a condition
  end

  -- Walks the program from the top and returns the highest tier reachable
  -- on the path the branches actually take.  Pure reads: no command is
  -- executed, only classified.
  local function reachableTier(prog, game)
    local labels
    for i, row in ipairs(prog) do
      if type(row) == "table" and row[1] == "label" then
        labels = labels or {}
        labels[row[2]] = i
      end
    end
    local function target(v)
      if type(v) == "number" then return v end
      return labels and labels[v] or nil
    end

    -- Tier 3 means "their dialogue reacts to your progress", so it needs a
    -- condition somewhere in the program.  Assigning it to anything that
    -- was not a gift or a change made it mean "has a script at all", and
    -- put a smiley over every NPC who says one fixed line -- 116 of 173 of
    -- them, which is how a hint becomes wallpaper.
    local reactive = false
    for _, row in ipairs(prog) do
      if type(row) == "table" and CONDITIONS[row[1]] then reactive = true break end
    end

    local pc, last, best, steps = 1, false, reactive and 3 or nil, 0
    while pc <= #prog and steps < MAX_STEPS do
      steps = steps + 1
      local row = prog[pc]
      if type(row) ~= "table" then pc = pc + 1
      else
        local verb = row[1]
        local cond = condition(verb, row[2], game)
        if cond ~= nil then
          last = cond
          pc = pc + 1
        elseif verb == "jump_if_true" then
          pc = last and (target(row[2]) or (pc + 1)) or (pc + 1)
        elseif verb == "jump_if_false" then
          pc = (not last) and (target(row[2]) or (pc + 1)) or (pc + 1)
        elseif verb == "jump" then
          local to = target(row[2])
          -- a backward jump is a loop we do not need to trace twice; the
          -- step budget catches it either way
          pc = (to and to > pc) and to or (pc + 1)
        else
          if GIVES[verb] then best = 1
          elseif CHANGES[verb] and best ~= 1 then best = 2 end
          pc = pc + 1
        end
      end
    end
    return best
  end

  -- Why a gift was not reachable -- which is the difference between "you
  -- already have this" and "come back later", and the only reason a
  -- come-back-later marker can exist without the stale bubbles returning.
  --
  -- A claimed gift is blocked by the very flag the script set when it gave
  -- it to you: check_flag GOT_X guarding a path that ends set_flag GOT_X.
  -- Anything else blocking it -- a happiness threshold, an item you do not
  -- carry, a badge -- is a prerequisite, not a receipt.
  --
  -- It is a judgement, not a proof: a script gating its gift on someone
  -- else's flag would read as "later" forever.  14 of the 29 gift programs
  -- guard themselves this way and 15 are gated by something else, so both
  -- halves are real rather than one being a rounding error.
  local function giftOutlook(prog, game)
    local hasGive, sets, checks = false, {}, {}
    for _, row in ipairs(prog) do
      if type(row) == "table" then
        if GIVES[row[1]] then hasGive = true end
        if row[1] == "set_flag" then sets[row[2]] = true end
        if row[1] == "check_flag" then checks[row[2]] = true end
      end
    end
    if not hasGive then return nil end
    for name in pairs(sets) do
      if checks[name] and condition("check_flag", name, game) then
        return "done"
      end
    end
    return "later"
  end

  -- The tier an NPC is worth right now, including the not-yet case.
  local function classify(prog, game)
    local tier = reachableTier(prog, game)
    if tier == 1 or tier == 2 then return tier end
    -- a gift that exists but is out of reach, and has not been claimed
    if giftOutlook(prog, game) == "later" then return 4 end
    return tier
  end

  mod.exports.classify = classify
  mod.exports.giftOutlook = giftOutlook

  -- ------- what each NPC on this map is worth
  --
  -- Rebuilt on map entry (the NPC set changed) and on flag.changed (a
  -- branch may have flipped).  Nothing polls: a gift script sets its flag
  -- as its last step, so the bubble clears the same frame the conversation
  -- ends.

  local tiers = {}          -- npc.id -> tier
  local opaque = {}         -- text ids whose talk entry is a function
  local reported = false

  -- A talk entry is either an instruction list or a function -- and the
  -- function is not opaque logic, it is a BUILDER.  It reads your save,
  -- assembles the rows the conversation would run, and hands them to
  -- ow.runner:run as its very last act (see Melanie's Bulbasaur in
  -- data/scripts/yellow_gifts.lua).  So call it with a runner that captures
  -- instead of running, and the program it built for your exact save falls
  -- out -- the same thing the walker reads for the table case.
  --
  -- Nothing is executed: the fake runner never runs a row, and a closure
  -- that does not fit the pattern throws on the stub ow and is caught,
  -- leaving that NPC unclassified exactly as before.
  local function programFor(prog, game, npc)
    if type(prog) == "table" then return prog end
    if type(prog) ~= "function" then return nil end
    local captured
    local stub = { runner = { run = function(_, rows) captured = rows end } }
    local ok = pcall(prog, game, stub, npc, function() end)
    if ok and type(captured) == "table" then return captured end
    return nil
  end

  local function rebuild()
    tiers = {}
    local game = mod.world and mod.world.game
    local ow = mod.world and mod.world:overworld()
    local map = ow and ow.map
    if not (map and map.id) then return end
    local view = MapScripts.get(map.id)
    local talk = view and view.talk
    if not talk then return end
    for _, npc in ipairs(ow.npcs or {}) do
      local key = npc.def and npc.def.text
      local prog = programFor(key and talk[key], game, npc)
      if prog then
        tiers[npc.id] = classify(prog, game)
      elseif type(key and talk[key]) == "function" then
        opaque[map.id .. "/" .. tostring(key)] = true
      end
    end
  end

  mod.events:on("map.entered", rebuild)
  mod.events:on("map.reloaded", rebuild)
  mod.events:on("flag.changed", rebuild)
  mod.events:on("save.loaded", rebuild)

  mod.events:on("game.ready", function()
    if reported then return end
    reported = true
    local n = 0
    for _ in pairs(opaque) do n = n + 1 end
    if n > 0 then
      mod.log:info("%d talk entries are functions rather than instruction "
        .. "lists; those NPCs cannot be classified", n)
    end
  end)

  -- ------- drawing
  --
  -- The engine's own emote art, baked the way it bakes it: the sheet is OBJ
  -- art read through OBP0, so a raw blit leaves the bubble's interior at
  -- shade 1 grey instead of white.  Same remap as obpEmoteImage.

  local sheet, quads = nil, nil

  local function art(game)
    if sheet ~= nil then return sheet end
    sheet = false
    local def = game and game.data and game.data.field
      and game.data.field.emotionBubbles
    if not (def and def.path and def.bubbles) then return sheet end
    local ok, image = pcall(function()
      if not (love.image and love.image.newImageData) then
        return love.graphics.newImage(def.path)
      end
      local id = love.image.newImageData(def.path)
      id:mapPixel(function(_, _, r, _, _, a)
        local v = 0
        if r > 0.5 then v = 1
        elseif r > 0.17 then v = 170 / 255 end
        return v, v, v, a
      end)
      return love.graphics.newImage(id)
    end)
    if not ok or not image then
      mod.log:warn("could not load the emote sheet: %s", tostring(image))
      return sheet
    end
    quads = {}
    local iw, ih = image:getDimensions()
    for i, b in ipairs(def.bubbles) do
      quads[i] = love.graphics.newQuad(b.x, b.y, b.w, b.h, iw, ih)
    end
    sheet = image
    return sheet
  end

  local function enabled(tier)
    return mod.options:get(TIER_OPTION[tier]) == true
  end

  -- Drawn per NPC, immediately after that NPC's own sprite, in whatever
  -- space the sprite was drawn in.
  --
  -- This matters because the overworld has two draw paths.  The flat one
  -- blits sprites at px - camX; the tilt one (the voxel diorama) wraps each
  -- sprite in a billboard transform and calls the engine's own emote
  -- through an `at(...)` helper.  A bubble drawn once per frame from
  -- outside would need to know which path is live and reproduce its
  -- transform -- which is how the first attempt ended up several tiles east
  -- of the NPC.  Riding the sprite's own draw call inherits the transform
  -- for free, so the offsets below are correct in both modes.
  local function drawFor(npc, camX, camY)
    local tier = tiers[npc.id]
    if not (tier and enabled(tier)) then return end
    local image = art(mod.world and mod.world.game)
    if not (image and quads and quads[BUBBLE[tier]]) then return end
    local g = love.graphics
    local r, gg, b, a = g.getColor()
    g.setColor(1, 1, 1, ALPHA[tier] or 1)
    -- fxEmote's own offsets: SpriteRenderer puts the sprite's top at
    -- py - camY - 4, so -14 lands the bubble just above the head
    g.draw(image, quads[BUBBLE[tier]],
           math.floor(npc.px - camX) + 4, math.floor(npc.py - camY) - 14)
    g.setColor(r, gg, b, a)
  end

  mod.exports.reachableTier = reachableTier
  mod.exports.programFor = programFor
  mod.exports.tiers = function() return tiers end

  -- Wrapping NPC.draw rather than the overworld's: it is the one call that
  -- happens once per NPC, inside whichever transform that NPC's sprite is
  -- being drawn under.  Wrapped on the class, so every NPC on every map is
  -- covered by a single wrap and nothing needs re-attaching on a map change.
  local attached = false

  local function attach()
    if attached then return end
    local NPC = require("src.world.NPC")
    if type(NPC.draw) ~= "function" then return end
    attached = true
    local baseDraw = NPC.draw
    NPC.draw = function(self, camX, camY, ...)
      baseDraw(self, camX, camY, ...)
      local ok, err = pcall(drawFor, self, camX or 0, camY or 0)
      if not ok then mod.log:error("bubble draw failed: %s", tostring(err)) end
    end
  end

  mod.exports.drawFor = drawFor

  mod.events:on("game.ready", attach)
  mod.events:on("map.entered", attach)
  attach()
end

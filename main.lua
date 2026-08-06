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
local BUBBLE = { 1, 2, 3 }
local TIER_OPTION = { "gift", "event", "story" }

-- a script that jumps backwards could spin forever; no vanilla one does,
-- but this runs every time a flag changes and must not be able to hang
local MAX_STEPS = 400

return function(mod)
  mod.options:define({
    { key = "gift", label = "GIFT BUBBLE", type = "toggle", default = true },
    { key = "event", label = "EVENT BUBBLE", type = "toggle", default = true },
    { key = "story", label = "STORY BUBBLE", type = "toggle", default = true },
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

    local pc, last, best, steps = 1, false, nil, 0
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
          elseif CHANGES[verb] and best ~= 1 then best = 2
          elseif not best then best = 3 end
          pc = pc + 1
        end
      end
    end
    return best
  end

  -- ------- what each NPC on this map is worth
  --
  -- Rebuilt on map entry (the NPC set changed) and on flag.changed (a
  -- branch may have flipped).  Nothing polls: a gift script sets its flag
  -- as its last step, so the bubble clears the same frame the conversation
  -- ends.

  local tiers = {}          -- npc.id -> tier
  local opaque = {}         -- text ids whose talk entry is a function
  local reported = false

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
      local prog = key and talk[key]
      if type(prog) == "function" then
        -- a hand-written closure, not an instruction list: we cannot see
        -- inside it, so this NPC gets no bubble even if it hands you the
        -- world.  Collected so the gap is visible rather than silent.
        opaque[map.id .. "/" .. tostring(key)] = true
      elseif type(prog) == "table" then
        tiers[npc.id] = reachableTier(prog, game)
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

  local function drawBubbles(ow)
    if not next(tiers) then return end
    local game = mod.world and mod.world.game
    local image = art(game)
    if not image then return end
    local cam = ow.camera
    if not cam then return end
    local g = love.graphics
    g.setColor(1, 1, 1, 1)
    for _, npc in ipairs(ow.npcs or {}) do
      local tier = tiers[npc.id]
      if tier and enabled(tier) and quads[BUBBLE[tier]] then
        -- the slot the engine's own sighting bubble uses: over the head,
        -- half a tile right of the sprite's foot
        g.draw(image, quads[BUBBLE[tier]],
               math.floor(npc.px - cam.x), math.floor(npc.py - cam.y - 8))
      end
    end
  end

  mod.exports.reachableTier = reachableTier
  mod.exports.tiers = function() return tiers end

  -- There is no overworld draw hook, so the mod decorates the state's own
  -- draw the way quality_of_life decorates a battle's: wrap once, call the
  -- original, then add to it.
  local wrapped = setmetatable({}, { __mode = "k" })

  local function attach()
    local ow = mod.world and mod.world:overworld()
    if not ow or wrapped[ow] or type(ow.draw) ~= "function" then return end
    wrapped[ow] = true
    local baseDraw = ow.draw
    ow.draw = function(self, ...)
      baseDraw(self, ...)
      local ok, err = pcall(drawBubbles, self)
      if not ok then mod.log:error("bubble draw failed: %s", tostring(err)) end
    end
    rebuild()
  end

  mod.events:on("game.ready", attach)
  mod.events:on("map.entered", attach)
end

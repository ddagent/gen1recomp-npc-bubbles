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
local TIER_OPTION = { "gift", "event", "story", "later" }

-- The three commands that read your state.  A program containing one is
-- one whose dialogue can differ depending on what you have done -- which is
-- exactly what the smile is for.
local CONDITIONS = { check_flag = true, check_item = true, check_dex_owned = true }

-- Commands whose result is decided in the moment rather than read off the
-- save: a prompt the player answers, and a gift that either lands or finds
-- the bag full.  The walk assumes the willing path.
local OPTIMISTIC = {
  ask = true, choice = true,
  give_item = true, give_pokemon = true, give_money = true, trade = true,
}

-- a script that jumps backwards could spin forever; no vanilla one does,
-- but this runs every time a flag changes and must not be able to hang
local MAX_STEPS = 400

return function(mod)
  mod.options:define({
    { key = "gift", label = "GIFT BUBBLE", type = "toggle", default = true },
    { key = "event", label = "EVENT BUBBLE", type = "toggle", default = true },
    { key = "story", label = "STORY BUBBLE", type = "toggle", default = true },
    { key = "later", label = "LATER BUBBLE", type = "toggle", default = true },
    -- How solid the come-back-later ! is, as a percent.  It has to read as
    -- subordinate to a real one without disappearing into the tilework --
    -- and where that line sits depends on the renderer you use and how
    -- bright the ground is, so it is a dial rather than a constant.  Read
    -- at draw time, so it moves as you turn it.
    { key = "later_fade", label = "LATER FADE %", type = "number",
      default = 75, min = 20, max = 100, step = 5 },
  })

  -- forward declaration: classify needs to rebuild a closure, and the
  -- builder is defined further down with the rest of the map handling
  local programFor

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
        elseif OPTIMISTIC[verb] then
          -- `ask` is a yes/no prompt and give_* reports whether it landed.
          -- Neither can be read off the save -- they are answered at the
          -- time -- so the walk takes the branch a player who WANTS the
          -- thing would take.  Leaving these false was silently deciding
          -- you had declined every gift that asks first, which is how
          -- Melanie's Bulbasaur went invisible.
          last = true
          if GIVES[verb] then best = 1 end
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

  -- A best-case stand-in for the save: nothing done yet, every item in the
  -- bag, every number at its ceiling.
  --
  -- Only closures need this.  A table script always CONTAINS its gift row --
  -- unreachable, but visible -- so "there is something here later" can be
  -- read straight off it.  A closure decides what to write before writing
  -- it, so an unmet prerequisite means the give row is simply absent and
  -- there is nothing to find.  Building the program a second time against a
  -- save that meets everything reveals whether a gift exists at all.
  local function permissive(game)
    local save = (game and game.save) or {}
    local fake = setmetatable({
      flags = setmetatable({}, { __index = function() return false end }),
      inventory = setmetatable({}, { __index = function() return 99 end }),
    }, { __index = function(_, key)
      local v = save[key]
      if type(v) == "number" then return math.huge end
      return v
    end })
    -- already safe: a synthetic save, and a stack that swallows pushes, so
    -- programFor leaves it alone rather than deep-copying the metatables away
    local noop = function() end
    return setmetatable({
      __sandboxed = true,
      save = fake,
      stack = { push = noop, pop = noop, top = noop, states = {} },
    }, { __index = game })
  end

  -- A gift is already claimed when a flag the giving path SETS is already
  -- true.  For a closure this is the only workable test: the flag it checks
  -- lives in Lua, not in the rows, so it never appears in either build --
  -- but the flag it would SET does, and that flag being set already is the
  -- receipt.  Without this Melanie kept a faded ! forever after handing the
  -- BULBASAUR over, which is the exact stale bubble this was meant to avoid.
  local function alreadyClaimed(prog, game)
    for _, row in ipairs(prog or {}) do
      if type(row) == "table" and row[1] == "set_flag"
         and condition("check_flag", row[2], game) then
        return true
      end
    end
    return false
  end

  local function hasGive(prog)
    for _, row in ipairs(prog or {}) do
      if type(row) == "table" and GIVES[row[1]] then return true end
    end
    return false
  end

  -- The tier an NPC is worth right now, including the not-yet case.
  -- `entry` is the original talk entry, needed to rebuild a closure.
  local function classify(prog, game, entry)
    local tier = reachableTier(prog, game)
    if tier == 1 or tier == 2 then return tier end
    -- a gift that exists but is out of reach, and has not been claimed
    if giftOutlook(prog, game) == "later" then return 4 end
    -- closure with no gift in THIS build: ask what it would write at best
    if type(entry) == "function" and not hasGive(prog) then
      local best = programFor(entry, permissive(game))
      if best and hasGive(best) and not alreadyClaimed(best, game) then
        return 4
      end
    end
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
  -- A script that sets three flags fires flag.changed three times, and a
  -- rebuild walks every NPC's program.  Mark and settle once instead: the
  -- draw asks for freshness, so at worst it costs one rebuild per frame and
  -- usually none.
  local dirty = false
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
  -- NOT every closure is a builder.  The bike shop clerk pushes its own
  -- text boxes and touches the bag directly (data/scripts/story2.lua) --
  -- so probing one with the live game could put a text box on screen or
  -- write to the save.  A pcall does not help: those are successes, not
  -- errors.
  --
  -- So a probe never sees the real thing.  It gets a copy of the save
  -- (writes land on the copy and are dropped), a stack that swallows
  -- pushes, and a runner that captures rather than runs.  A builder yields
  -- its rows; an imperative closure spends itself harmlessly on the stub
  -- and yields nothing.
  local function copy(v, depth)
    if type(v) ~= "table" or (depth or 0) > 6 then return v end
    local out = {}
    for k, item in pairs(v) do out[k] = copy(item, (depth or 0) + 1) end
    return out
  end

  -- One copy per rebuild, not one per NPC.  The copy is the expensive part
  -- -- a save carries the party, the boxes, the bag and every flag -- and a
  -- map with several closure NPCs was paying for it once each, on every
  -- flag change.  Reusing it means a builder could in principle see another
  -- builder's discarded writes; that can only mis-tier one bubble, and it
  -- buys turning N deep copies into one.
  -- Keyed on the game it was made from: within one rebuild that is the same
  -- object with the same save, so reuse is free.  A different game -- or a
  -- new rebuild, which clears it -- gets a fresh copy, so a cached sandbox
  -- can never answer for state it was not built from.
  local sandboxCache, sandboxFor = nil, nil

  local function sandbox(game)
    if not game then return nil end
    if sandboxCache and sandboxFor == game then return sandboxCache end
    local noop = function() end
    sandboxFor = game
    sandboxCache = setmetatable({
      __sandboxed = true,
      save = copy(game.save),
      stack = { push = noop, pop = noop, top = noop, states = {} },
    }, { __index = game })
    return sandboxCache
  end

  function programFor(prog, game, npc)
    if type(prog) == "table" then return prog end
    if type(prog) ~= "function" then return nil end
    local captured
    local stub = { runner = { run = function(_, rows) captured = rows end } }
    -- a caller may hand in an already-safe game (the best-case probe);
    -- copying it again would flatten the metatables it is built from
    local safe = (type(game) == "table" and game.__sandboxed) and game
                 or sandbox(game)
    local ok = pcall(prog, safe, stub, npc, function() end)
    if ok and type(captured) == "table" then return captured end
    return nil
  end

  local function rebuild()
    sandboxCache, sandboxFor = nil, nil   -- the save moved; the copy is stale
    dirty = false
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
      local entry = key and talk[key]
      if prog then
        tiers[npc.id] = classify(prog, game, entry)
      elseif type(entry) == "function" then
        -- A closure we cannot read is still a signal.  Ordinary NPCs have
        -- no script at all; a hand-written one exists precisely because the
        -- interaction did not fit the command rows -- the bike shop clerk,
        -- Misty, the badge house.  So it is not "unknown, show nothing",
        -- it is "something bespoke happens here", which is the smile.
        opaque[map.id .. "/" .. tostring(key)] = true
        tiers[npc.id] = 3
      end
    end
  end

  local function ensureFresh()
    if dirty then rebuild() end
  end

  local function markDirty() dirty = true end

  mod.events:on("map.entered", rebuild)
  mod.events:on("map.reloaded", rebuild)
  mod.events:on("flag.changed", markDirty)
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

  -- the faded ! is the only tier drawn at less than full opacity
  local function alphaFor(tier)
    if tier ~= 4 then return 1 end
    return math.max(0.2, math.min(1,
      (tonumber(mod.options:get("later_fade")) or 75) / 100))
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
    if dirty then rebuild() end
    local tier = tiers[npc.id]
    if not (tier and enabled(tier)) then return end
    local image = art(mod.world and mod.world.game)
    if not (image and quads and quads[BUBBLE[tier]]) then return end
    local g = love.graphics
    local r, gg, b, a = g.getColor()
    g.setColor(1, 1, 1, alphaFor(tier))
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

  -- ------- the voxel arena
  --
  -- DRAMATIC_SHAPE registers a render pipeline that supplies its own
  -- drawWorld, and the engine skips the whole flat entity pass when a
  -- pipeline renders the world:
  --
  --   if override then          -- the pipeline drew it
  --   elseif not tilt then      -- ...so this never runs
  --     for _, e in ipairs(self.entities) do e:draw(cam.x, cam.y) end
  --
  -- NPC.draw is inside that skipped branch, so the wrap above simply never
  -- fires in voxel mode.  Nothing was wrong with it; the function it lives
  -- in does not run.
  --
  -- The fix rides the same seam the engine's own "!" does there.  A
  -- presentation-only pipeline (worldPresent, no drawWorld) folds over the
  -- finished world image, and the voxel mod publishes what is needed to
  -- place things in it: project() answers in canvas pixels, and
  -- beginOverlay re-binds that canvas for ordinary 2D drawing.
  --
  -- The two paths cannot both fire.  worldPresent only runs when a pipeline
  -- produced a world canvas, which is exactly when NPC.draw is skipped; in
  -- flat mode there is no canvas and this pass is never called at all.
  -- Whoever registered the "voxel" pipeline is the arena, whatever it is
  -- called.  The merge records provenance under the registry's _owners, so a
  -- fork or a rename is found without this mod knowing its name; the
  -- original stays as the fallback for a build whose registry does not carry
  -- the bookkeeping.
  local function voxelOwner(data)
    data = data or (mod.world and mod.world.game and mod.world.game.data)
    local defs = type(data) == "table" and data.render_pipelines
    local owners = type(defs) == "table" and defs._owners
    if type(owners) == "table" and type(owners.voxel) == "string"
      and owners.voxel ~= "" then
      return owners.voxel
    end
    return "DRAMATIC_SHAPE"
  end
  mod.exports.voxelOwner = voxelOwner

  local voxel, aaLib, voxelTried = nil, nil, false

  local function voxel3D()
    if voxelTried then return voxel, aaLib end
    voxelTried = true
    local handle = type(mod.find) == "function" and mod.find(voxelOwner())
    local lib = handle and handle.exports and handle.exports.lib
    if not (lib and type(lib.require) == "function") then return nil end
    local ok, v = pcall(lib.require, "Voxel3D")
    -- only project() is required now: the overlay canvas comes from
    -- worldPresent's own argument, so beginOverlay is no longer needed
    if ok and type(v) == "table" and type(v.project) == "function" then
      voxel = v
      mod.log:info("voxel arena detected; bubbles will be projected into it")
    end
    -- project() answers in supersampled coordinates when AA is on, but
    -- worldPresent draws on the resolved canvas, so the AA factor is
    -- needed to divide those back down.  Resolved as a module reference
    -- (not a value) so the player toggling AA mid-session takes effect
    -- on the next frame.
    local ok2, aa = pcall(lib.require, "AntiAlias")
    if ok2 and type(aa) == "table" and type(aa.factor) == "function" then
      aaLib = aa
    end
    return voxel, aaLib
  end

  mod.content.render_pipelines:register("npc_bubbles_overlay", {
    label = "NPC BUBBLES 3D",
    -- on unless the player turns it off; without this a pipeline restores
    -- to level 0 and the pass would silently never run
    default = 1,
    worldPresent = function(canvas, ctx)
      local v, aa = voxel3D()
      if not (v and canvas and ctx and tonumber(ctx.vw) and ctx.vw > 0) then
        return canvas
      end
      ensureFresh()
      if not next(tiers) then return canvas end
      local ow = mod.world and mod.world:overworld()
      local image = art(mod.world and mod.world.game)
      if not (ow and image and quads) then return canvas end

      -- canvas pixels per world pixel.  The voxel mod says this as
      -- ctx.scale * AntiAlias.factor(), but the factor is internal to it --
      -- and the canvas it handed back already carries both, so its width
      -- against the world view width is the same number without reaching
      -- for anything private.
      local ok, w = pcall(canvas.getWidth, canvas)
      if not (ok and w) then return canvas end
      local scale = w / ctx.vw
      if not (scale > 0) then return canvas end

      -- project() answers in the SUPERSAMPLED coordinate space when AA is on,
      -- but worldPresent draws onto the RESOLVED canvas.  Dividing by the AA
      -- factor maps supersampled positions back down to resolved pixels, so
      -- the bubble lands at the right place whether AA is off (factor 1),
      -- 2X (factor 2) or 4X.
      local aaFactor = 1
      if aa then
        local ok2, f = pcall(aa.factor)
        if ok2 and tonumber(f) and f > 0 then aaFactor = f end
      end

      -- Draw into the canvas we were HANDED, not the arena's internal one.
      -- worldPresent folds in descending priority, and T-SHIFT (priority 10)
      -- runs first and returns a NEW, blurred canvas -- so beginOverlay's
      -- scene canvas is no longer the image anyone will use, and the bubbles
      -- landed on a discarded buffer.  TiltShift.apply keeps the dimensions,
      -- so project()'s coordinates stay valid either way, and folding last
      -- leaves the bubbles sharp on top of the blur rather than inside it.
      local g = love.graphics
      local prevCanvas = g.getCanvas()
      local bound = pcall(g.setCanvas, canvas)
      if not bound then return canvas end
      pcall(g.setShader)
      if g.setDepthMode then pcall(g.setDepthMode) end

      -- hoisted: these were being re-read per NPC per frame
      local on = { enabled(1), enabled(2), enabled(3), enabled(4) }
      local fade = alphaFor(4)

      for _, npc in ipairs(ow.npcs or {}) do
        local tier = tiers[npc.id]
        if tier and on[tier] and quads[BUBBLE[tier]] then
          -- project() returns canvas x, canvas y, and a depth-scale: how
          -- much the perspective camera magnifies this point (close NPCs
          -- are large, far ones small).  That depth value is what makes
          -- the bubble grow as the NPC approaches under perspective.
          --
          -- The head is projected directly (at a world height of 32) rather
          -- than offsetting a flat number of pixels from the feet, so the
          -- position is correct under any camera angle -- including the
          -- aggressive first-person rung where a flat offset barely moves.
          --
          -- Only x and y carry the AA factor: project() multiplies those by
          -- the scene canvas size, which is the supersampled one.  The third
          -- return is focusW/cw -- one number off the camera matrix divided
          -- by another -- so it is a ratio with no pixels in it and AA
          -- cannot touch it.  Dividing it too made every bubble half size
          -- at 2X and a quarter at 4X.
          -- Ground point, not the head.  These offsets are not guesses --
          -- they are what the engine's own emote works out to.  In the
          -- pipeline path OverworldController anchors an emote at
          -- (px + 8, py + 16) and hands the flat closure a transform:
          --
          --   translate(sx/scale - (px + 8 - cam.x),
          --             sy/scale - (py + 16 - cam.y))   -- drawFx.at
          --   draw at   (px - cam.x + 4, py - cam.y - 14)  -- fxEmote
          --
          -- which cancels to (sx/scale - 4, sy/scale - 30) inside a
          -- scale(scale) -- so sx - 4*scale, sy - 30*scale in canvas pixels.
          -- Projecting the head instead moved the anchor a tile or two off
          -- under a tilted camera, which is what put the bubble in front of
          -- the NPC.
          local sx, sy = v.project(npc.px + 8, 0, npc.py + 16)
          if sx and sy then
            -- Only the position carries the AA factor; there is nothing
            -- else left to correct now that the size is flat again.
            sx, sy = sx / aaFactor, sy / aaFactor
            g.setColor(1, 1, 1, tier == 4 and fade or 1)
            -- Unscaled by depth, deliberately.  The engine says it of its
            -- own field FX: "an effect keeps its crisp authored size and
            -- only its anchor moves."  Scaling with distance made the
            -- bubble tiny in first person and disagreed with the game's own
            -- emote bubble standing next to it.
            g.draw(image, quads[BUBBLE[tier]],
                   sx - 4 * scale, sy - 30 * scale, 0, scale, scale)
          end
        end
      end
      g.setColor(1, 1, 1, 1)
      pcall(g.setCanvas, prevCanvas)
      return canvas
    end,
  })

  mod.events:on("game.ready", attach)
  mod.events:on("map.entered", attach)
  attach()
end

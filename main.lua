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
-- Badges and TMs are NOT in a leader's talk script -- that only decides
-- which line they say.  The rewards live in their own table, keyed by the
-- same "OPP_CLASS#party" the map object already carries, which is how the
-- engine pays them out (OverworldState:checkVictoryRewards).
local Victories = require("data.scripts.victories")
-- only the guide screen needs this; the bubbles themselves are sprite draws
local Font = require("src.render.Font")

-- Tier 1: you receive something.
local GIVES = {
  give_item = true, give_pokemon = true, give_money = true,
  trade = true, heal_party = true,
  -- open_mart is NOT here.  Buying is not receiving, and a shop never runs
  -- out -- so the one clerk in the game who opens one (VIRIDIAN MART) wore
  -- a ! for the rest of the save, long after the only thing he actually
  -- hands over, OAK's PARCEL, was collected.  Healing stays: it is given,
  -- not sold.
  -- A dex entry is something you receive and cannot lose.  Every use of
  -- this in the game is an exhibit -- the Fuchsia zoo signs, and the
  -- gentleman on the S.S. ANNE who shows you a sleeping SNORLAX -- and each
  -- one was showing no bubble at all.
  mark_seen = true,
}

-- Tier 2: the world changes.  These write; tier 3 only reads.
local CHANGES = {
  set_flag = true, hide_object = true, show_object = true,
  replace_block = true, warp = true,
  -- All three battle verbs, not two.  A fight you can be put in is a change
  -- to the world whoever it is with -- the Voltorb that stops blocking the
  -- corridor, the rival who walks off, Oak's post-game rematch.
  static_battle = true, rival_battle = true, start_battle = true,
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
local CONDITIONS = { check_flag = true, check_item = true, check_dex_owned = true, dex_rating = true }

-- Commands whose result is decided in the moment rather than read off the
-- save: a prompt the player answers, and a gift that either lands or finds
-- the bag full.  The walk assumes the willing path.
local OPTIMISTIC = {
  ask = true, choice = true,
  give_item = true, give_pokemon = true, give_money = true, trade = true,
}

-- What a probe is given to spend.  Money is not progress -- open_mart is
-- already a gift whatever the wallet holds, so a Mart clerk shows a ! at
-- zero yen and a vending machine two floors up did not.  Nothing in the
-- game gates permanently on price (the bicycle wants a voucher, not
-- money), so a full wallet cannot invent a gift that is not there.
--
-- Finite, not math.huge: the Game Corner clerk prints the balance with %d
-- and the prize counter prints the coin total the same way, and inf throws
-- there -- before the purchase, so the gift behind it would be lost.
-- Coins sit between the dearest prize (7700, TM SUBSTITUTE) and the point
-- the coin case reports itself full (9990), so both counters work.
local PLENTY_MONEY, PLENTY_COINS = 999999, 9500

-- a script that jumps backwards could spin forever; no vanilla one does,
-- but this runs every time a flag changes and must not be able to hang
-- A fight you can be put in, whoever it is with.  The walk assumes you
-- win, for the same reason it assumes yes to an `ask`: the outcome is
-- decided at the time, not read off the save, and a player who wants the
-- thing takes that branch.  Without it `jump_if_false "end"` after a battle
-- -- "if you LOST, stop" -- was answered with whatever stale value the last
-- flag check left behind, so the walk took the losing path and never saw
-- what came after.  The CERULEAN thief's TM28 sat behind exactly that.
local BATTLE_VERBS = { start_battle = true, rival_battle = true,
                       static_battle = true }

local MAX_STEPS = 400

return function(mod)
  mod.options:define({
    -- The labels ARE the legend.  There is one toggle per bubble already, so
    -- naming each after what its symbol means turns the settings screen into
    -- the reminder -- on the very screen someone is already looking at to
    -- switch one off.  A row is a full-width box with the name on one line
    -- and the value beneath it, so there is room for about 17 characters.
    -- Named for the symbol they switch, and in the order the two exclamation
    -- marks belong together, so the faded one is read against the solid one.
    --
    -- No legend row here.  A row that steps through four sentences to say
    -- what a picture says at a glance was competing with the guide rather
    -- than helping it, and the guide can show the faded ! actually faded.
    -- SMILE is a word because the charmap has no smiley -- it carries
    -- ! ? ( ) [ ] : - and no more -- which is the whole argument for a
    -- screen that can draw the crop instead of naming it.
    { key = "gift", label = "! BUBBLE", type = "toggle", default = true },
    { key = "later", label = "FADED ! BUBBLE", type = "toggle", default = true },
    { key = "event", label = "? BUBBLE", type = "toggle", default = true },
    { key = "story", label = "SMILE BUBBLE", type = "toggle", default = true },
    -- How solid the come-back-later ! is, as a percent.  It has to read as
    -- subordinate to a real one without disappearing into the tilework --
    -- and where that line sits depends on the renderer you use and how
    -- bright the ground is, so it is a dial rather than a constant.  Read
    -- at draw time, so it moves as you turn it.
    -- No % in the label: the Game Boy charmap has no glyph for one, so it
    -- has been printing as a blank gap ever since this option existed.
    -- Off by default.  It reads the arena's tile heights rather than its
    -- depth buffer, which cannot be reached from a mod, so it is right about
    -- walls and roofs and wrong about the props built from rules.  An
    -- approximation nobody asked for should not be the default; one someone
    -- can switch on is fine.  Only does anything on the free-cam rungs.
    { key = "hide_walls", label = "HIDDEN BY WALLS", type = "toggle",
      default = false },
    -- 50, not 75.  The come-back-later ! has to read as subordinate to a
    -- real one at a glance, and three quarters opacity was close enough to
    -- solid that the two were hard to tell apart on the handheld.
    -- Off by default: the smile is the one bubble that costs nothing to
    -- ignore, and quietly hiding people because you walked past them once is
    -- a bigger change than it sounds.  On, a smile clears once you have heard
    -- what they have to say, and comes back the moment they say something
    -- new -- which is what makes it safe to hide them at all.
    { key = "heard", label = "CLEAR AFTER TALK", type = "toggle",
      default = false },
    { key = "later_fade", label = "LATER FADE", type = "number",
      default = 50, min = 20, max = 100, step = 5 },
  })

  -- forward declaration: classify needs to rebuild a closure, and the
  -- builder is defined further down with the rest of the map handling
  local programFor
  -- and the deep copy every probe is based on, which lives with it
  local sandbox
  -- rebuild asks whether a smile has already been heard; the roll and the
  -- stamping live down with the interaction handling that fills them
  local alreadyHeard
  -- and both of those ask what an NPC would say, which needs the walker and
  -- the probe, so it is defined with them further down
  local saidNow

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

  -- Most gifts announce they are spent by setting a flag the same script
  -- also checks, which giftOutlook reads.  Two do not, and each carries its
  -- own receipt instead:
  --
  --   mark_seen  -- nothing writes a flag when you read the CHANSEY sign,
  --                 but CHANSEY is in the POKeDEX afterwards and stays
  --                 there.  So the placard goes quiet once it has nothing
  --                 left to tell you, and never speaks up at all if you met
  --                 the species in the wild first.
  --   trade      -- the flag it sets is its own third argument, and nothing
  --                 was reading it: every finished in-game trade kept its !
  --                 for the rest of the save.
  local function givePending(verb, row, game)
    if verb == "mark_seen" then
      local dex = game and game.save and game.save.pokedex
      return not (dex and dex.seen and dex.seen[row[2]])
    end
    if verb == "trade" then
      return not condition("check_flag", row[3], game)
    end
    return true
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
    -- "end" is the engine's reserved halt, not a label anybody declares
    -- (ScriptRunner: `if jump == "end" then` stops the script).  Reading it
    -- as an unresolvable label and falling through to the next line walked
    -- straight into the branch the script had just decided to skip -- MOM's
    -- heal_party sits immediately after the `jump "end"` that ends the
    -- no-starter path, so a brand new save showed a ! over somebody with
    -- nothing to give, and OAK did the same after the rival battle.
    local HALT = #prog + 1
    local function target(v)
      if v == "end" then return HALT end
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

    -- Whether every branch taken is decided for good.  A flag that is true
    -- now stays true -- only three flags in the whole game are ever cleared,
    -- and all three belong to the FAN CLUB boast pair, who are a ? rather
    -- than a smile.  So a path chosen by true flags can never choose
    -- differently, and the dialogue at the end of it is the last thing this
    -- NPC will ever say.  A FALSE check is not settled: it can still flip.
    -- Nor is an item, which can be used or tossed.
    local settled = true
    -- The lines actually reached on this walk, in order.  Their IDENTIFIERS,
    -- never the rendered string: a rendered line moves for reasons that have
    -- nothing to do with progress -- a player name, a translation -- and a
    -- signature built on it would go stale for everybody at once.
    local said = {}
    local pc, last, best, steps = 1, false, reactive and 3 or nil, 0
    while pc <= #prog and steps < MAX_STEPS do
      steps = steps + 1
      local row = prog[pc]
      if type(row) ~= "table" then pc = pc + 1
      else
        local verb = row[1]
        local cond = condition(verb, row[2], game)
        if cond ~= nil then
          if verb == "check_item" or not cond then settled = false end
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
          if GIVES[verb] and givePending(verb, row, game) then best = 1 end
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
          if verb == "show_text" then said[#said + 1] = tostring(row[2]) end
          if BATTLE_VERBS[verb] then last = true end
          if GIVES[verb] then
            if givePending(verb, row, game) then best = 1 end
          elseif CHANGES[verb] and best ~= 1 then best = 2 end
          pc = pc + 1
        end
      end
    end
    return best, settled, table.concat(said, "|")
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
    local pending = false
    for _, row in ipairs(prog) do
      if type(row) == "table" then
        if GIVES[row[1]] then
          hasGive = true
          if givePending(row[1], row, game) then pending = true end
        end
        if row[1] == "set_flag" then sets[row[2]] = true end
        if row[1] == "check_flag" then checks[row[2]] = true end
      end
    end
    if not hasGive then return nil end
    -- every gift here was a dex entry and you already hold them all
    if not pending then return "done" end
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
  -- A dex that can be COUNTED, built from the live species registry.
  --
  -- The distinction that matters: a metatable answers a lookup but iterates
  -- to nothing, and the gates that decide a gift often count -- Oak's aides
  -- want 10, 30 and 50 species owned, and check_dex_owned walks pairs().  A
  -- faked dex therefore claimed to own everything and counted zero, so those
  -- three could never show anything.
  --
  -- Built from game.data.pokemon rather than a list in this file, so a mod
  -- that adds species is covered the moment it registers them, and so is a
  -- total conversion that replaces them all.
  local dexCache, dexCacheFor = nil, nil
  local function everySpecies(data)
    if dexCacheFor == data and dexCache then return dexCache end
    local owned = {}
    for id in pairs((data and data.pokemon) or {}) do
      if type(id) == "string" then owned[id] = true end
    end
    dexCacheFor, dexCache = data, { seen = owned, owned = owned }
    return dexCache
  end

  local function permissive(game)
    -- the rebuild's deep copy, never the live save: everything this does
    -- not name explicitly falls through, and a fall-through write at any
    -- depth would land in the player's own file
    local safe = (type(game) == "table" and game.__sandboxed) and game
                 or sandbox(game)
    local save = (safe and safe.save) or {}
    local dex = everySpecies(game and game.data)
    local fake = setmetatable({
      -- REAL flags, not a blanket false.  A flag is the receipt: it is how
      -- the game records what you have already collected.  Blanking them
      -- makes the best case re-offer everything you have ever claimed, and
      -- a closure's receipt never shows up in the synthesised rows, so
      -- alreadyClaimed cannot catch it -- both Mt Moon fossils kept a faded
      -- ! after being taken, and were only saved from showing it by the
      -- object being removed from the map.  Prerequisites live in items,
      -- dex counts and the world, and those are still faked generously.
      flags = {},
      -- ONE of everything, not ninety-nine.  Bag.add refuses when the
      -- quantity would pass 99 (src/inventory/Bag.lua), so a bag that
      -- answered 99 for every item made every gift bounce off "you have no
      -- room" -- the save meant to make gifts possible made them
      -- impossible, and Copycat's TM31 was unreachable because of it.
      -- Iterating empty also keeps Bag.slots at zero, so the bag is never
      -- full however many items are asked for.
      inventory = setmetatable({}, { __index = function() return 1 end }),
      pokedex = dex,
      money = PLENTY_MONEY,
      coins = PLENTY_COINS,
    }, { __index = function(_, key)
      local v = save[key]
      if type(v) == "number" then return PLENTY_MONEY end
      return v
    end })
    -- already safe: a synthetic save, and a stack that swallows pushes, so
    -- programFor leaves it alone rather than deep-copying the metatables away
    local noop = function() end
    return setmetatable({
      __sandboxed = true,
      -- marks this as the BEST-CASE probe, so the world it is handed is
      -- generous too -- see probeOw
      __permissive = true,
      save = fake,
      stack = { push = noop, pop = noop, top = noop, states = {} },
    }, { __index = game })
  end

  -- The world a probe hands a closure.
  --
  -- Ordinarily bare: a runner that records rows and nothing else, because a
  -- script reaching past it is doing world work the probe has no business
  -- answering.
  --
  -- The best-case probe is different.  It asks "if everything you could have
  -- done, you had done" -- and not every gate is in the save.  Both Mt Moon
  -- fossils sit behind superNerdBeaten(ow), which calls ow:npcByIndex and
  -- ow:trainerDefeated; against a bare stub the first of those throws, and
  -- the fossil behind it was never seen.  So the generous world answers yes
  -- to what a script can ask of it -- the same willing path the walker
  -- already takes for an `ask`.
  local function probeOw(onRows, generous, real)
    local ow = { runner = { run = onRows,
                            isRunning = function() return false end } }
    -- Read-through, write-nowhere.  For the TODAY probe the truthful answer
    -- matters: once the Super Nerd is beaten the fossil is takeable now, not
    -- later.  trainerDefeated keys on the npc's own id, so nothing but the
    -- real object gives a real answer -- but a shadow over it answers every
    -- read and swallows every write, so a script that turns an NPC to face
    -- it cannot turn one in the world.  Only the queries are forwarded;
    -- anything that would move or fight goes nowhere.
    if real then
      local function shade(n)
        if type(n) ~= "table" then return n end
        return setmetatable({}, { __index = n })
      end
      local function forward(name, wrap)
        local f = real[name]
        if type(f) ~= "function" then return end
        ow[name] = function(_, ...)
          local ok, v = pcall(f, real, ...)
          if not ok then return nil end
          return wrap and shade(v) or v
        end
      end
      forward("trainerDefeated")
      forward("objectVisible")
      forward("npcByIndex", true)
      forward("npcByName", true)
      -- deliberately no ow.npcs: handing over the live list would let a
      -- script write straight into the objects the world is drawing, and
      -- everything that needs one asks by index or by name
      ow.player = shade(real.player)
      -- Turning somebody to face you is answered by doing nothing, which is
      -- the whole point: the CERULEAN pair open with ow:facePlayer and threw
      -- before saying a word, so the mod could not tell what they say.
      ow.facePlayer = function() end
      ow.faceObject = function() end
      -- A FRESH list, never the live one.  Scripts guard on
      -- #ow.scriptMoves before walking somebody, and the PEWTER youngster
      -- appends to it as he escorts you to the gym.  An empty throwaway
      -- answers the guard truthfully for a world that is not mid-walk, and
      -- anything appended is discarded with it.
      ow.scriptMoves = {}
      ow.scriptMove = function() end
      return ow
    end
    if not generous then return ow end
    local stub = { id = "probe", px = 0, py = 0, cellX = 0, cellY = 0,
                   facing = "down", def = { index = 1, name = "PROBE" } }
    ow.npcs = { stub }
    ow.player = { px = 0, py = 0, cellX = 0, cellY = 0, facing = "down" }
    ow.trainerDefeated = function() return true end
    ow.npcByIndex = function() return stub end
    ow.npcByName = function() return stub end
    ow.objectVisible = function() return true end
    ow.facePlayer = function() end
    ow.faceObject = function() end
    ow.engageTrainer = function() end
    return ow
  end

  -- A gift is already claimed when a flag the giving path SETS is already
  -- true.  For a closure this is the only workable test: the flag it checks
  -- lives in Lua, not in the rows, so it never appears in either build --
  -- but the flag it would SET does, and that flag being set already is the
  -- receipt.  Without this Melanie kept a faded ! forever after handing the
  -- BULBASAUR over, which is the exact stale bubble this was meant to avoid.
  local function alreadyClaimed(prog, game)
    -- EVERY receipt, not any one of them.  An NPC can hold several separate
    -- trades: the CELADON MART roof girl swaps three drinks for three TMs,
    -- and taking the first one made her look spent while she still owed two.
    -- One outstanding receipt means there is something left here.
    local any, allClaimed = false, true
    for _, row in ipairs(prog or {}) do
      if type(row) == "table"
         and (row[1] == "set_flag" or row[1] == "receipt") then
        any = true
        if not condition("check_flag", row[2], game) then allClaimed = false end
      end
    end
    return any and allClaimed
  end

  -- A leader still owing a badge or a TM.  The badge lands with the win and
  -- the TM is a separate hand-over that retries when the bag was full at the
  -- time, so each has its own receipt and either one outstanding is a gift.
  local function victoryReward(def, game)
    if not (def and def.trainerClass) then return false end
    local e = Victories[def.trainerClass .. "#" .. tostring(def.trainerParty or 1)]
    if not e then return false end
    local flags = (game and game.save and game.save.flags) or {}
    if e.badge and not flags[e.flag] then return true end
    if e.item and not flags[e.gotFlag] then return true end
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
    local tier, settled = reachableTier(prog, game)
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
    -- Reacts to nothing any more: every branch that chose this line is
    -- decided for good, and there is no gift or change left down it.  The
    -- smile means "worth another word later", and there is no later.
    if tier == 3 and settled then return nil end
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
  -- Signs are not NPCs.  They live in map.signs and are answered by
  -- signAtCell, so nothing iterates them and nothing draws them -- which is
  -- why the six FUCHSIA dex placards, the only signs in the game that hand
  -- you anything, had no bubble at all.  Kept separate because they are
  -- keyed by cell rather than by id, and only the ! ones are kept: a smile
  -- on a sign can never clear, since the game writes down nothing when you
  -- read one.
  local signTiers = {}      -- "x,y" -> tier, current map only
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

  function sandbox(game)
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

  -- ------- the second probe: closures that give without saying so
  --
  -- Most builders hand their rows to ow.runner:run and the walk above reads
  -- them (Melanie's Bulbasaur).  A few never build rows at all -- they call
  -- Bag.add themselves, inside the "when the player closes this box"
  -- callback of a text box (Mr Psychic's TM29, Copycat's TM31, each of
  -- Oak's aides).  Those handed back nothing, so every one of them fell to
  -- the smile: a free HM reading exactly like a remark about the weather.
  --
  -- So when nothing was captured, run it again with a stack that CLOSES its
  -- boxes, and watch the bag.  What lands there is the gift, and a
  -- synthesised give_item row hands it to the same walker everything else
  -- goes through -- so "already claimed" and "not yet" keep working without
  -- a second set of rules.
  --
  -- Sealed by swapping `require` for the duration rather than stubbing a
  -- list of modules: the scripts require INSIDE the closure, so one gate
  -- catches every one of them, and a script that reaches for something new
  -- cannot leak past it.  Sound, music, battles and the follower all come
  -- back inert; the save is a copy; nothing here touches the real game.
  local function inertModule()
    return setmetatable({}, { __index = function() return function() end end })
  end

  -- ------- one probe's view of the save
  --
  -- Reads fall through to the rebuild's deep copy; writes land here and are
  -- thrown away with the view.  BOTH probes take their own, which is what
  -- makes the copy underneath a clean baseline to measure a gift against --
  -- when the row-building probe wrote straight into the copy, the gift it
  -- left behind was already in the "before" reading and the watcher saw no
  -- change at all.
  --
  -- Shadowed rather than copied, because the best-case save is built from
  -- metatables that answer every lookup and iterate to nothing: copying it
  -- hands back an empty bag and Copycat's TM31 looks unreachable.
  --
  -- The copy is the barrier that matters.  Everything this does not name --
  -- the object toggles a hide_object writes, the hiddenTaken a found item
  -- writes, the day care, the safari counters -- falls through to the copy,
  -- so a write at any depth lands there and never in the player's own file.
  -- The named ones are the ones a wrong answer would mis-tier: the bag and
  -- the party because a gift is measured against them, the flags and the
  -- POKeDEX because they are the receipts a script reads to decide whether
  -- it still owes you anything.
  local function probeSave(base)
    base = base or {}
    local save = setmetatable({}, { __index = base })
    save.inventory = setmetatable({}, { __index = base.inventory or {} })
    save.flags = setmetatable({}, { __index = base.flags or {} })
    -- The POKeDEX is COPIED, not shadowed.  check_dex_owned counts with
    -- pairs(), and a shadow iterates to nothing however many lookups it
    -- answers -- so each of OAK's aides, who want 10, 30 and 50 species,
    -- read a dex of zero and went quiet.  Small enough to copy: it is one
    -- boolean per species.
    local dex = base.pokedex or {}
    local seen, owned = {}, {}
    for k, v in pairs(dex.seen or {}) do seen[k] = v end
    for k, v in pairs(dex.owned or {}) do owned[k] = v end
    save.pokedex = { seen = seen, owned = owned }
    -- a shop is a shop whether or not you can afford it today
    save.money = PLENTY_MONEY
    save.coins = PLENTY_COINS

    -- The party is copied member by member, each behind its own shadow.
    -- Reading has to keep working -- the day care reads a level, a seller
    -- checks for room -- but a write must not reach the real POKeMON.
    -- give_pokemon calls Party.add(save.party, mon), which inserts straight
    -- into whatever list it is handed, and reading save.party through the
    -- shadow handed it the player's own: probing the MAGIKARP salesman put
    -- a MAGIKARP in the party, and probing the day care raised a real
    -- member to the level it was offering.
    local baseParty = base.party or {}
    local party = {}
    for i, mon in ipairs(baseParty) do
      party[i] = type(mon) == "table" and setmetatable({}, { __index = mon })
                 or mon
    end
    save.party = party
    -- and the boxes, where a gift lands when the party is full
    local baseBoxes = type(base.boxes) == "table" and base.boxes or nil
    local beforeStored = 0
    if baseBoxes then
      local boxes = {}
      for k, b in pairs(baseBoxes) do
        if type(b) == "table" then
          local copy = {}
          for i, mon in ipairs(b) do copy[i] = mon end
          beforeStored = beforeStored + #b
          boxes[k] = copy
        else
          boxes[k] = b
        end
      end
      save.boxes = boxes
    end
    return save, #baseParty, beforeStored
  end

  local function observedGift(entry, game, npc, realOw)
    if type(entry) ~= "function" then return nil end
    -- The NPC goes in shadowed, the same way npcByIndex hands one back.
    -- Scripts call methods ON it -- the CERULEAN SLOWBRO and ELECTRODE open
    -- with npc:facePlayer(ow.player) -- and the real object was going in
    -- unwrapped, so probing them turned them to face the player in the
    -- world.  Nothing reached the save, so the leak sweep never saw it.
    -- Reads pass through; writes land on the shadow and go out with it.
    if type(npc) == "table" then
      npc = setmetatable({}, { __index = npc })
    end
    local safeGame = (type(game) == "table" and game.__sandboxed) and game
                     or sandbox(game)
    local base = (safeGame and safeGame.save) or {}
    local save, baseParty, beforeStored = probeSave(base)
    local party = save.party
    -- what the bag held before it ran, read off the copy rather than the
    -- view, so a metatable's answer counts as the starting quantity
    local before = setmetatable({}, { __index = function(_, k)
      return (base.inventory or {})[k] or 0
    end })

    local depth = 0
    -- What it would say.  A closure pushes finished strings rather than text
    -- ids, so unlike the walker this is the rendered line -- good enough to
    -- notice when somebody starts saying something different, but it moves if
    -- the player's name is substituted into it.
    local heard = {}
    local probe = setmetatable({
      __sandboxed = true,
      save = save,
      stack = {
        push = function(_, box)
          depth = depth + 1
          -- a chain that will not end must not take the frame with it
          if depth > 48 then return end
          if type(box) ~= "table" then return end
          -- answer first, then close: a prompt's continuation IS the rest of
          -- the conversation, and the gift usually lives inside it
          if box.text ~= nil then heard[#heard + 1] = tostring(box.text) end
          if type(box.choice) == "function" then box.choice(true) end
          if type(box.onDone) == "function" then box.onDone() end
        end,
        pop = function() end, top = function() end, states = {},
      },
    }, { __index = game })

    -- A box that also carries the answer to a question.  A yes/no prompt is
    -- a TextBox with a `choice` callback (see the `ask` helper the scripts
    -- share), and a probe that only closes boxes never answers it -- which
    -- is why each of Oak's aides, who open by asking whether you have caught
    -- enough, gave up nothing.  It answers YES, the same willing path the
    -- walker already takes for an `ask` row, so the two agree.
    local FakeTextBox = { new = function(_, text, done, opts)
      local choice = type(opts) == "table" and opts.choice or nil
      return { __probe = true, text = text, onDone = done, choice = choice }
    end }
    -- A menu is a question with more than two answers.  The probe already
    -- says yes to a yes/no; a list it cannot answer just sits there
    -- unpicked, which is why the vending machines and the Game Corner prize
    -- counters -- shops, all six -- looked like they did nothing at all.
    -- It takes the first row that carries a value, since the trailing
    -- "NO THANKS" exit carries none, and one purchase is enough to prove
    -- there is something to be had here.
    local FakeListMenu = { new = function(_, _, items, opts)
      -- ListMenu calls onChoose(item, self), and callers use that second
      -- argument -- the CELADON MART roof girl opens with `list:close()`.
      -- Passing only the item left it nil and the whole chain threw before
      -- her TM was ever handed over, so she read as small talk.  The stand-in
      -- hands itself across and answers close() like the real one.
      local menu
      menu = { __probe = true, close = function() end, onDone = function()
        local onChoose = type(opts) == "table" and opts.onChoose
        if type(onChoose) ~= "function" then return end
        -- EVERY option, not just the first.  A menu can hold several
        -- different trades and only some may still be open: the CELADON
        -- MART roof girl swaps three drinks for three TMs, and picking only
        -- FRESH WATER made her read as spent the moment TM13 was claimed,
        -- while she still owed two more.  Taking each in turn lets the
        -- watcher see whichever one is still live.
        local tried = 0
        for _, item in ipairs(type(items) == "table" and items or {}) do
          if type(item) == "table" and item.value ~= nil then
            tried = tried + 1
            if tried > 8 then return end
            pcall(onChoose, item, menu)
          end
        end
      end }
      return menu
    end }
    -- the same willing answer the TextBox choice already gives
    local FakeChoiceBox = { new = function(_, onChoose)
      return { __probe = true, onDone = function()
        if type(onChoose) == "function" then onChoose(true) end
      end }
    end }
    local SEALED = {
      ["src.render.TextBox"] = FakeTextBox,
      ["src.ui.ListMenu"] = FakeListMenu,
      ["src.ui.ChoiceBox"] = FakeChoiceBox,
      ["src.core.Sound"] = inertModule(),
      ["src.core.Music"] = inertModule(),
      ["src.battle.BattleState"] = inertModule(),
      ["src.world.PikachuFollower"] = inertModule(),
    }
    local realRequire = require
    _G.require = function(name) return SEALED[name] or realRequire(name) end
    -- The result is deliberately ignored.  A gift is observed the moment
    -- Bag.add writes it, and what the closure does AFTERWARDS is usually
    -- world work the stub cannot answer -- the museum scientist hands over
    -- the OLD AMBER and then hides the exhibit, which needs a real map, so
    -- it throws.  Discarding the run on that error threw away a gift that
    -- had already happened, and the giver came out a smile.  An error
    -- cannot un-give what the bag is already holding.
    -- The runner's rows count as things said.  Some closures never push a
    -- box at all -- the POKeMON TOWER rival hands his whole scene to
    -- ow.runner:run -- and throwing the rows away meant the mod could not
    -- tell what he says, so his smile could never clear.
    pcall(entry, probe,
          probeOw(function(_, rows)
            for _, r in ipairs(type(rows) == "table" and rows or {}) do
              if type(r) == "table" and r[1] == "show_text" then
                heard[#heard + 1] = tostring(r[2])
              end
            end
          end, game and game.__permissive, realOw),
          npc or {}, function() end)
    _G.require = realRequire

    -- only what the shadow itself holds: pairs() on it lists exactly the
    -- items the closure wrote, whatever the save underneath answers
    local rows = nil
    for item, count in pairs(save.inventory) do
      if type(count) == "number" and count > (before[item] or 0) then
        rows = rows or {}
        rows[#rows + 1] = { "give_item", item, 1 }
      end
    end

    -- A POKeMON is a gift too, and it never touches the bag.  The MAGIKARP
    -- salesman and the GAME CORNER's two mon counters hand one over, and
    -- watching only the inventory made all three look like they did nothing.
    local storedNow = 0
    for _, b in pairs(save.boxes or {}) do
      if type(b) == "table" then storedNow = storedNow + #b end
    end
    -- Flags the closure WROTE.  The shadow starts empty with __index to the
    -- base, so pairs() lists exactly what it set and nothing inherited.
    -- Without these a closure's receipt never reached alreadyClaimed.
    for name, value in pairs(save.flags) do
      if value then
        rows = rows or {}
        -- "receipt", not "set_flag": alreadyClaimed reads it, the tier walker
        -- does not.  Emitting set_flag made every flag-writing closure look
        -- like a world change and promoted the museum ticket clerk to a ?.
        rows[#rows + 1] = { "receipt", name }
      end
    end

    local gained = (#party - baseParty) + (storedNow - beforeStored)
    if gained > 0 then
      local last = party[#party]
      rows = rows or {}
      rows[#rows + 1] = { "give_pokemon",
                          (type(last) == "table" and last.species) or "?" }
    end
    -- A receipt on its own is not a finding.  It rides along with a gift so
    -- alreadyClaimed can see what the closure would set; without one there is
    -- nothing here, and returning rows anyway short-circuited the
    -- unreadable-closure fallback and silenced the museum ticket clerk.
    if rows and not hasGive(rows) then return nil, table.concat(heard, "|") end
    return rows, table.concat(heard, "|")
  end

  function programFor(prog, game, npc, realOw)
    if type(prog) == "table" then return prog end
    if type(prog) ~= "function" then return nil end
    -- Shadowed here as well as in observedGift: this runs the closure too,
    -- and a script that calls a method ON the npc -- npc:facePlayer -- would
    -- otherwise turn the real one while it was being classified.
    if type(npc) == "table" then
      npc = setmetatable({}, { __index = npc })
    end
    local captured
    -- a caller may hand in an already-safe game (the best-case probe);
    -- copying it again would flatten the metatables it is built from
    local outer = (type(game) == "table" and game.__sandboxed) and game
                  or sandbox(game)
    -- its own view, so what it writes cannot be mistaken for what was
    -- already there when the watcher below takes its reading
    local safe = setmetatable({ __sandboxed = true,
                                __permissive = outer and outer.__permissive,
                                save = probeSave(outer and outer.save),
                                stack = { push = function() end,
                                          pop = function() end,
                                          top = function() end, states = {} } },
                              { __index = outer })
    -- the best-case probe wants a generous world, not the real one
    local stub = probeOw(function(_, rows) captured = rows end,
                         safe.__permissive,
                         not safe.__permissive and realOw or nil)
    -- Same reasoning as observedGift: rows are complete when they reach
    -- runner:run, and a throw further down does not unbuild them.
    pcall(prog, safe, stub, npc, function() end)
    if type(captured) == "table" then return captured end
    -- built no rows: it may still be giving something directly
    return observedGift(prog, game, npc, not safe.__permissive and realOw or nil)
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
      -- A trainer already tells you what they are: they see you, they show
      -- their own "!", and they fight.  Nothing this mod can add to that is
      -- news.  They were reaching the unreadable-closure fallback and coming
      -- out as smiles -- every gym leader and all four of the Elite Four.
      --
      -- Read off the map object rather than a list of names: the extractor
      -- writes trainerClass on anything that battles you, so a trainer added
      -- by another mod is covered without this mod knowing it exists.
      --
      -- A gift still wins, though.  The NUGGET on Route 24 is handed over by
      -- someone who then fights you, and hiding that would cost the player
      -- the thing the bubble exists for.  So a trainer loses the smile and
      -- the "?", never the "!".
      -- trainerClass, and nothing cleverer.  It is the engine's OWN
      -- announcement: an NPC carrying one gets sight-lines and shows its
      -- own "!" when it spots you, so a second marker is noise.  A scripted
      -- battle announces nothing at all -- Oak's post-game rematch and the
      -- Fan Club chief have no trainer header, and the only window in which
      -- either is worth crossing the map for is the one a broader rule
      -- silenced.  Do not duplicate what the engine says; do not stay quiet
      -- about what it does not.
      local isTrainer = npc.def and npc.def.trainerClass ~= nil
      local prog = programFor(key and talk[key], game, npc, ow)
      local entry = key and talk[key]
      -- A leader is not announced by the engine the way a route trainer is:
      -- sight engagement skips anyone carrying a talk script
      -- (OverworldController, CheckFightingMapTrainers), and every leader
      -- has one.  So nothing tells the player a badge and a TM are sitting
      -- there -- and their scripts cannot say so either, since the rewards
      -- are paid from the victories table rather than from any row.
      if victoryReward(npc.def, game) then
        tiers[npc.id] = 1
      elseif prog then
        local tier = classify(prog, game, entry)
        -- a trainer keeps a gift, loses everything softer
        if isTrainer and tier ~= 1 and tier ~= 4 then tier = nil end
        -- and a smile you have already heard is not news until it changes
        if tier == 3 and mod.options:get("heard") == true
           and alreadyHeard(map.id, npc, entry, game, ow) then
          tier = nil
        end
        tiers[npc.id] = tier
      elseif type(entry) == "function" and not isTrainer then
        -- Nothing to give TODAY -- but a closure gated on something you have
        -- not done yet gives nothing either, and those are exactly the ones
        -- worth marking.  Copycat wants the POKe DOLL; each of Oak's aides
        -- wants 10, 30 and 50 species.  Ask once more with the prerequisites
        -- met and nothing claimed, and a real "come back later" falls out.
        local best = programFor(entry, permissive(game), npc)
        if best and hasGive(best) and alreadyClaimed(best, game) then
          -- spent: it handed its gift over and set its own receipt, and the
          -- receipt is already true.  Nothing left to say.
          tiers[npc.id] = nil
        elseif best and hasGive(best) then
          tiers[npc.id] = 4
        else
          -- A closure we cannot read is still a signal.  Ordinary NPCs have
          -- no script at all; a hand-written one exists precisely because
          -- the interaction did not fit the command rows -- the bike shop
          -- clerk, Misty, the badge house.  So it is not "unknown, show
          -- nothing", it is "something bespoke happens here": the smile.
          opaque[map.id .. "/" .. tostring(key)] = true
          if mod.options:get("heard") == true
             and alreadyHeard(map.id, npc, entry, game, ow) then
            tiers[npc.id] = nil
          else
            tiers[npc.id] = 3
          end
        end
      end
    end

    signTiers = {}
    for _, sign in ipairs((map.def and map.def.signs) or {}) do
      local entry = sign.text and talk[sign.text]
      if entry ~= nil then
        local prog = programFor(entry, game, nil, ow)
        local tier = prog and classify(prog, game, entry) or nil
        -- only a gift: see above
        if tier == 1 then
          signTiers[sign.x .. "," .. sign.y] = tier
        end
      end
    end
  end

  local function ensureFresh()
    if dirty then rebuild() end
  end

  local function markDirty() dirty = true end

  -- A script that writes save.flags itself never fires flag.changed: that
  -- event comes from Flags.set, and the shared gift() helper assigns
  -- `game.save.flags[opts.flag] = true` straight out.  So the ROUTE 1
  -- POTION man kept his ! after handing it over -- nothing told the mod
  -- anything had happened, and the bubble only cleared when the map change
  -- forced a rebuild.
  --
  -- Notice the A press instead.  It cannot be acted on at the time: when
  -- the press lands the conversation has not run yet, and the flag is
  -- written when the last box closes.  So it is remembered, and settled
  -- A short stamp of a line, so the save holds a number per NPC rather than a
  -- paragraph.  Plain arithmetic rather than a bitwise hash: LuaJIT is 5.1
  -- and has no `~`.  The words are only ever compared for equality, and the
  -- length is folded in so two different lines of the same characters cannot
  -- collide as easily.
  local function stamp(text)
    local h = 5381
    for i = 1, #text do
      h = (h * 33 + text:byte(i)) % 4294967296
    end
    return h * 64 + (#text % 64)
  end

  local function heardKey(mapId, npc)
    local text = npc and npc.def and npc.def.text
    if not (mapId and text) then return nil end
    return mapId .. "/" .. text
  end

  -- Recorded WHATEVER the toggle says, the way battle_dex records a species
  -- it has met: switching the toggle on later should not replay every
  -- conversation you have already had.
  --
  -- Taken after the conversation, not before -- if they handed something over
  -- they are now saying something different, and that new line is what you
  -- have heard.  Which is also why beating BROCK brings the gym guide's smile
  -- back: his line moves, and the stamp no longer matches.
  local function rememberHeard(npc)
    local game = mod.world and mod.world.game
    local ow = mod.world and mod.world:overworld()
    local map = ow and ow.map
    local key = map and heardKey(map.id, npc)
    if not (game and key and mod.save) then return end
    local view = MapScripts.get(map.id)
    local entry = view and view.talk and view.talk[npc.def.text]
    if entry == nil then return end
    local ok, said = pcall(saidNow, entry, game, npc, ow)
    if not (ok and type(said) == "string" and said ~= "") then return end

    -- Ask twice more, with nothing changed in between.  Somebody whose line
    -- is picked at random answers differently for no reason -- the CERULEAN
    -- SLOWBRO, ELECTRODE and COOLTRAINER roll one of four, and the SS ANNE
    -- chef rolls his main course -- and stamping that means the smile comes
    -- back every time the roll lands elsewhere, which reads as the bubble
    -- flickering.  Two matching answers is not proof of anything, but two
    -- DIFFERENT answers is proof they vary on their own, and then any line
    -- from them counts as heard.
    local varies = false
    for _ = 1, 2 do
      local ok2, again = pcall(saidNow, entry, game, npc, ow)
      if ok2 and type(again) == "string" and again ~= "" and again ~= said then
        varies = true
        break
      end
    end

    local roll = mod.save:get("heard")
    if type(roll) ~= "table" then roll = {} end
    -- Every line heard, not just the last.  The SS ANNE chef rolls his main
    -- course at random each time you ask, so one stamp could never match on
    -- the next look and his smile would have sat there for good.  Collect
    -- them and he goes quiet once you have heard the lot.
    local seen = roll[key]
    if seen == "varies" then return end          -- already known to wander
    if type(seen) ~= "table" then seen = {} end
    if varies then
      roll[key] = "varies"
      mod.save:set("heard", roll)
      return
    end
    local mark = stamp(said)
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    -- bounded: a line carrying something genuinely unbounded -- a number, a
    -- name -- must not grow the save without limit.  Past the cap it stops
    -- collecting, and that NPC simply keeps a smile.
    if seen[mark] == nil and n < 8 then seen[mark] = true end
    roll[key] = seen
    mod.save:set("heard", roll)
  end

  -- Only asked about an NPC already in the roll, so an NPC you have never
  -- spoken to costs nothing -- for a closure this would otherwise mean a
  -- third probe run on every rebuild.
  function alreadyHeard(mapId, npc, entry, game, ow)
    local roll = mod.save and mod.save:get("heard")
    if type(roll) ~= "table" then return false end
    local key = heardKey(mapId, npc)
    local seen = key and roll[key]
    -- heard once is heard, for somebody who never says the same thing twice
    if seen == "varies" then return true end
    if type(seen) ~= "table" then return false end
    local ok, said = pcall(saidNow, entry, game, npc, ow)
    if not (ok and type(said) == "string" and said ~= "") then return false end
    return seen[stamp(said)] == true
  end

  -- once the world has the player back -- no box on the stack, no script
  -- running, input unlocked.
  local pendingTalk, pendingNpc = false, nil
  local function settle()
    if not pendingTalk then return end
    local game = mod.world and mod.world.game
    local ow = mod.world and mod.world:overworld()
    if not (game and ow and game.stack) then return end
    if game.stack.top and game.stack:top() ~= ow then return end
    local player = ow.player
    if player and player.inputLocked then return end
    local runner = ow.runner
    if runner and runner.isRunning and runner:isRunning() then return end
    pendingTalk = false
    local npc = pendingNpc
    pendingNpc = nil
    if npc then pcall(rememberHeard, npc) end
    markDirty()
  end

  mod.events:on("world.interacted", function(ev)
    pendingTalk = true
    pendingNpc = (type(ev) == "table" and ev.kind == "npc") and ev.target or nil
  end)
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
    settle()
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

  -- The same offsets NPC.draw uses, from the cell rather than from a moving
  -- sprite: a sign never walks, so its pixel position is just its cell.
  local function drawSigns(camX, camY)
    settle()
    if dirty then rebuild() end
    if not next(signTiers) then return end
    local image = art(mod.world and mod.world.game)
    if not (image and quads) then return end
    local g = love.graphics
    local r, gg, b, a = g.getColor()
    for cell, tier in pairs(signTiers) do
      if enabled(tier) and quads[BUBBLE[tier]] then
        local sx, sy = cell:match("^(-?%d+),(-?%d+)$")
        if sx then
          g.setColor(1, 1, 1, alphaFor(tier))
          g.draw(image, quads[BUBBLE[tier]],
                 math.floor(tonumber(sx) * 16 - camX) + 4,
                 math.floor(tonumber(sy) * 16 - camY) - 14)
        end
      end
    end
    g.setColor(r, gg, b, a)
  end

  mod.exports.drawSigns = drawSigns
  mod.exports.signTiers = function() return signTiers end
  -- What this NPC would say if you spoke to them right now, as a string that
  -- changes when the words change and not otherwise.  Readable scripts answer
  -- from the walk; a closure has to be run, and the probe already sees every
  -- line it pushes -- it was throwing them away.
  function saidNow(entry, game, npc, realOw)
    if type(entry) == "table" then
      local _, _, said = reachableTier(entry, game)
      return said
    end
    if type(entry) ~= "function" then return nil end
    local _, heard = observedGift(entry, game, npc, realOw)
    return heard
  end

  mod.exports.saidNow = saidNow
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

    -- Signs get no draw call of their own, so there is nothing per-sign to
    -- wrap.  drawWorld is the flat-mode pass that draws the entities, and it
    -- works in the same manual camera offset the sprites do -- no transform
    -- is pushed -- so the placards land in the same space right after it.
    local OverworldController = require("src.world.OverworldController")
    local State = OverworldController.OverworldState or OverworldController
    if type(State) == "table" and type(State.drawWorld) == "function" then
      local baseWorld = State.drawWorld
      State.drawWorld = function(self, ...)
        local result = baseWorld(self, ...)
        local cam = self.camera
        if cam then
          local ok, err = pcall(drawSigns, cam.x or 0, cam.y or 0)
          if not ok then mod.log:error("sign draw failed: %s", tostring(err)) end
        end
        return result
      end
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

  local voxel, aaLib, fpLib, tileShape, voxelTried = nil, nil, nil, nil, false

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
    -- Held as a module, not a value: which rung the player is on changes
    -- while the game runs.
    local ok3, fp = pcall(lib.require, "FirstPerson")
    if ok3 and type(fp) == "table" and type(fp.engaged) == "function" then
      fpLib = fp
    end
    -- The arena's own per-tile height field, which is what its mesher builds
    -- the visible world from: wall 16, roof 28, tree 16, canopy 32, cliff 32,
    -- fence 10, ledge 6.  Standing in for a depth test we cannot have -- the
    -- depth buffer exists only while the arena's pass is open and no pipeline
    -- hook runs there.  Absent on any other arena, and then nothing hides.
    local ok4, ts = pcall(lib.require, "TileShape")
    if ok4 and type(ts) == "table" and type(ts.forMap) == "function"
      and type(ts.at) == "function" then
      tileShape = ts
    end
    return voxel, aaLib
  end

  -- ------- what stands between the camera and an NPC
  --
  -- The arena leaves NPCs to honest occlusion -- only the player gets a
  -- see-through silhouette -- so a bubble over a roof whose NPC is correctly
  -- hidden is wrong.  This walks the line from the eye to the NPC's head and
  -- asks the height field whether anything along it is taller than the line
  -- is at that point.
  --
  -- Approximate by construction: props the arena builds from rules (shelves,
  -- figures, cylinders) are not in the tile heights, so it will disagree in
  -- places.  Every uncertainty therefore fails OPEN -- no library, no map, a
  -- throw, anything -- because a bubble that shows when it should not is the
  -- lesser fault of the two, and the one this mod already had.
  local TILE = 8            -- world pixels per tile (a cell is two)
  local STEP = 4            -- half a tile: cannot step over a wall
  local MAX_STEPS = 160

  local function heightAt(map, shapes, tx, ty)
    local ok, tile = pcall(map.tileAt, map, tx, ty)
    if not (ok and tile) then return 0 end
    local got, s = pcall(tileShape.at, map, shapes, tile, tx, ty)
    if not (got and type(s) == "table") then return 0 end
    return tonumber(s.h) or 0
  end

  local function sightBlocked(v, ow, npc)
    if not tileShape then return false end
    local map = ow and ow.map
    if not (map and type(map.tileAt) == "function") then return false end
    local eye = v.eye
    if type(eye) ~= "table" or not (eye[1] and eye[2] and eye[3]) then
      return false
    end
    local okS, shapes = pcall(tileShape.forMap, map)
    if not (okS and type(shapes) == "table") then return false end

    -- the head, not the bubble: then it hides exactly when his sprite does
    local hx, hy, hz = npc.px + 8, 16, npc.py + 16
    local dx, dy, dz = hx - eye[1], hy - eye[2], hz - eye[3]
    local dist = math.sqrt(dx * dx + dz * dz)
    if not (dist > TILE) then return false end
    local steps = math.min(MAX_STEPS, math.floor(dist / STEP))
    if steps < 2 then return false end

    local lastTx, lastTy = nil, nil
    -- open interval: the camera's own tile and the NPC's own tile are the
    -- ends of the line, never obstacles on it
    for i = 1, steps - 1 do
      local t = i / steps
      local x, y, z = eye[1] + dx * t, eye[2] + dy * t, eye[3] + dz * t
      local tx, ty = math.floor(x / TILE), math.floor(z / TILE)
      if tx ~= lastTx or ty ~= lastTy then
        lastTx, lastTy = tx, ty
        if heightAt(map, shapes, tx, ty) > y then return true end
      end
    end
    return false
  end

  -- Whether the camera stands with the player rather than orbiting above.
  -- On the free-cam rungs depth varies enormously across the screen -- an
  -- NPC a step away is ten times the size of one across the room -- which
  -- is the case the engine's flat scale was never meant to cover.
  local function freeCam()
    if not (fpLib and type(fpLib.engaged) == "function") then return false end
    local ok, on = pcall(fpLib.engaged)
    return ok and on == true
  end

  -- Canvas pixels per world pixel AT THIS NPC'S DEPTH, measured rather than
  -- assumed: project the feet and a point one tile above them and see how
  -- far apart they land.  That is the same magnification the arena drew the
  -- NPC's own sprite at, so a bubble sized and offset by it keeps pace with
  -- the NPC instead of staying screen-sized while he fills the view.
  --
  -- Not derived from project()'s third return.  That is focusW/cw, and in
  -- first person the focus point IS the player, so focusW collapses towards
  -- zero and the ratio takes every bubble down with it -- which is why
  -- scaling by it made them smaller as you approached, not larger.
  local function pixelsPerWorldPixel(v, npc, aaFactor, flat)
    local _, fy = v.project(npc.px + 8, 0, npc.py + 16)
    local _, hy = v.project(npc.px + 8, 16, npc.py + 16)
    if not (fy and hy) then return flat end
    local pps = math.abs(fy - hy) / 16 / (aaFactor > 0 and aaFactor or 1)
    -- a degenerate near-plane reading must not produce an invisible or
    -- screen-filling bubble
    if not (pps > 0) then return flat end
    return math.max(flat * 0.25, math.min(flat * 16, pps))
  end

  -- ------- keeping the pass out of START > OPTIONS
  --
  -- Drawing over an arena's world pass means registering a pipeline, and the
  -- options menu lists every pipeline there is (Pipelines.rows builds a row
  -- per entry, unfiltered).  But this is not a display mode anyone chooses
  -- between: it is how this mod draws when something else owns the world,
  -- and the only thing switching it off achieves is bubbles disappearing in
  -- 3D.  Having the mod enabled is already that toggle.
  --
  -- So the row is dropped on its way to the menu.  OptionsMenu passes its
  -- finished list through ui.options.rows and takes back whatever comes out,
  -- which is the sanctioned way to change that list.
  local PIPELINE_ID = "npc_bubbles_overlay"
  local ROW_ID = "pipeline:" .. PIPELINE_ID

  -- ------- the guide
  --
  -- Words can only ever say "SMILE".  The question people actually have is
  -- "what did the faded one look like again?", and the honest answer to that
  -- is the picture -- which the mod is already holding, since it draws these
  -- four crops over NPCs all day.
  local GUIDE_SCREEN = "npc_bubbles_guide"
  -- Wrapped, so the words are not rationed to whatever fits one line.  The
  -- box's inside edge is x=152 and the text starts at x=40, which is 14
  -- characters -- "SAYS MORE LATER" was 15 and ran through the border.
  local GUIDE_COLS = 14
  -- The wording from the mod's own description, rather than a shorter
  -- paraphrase invented to fit one line.  Sentence case, like the POKeDEX
  -- entries: this is prose, and the game only shouts at menu labels.
  --
  -- Ordered the way the two exclamation marks belong together, so the faded
  -- one is read against the solid one rather than three rows away.
  local GUIDE = {
    { tier = 1, text = "Something for you right now" },
    { tier = 4, text = "Something here later" },
    { tier = 2, text = "Talking to them changes the world" },
    { tier = 3, text = "They'll say new things as you progress" },
  }

  local function wrapWords(text, cols)
    local lines, line = {}, ""
    for word in tostring(text):gmatch("%S+") do
      local try = line == "" and word or (line .. " " .. word)
      if #try <= cols then
        line = try
      else
        if line ~= "" then lines[#lines + 1] = line end
        line = word
      end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
  end

  local Guide = {}
  Guide.__index = Guide
  Guide.isOpaque = true

  -- The box border sits on the outer tile, so the inside is x 8..152 and
  -- y 8..136.  Everything here is measured off that rather than the screen,
  -- which is how the first cut printed through both the right and the
  -- bottom edge.
  local G_TOP, G_BOTTOM = 38, 118    -- the scrolling window
  local G_ROW = 10                   -- a line of text
  local G_ENTRY_GAP = 6

  -- Without this the screen inherits whatever palette the thing underneath
  -- it left set (Game.lua walks DOWN the stack for the first screen that
  -- answers), which is why the guide wore the overworld's colours.  The
  -- generic whole-screen palette is what the engine's own list menus use.
  function Guide:sgbPalettes(game)
    local ok, P = pcall(require, "src.render.PaletteFX")
    if not (ok and P and P.wholeNamed) then return nil end
    local got, pal = pcall(P.wholeNamed, game.data, "MEWMON")
    return got and pal or nil
  end

  function Guide.new(game)
    local self = setmetatable({ game = game, scroll = 0 }, Guide)
    -- laid out once: each entry is its bubble and however many lines its
    -- description wraps to
    self.entries = {}
    local y = 0
    for _, row in ipairs(GUIDE) do
      local lines = wrapWords(row.text, GUIDE_COLS)
      local height = math.max(16, #lines * G_ROW)
      self.entries[#self.entries + 1] =
        { tier = row.tier, lines = lines, y = y, height = height }
      y = y + height + G_ENTRY_GAP
    end
    self.contentHeight = math.max(0, y - G_ENTRY_GAP)
    return self
  end

  function Guide:maxScroll()
    return math.max(0, self.contentHeight - (G_BOTTOM - G_TOP))
  end

  function Guide:update()
    local input = self.game and self.game.input
    if not input then return end
    if input:wasPressed("down") then
      self.scroll = math.min(self:maxScroll(), self.scroll + G_ROW)
      return
    elseif input:wasPressed("up") then
      self.scroll = math.max(0, self.scroll - G_ROW)
      return
    end
    -- any of the three ways out of a page in this game
    if input:wasPressed("b") or input:wasPressed("a")
      or input:wasPressed("start") then
      self.game.stack:pop()
    end
  end

  function Guide:draw()
    local g = love.graphics
    g.setColor(1, 1, 1, 1)
    g.rectangle("fill", 0, 0, 160, 144)
    g.setColor(0, 0, 0, 1)
    Font.drawBox(0, 0, 20, 18)
    Font.draw("NPC BUBBLES", 16, 16)
    g.rectangle("fill", 8, 30, 144, 1)

    local image = art(self.game)
    -- clipped to the window, so a half-scrolled entry is cut cleanly at the
    -- edge instead of drawing over the border
    g.setScissor(8, G_TOP, 144, G_BOTTOM - G_TOP)
    for _, entry in ipairs(self.entries) do
      local y = G_TOP + entry.y - self.scroll
      if y < G_BOTTOM and y + entry.height > G_TOP then
        -- the real crop, at the size it is drawn in the world, so the faded
        -- one is recognisable as the faded one
        if image and quads and quads[BUBBLE[entry.tier]] then
          g.setColor(1, 1, 1, alphaFor(entry.tier))
          g.draw(image, quads[BUBBLE[entry.tier]], 16, y)
          -- Exempt from the SGB recolour, the way DexEntryMenu exempts a
          -- full-colour pic.  A 75%-alpha blend lands BETWEEN the four DMG
          -- shades, and the palette pass has to round it to one of them --
          -- which is how the faded ! came out purple instead of faded.
          -- Marked, the blended pixels survive as themselves and it reads
          -- as what it is.
          pcall(function()
            require("src.render.PaletteFX").markTrueColor(16, y, 16, 16)
          end)
          g.setColor(0, 0, 0, 1)
        end
        for i, line in ipairs(entry.lines) do
          Font.draw(line, 40, y + (i - 1) * G_ROW)
        end
      end
    end
    g.setScissor()

    -- the arrows are the game's own, and only appear when there is more
    if self:maxScroll() > 0 then
      if self.scroll > 0 then Font.draw("▲", 144, G_TOP) end
      if self.scroll < self:maxScroll() then
        Font.draw("▼", 144, G_BOTTOM - 8)
      end
    end

    -- inside the border, not through it: the bottom edge is y=136
    Font.draw("B TO GO BACK", 16, 122)
    g.setColor(1, 1, 1, 1)
  end

  mod.content.screens:register(GUIDE_SCREEN, { new = Guide.new })

  mod.hooks:wrap("ui.options.rows", function(nextFn, game, rows)
    local out = nextFn(game, rows)
    if type(out) ~= "table" then return out end
    local kept = {}
    for _, row in ipairs(out) do
      if row.id ~= ROW_ID then kept[#kept + 1] = row end
    end
    -- the same hook that hides the pipeline row adds the guide: one entry in
    -- START > OPTIONS, opened with A
    kept[#kept + 1] = {
      id = "npc_bubbles_guide",
      label = "NPC BUBBLES",
      value = function() return "GUIDE" end,
      activate = function(g)
        local ok, Screens = pcall(require, "src.ui.Screens")
        if ok and Screens and Screens.push then
          pcall(Screens.push, g, GUIDE_SCREEN)
        end
      end,
    }
    return kept
  end)

  -- A player who switched it off before the row went away would be left with
  -- no bubbles in 3D and no way back, so the level is asserted once the save
  -- is up.  This is not fighting a live choice -- there is no longer a
  -- control to make one with.
  local function forceOn()
    local ok, Pipelines = pcall(require, "src.render.Pipelines")
    if not (ok and type(Pipelines) == "table"
      and type(Pipelines.setLevel) == "function") then return end
    if (Pipelines.level and Pipelines.level(PIPELINE_ID) or 0) > 0 then return end
    pcall(Pipelines.setLevel, PIPELINE_ID, 1)
  end
  mod.events:on("save.loaded", forceOn)
  mod.events:on("save.created", forceOn)

  mod.content.render_pipelines:register(PIPELINE_ID, {
    label = "NPC BUBBLES 3D",
    -- on unless the player turns it off; without this a pipeline restores
    -- to level 0 and the pass would silently never run
    default = 1,
    worldPresent = function(canvas, ctx)
      local v, aa = voxel3D()
      if not (v and canvas and ctx and tonumber(ctx.vw) and ctx.vw > 0) then
        return canvas
      end
      settle()
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
      -- one rung check per frame, not one per NPC
      local perspective = freeCam()
      -- Only where the camera stands with the player -- orbiting above it
      -- looks over walls on purpose -- and only when asked for.
      local hideBehind = perspective
        and mod.options:get("hide_walls") == true

      for _, npc in ipairs(ow.npcs or {}) do
        local tier = tiers[npc.id]
        if tier and on[tier] and quads[BUBBLE[tier]]
          and not (hideBehind and sightBlocked(v, ow, npc)) then
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
            sx, sy = sx / aaFactor, sy / aaFactor
            -- Orbiting above, every NPC is about the same distance away, so
            -- one flat number is right and is what the engine uses for its
            -- own field FX: "an effect keeps its crisp authored size and
            -- only its anchor moves."
            --
            -- Standing among them, that stops being true: one step away an
            -- NPC is ten times the size of one across the room, and a
            -- screen-sized bubble offset a screen-sized 30 pixels lands by
            -- his feet rather than over his head.  So on the free-cam rungs
            -- the offsets and the size come from the magnification measured
            -- at that NPC, and the two agree wherever depth is uniform.
            local s = scale
            if perspective then
              s = pixelsPerWorldPixel(v, npc, aaFactor, scale)
            end
            g.setColor(1, 1, 1, tier == 4 and fade or 1)
            g.draw(image, quads[BUBBLE[tier]],
                   sx - 4 * s, sy - 30 * s, 0, s, s)
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

#!/usr/bin/env python3
"""Break the mod on purpose and check the suite notices.

Nine tests in this mod have passed while proving nothing.  Every one was
caught by hand -- edit main.lua, run the suite, see whether anything goes
red -- and the one time that was skipped, the bug reached a player's
handheld.  A test that cannot fail is worse than no test, because it reads
as cover.

This applies each breakage below, runs the suite, and reports any that
leave it green.

A survivor means one of two things, and they are worth telling apart: the
rule is not actually tested, or the change was equivalent and broke
nothing.  The `not isOutdoor(...)` test inside the place spread was the
second kind -- every outdoor map is seeded as its own place before the
spread runs, so that check can never fire.  When something survives, read
the code before writing the test.

    cd ../gen1recomp && python3 mods/npc_bubbles/.devtools/mutate.py

Every entry is a real bug this mod has had.  Add to it whenever another
one gets fixed: the list is the memory.
"""

import pathlib
import subprocess
import sys

ENGINE = pathlib.Path(__file__).resolve().parents[3] / "gen1recomp"
MOD = pathlib.Path(__file__).resolve().parents[1]
MAIN = MOD / "main.lua"
SUITE = "mods/npc_bubbles/tests/npc_bubbles_test.lua"

# (name, find, replace).  An empty replacement deletes the line.
MUTATIONS = [
    ("mod closures are run again",
     '    if not safeToRun(mapId, npc.def and npc.def.text, entry) then\n      return 3\n    end\n', ''),
    ("talking runs a mod's closure",
     '    if not safeToRun(map.id, npc.def.text, entry) then return end\n', ''),
    ("a mod's rows are treated as unsafe too",
     '    if type(entry) ~= "function" then return true end   -- rows are data',
     '    if false then return true end'),
    ("a gift with no receipt is counted",
     '      if not skip and not recordable(item) then skip = true end\n', ''),
    ("only set_flag counts as a receipt",
     '          if verb == "trade" and row[3] then return true end\n          if verb == "mark_seen" then return true end\n', ''),
    ("a settled one-shot event stays a ?",
     '      if tier == 2 and alreadySettled(prog, game) then return nil, prog end\n', ''),
    ("a settled event is silenced even when it asks something",
     '        if CONDITIONS[row[1]] then return false end\n', ''),
    ("somebody absent counts as done without their receipt",
     '      if item.prog and alreadyClaimed(item.prog, game) then return "gone" end\n', ''),
    # Not the `not isOutdoor(maps[dest])` in the spread: every outdoor map
    # is seeded as its own place first, so that test can never fire and
    # removing it changes nothing.  The seeding is what carries the rule.
    # Not the last line of isOutdoor: the engine's own Map.isOutdoor
    # answers before it, so breaking the fallback changes nothing that runs.
    ("nowhere counts as outdoors, so towns and roads run together",
     '    if not def then return false end\n    if def.tileset == "PLATEAU" then return true end',
     '    if true then return false end'),
    ("PLATEAU is not somewhere you stand outdoors",
     '    if def.tileset == "PLATEAU" then return true end\n', ''),
    # Left out on purpose. Removing the sort makes the name depend on hash
    # order, which is stable inside one process and varies between them --
    # so this mutation is caught or missed at random, and a runner that
    # reports differently on identical code is worse than no runner. The
    # rule is pinned by a test asserting the first name in order instead.
    #   ("a sealed-off block names itself at random",
    #    '    table.sort(orphans)\n', ''),
    ("places are listed by name rather than map number",
     '      if ia ~= ib then return ia < ib end',
     '      if true then return a.mapId < b.mapId end'),
    ("the place you are standing in is listed twice",
     '      if reached[mapId] and mapId ~= here then rows[#rows + 1] = bucket end',
     '      if reached[mapId] then rows[#rows + 1] = bucket end'),
    ("a road is not inferred from its two ends",
     '    local been, of = inferRoads(maps, beenTo(game)), anchors(maps)',
     '    local been, of = beenTo(game), anchors(maps)'),
    ("a dead end counts as a road you have walked",
     '          if ends >= 2 and allKnown then',
     '          if ends >= 1 and allKnown then'),
    ("the count is reported on the menu row again",
     '      label = "NPC BUBBLES..",',
     '      label = "NPC BUBBLES..",\n      value = function() return "X" end,'),
    ("the presenter is found by name rather than by what it can do",
     '        if id ~= mod.id and type(ex) == "table"\n           and type(ex.registerAdapter) == "function" then',
     '        if id == "gen1_modern_ui" and type(ex) == "table"\n           and type(ex.registerAdapter) == "function" then'),
    ("the recogniser takes two arguments again",
     '      return function(state)\n        return type(state) == "table" and state.screenId == id',
     '      return function(_, state)\n        return type(state) == "table" and state.screenId == id'),
    ("a row with a picture is as wide as the rest",
     '    local WRAP, WRAP_WITH_PICTURE = 22, 15',
     '    local WRAP, WRAP_WITH_PICTURE = 22, 22'),
    ("the presented list cannot be scrolled",
     '      local frac = math.max(0, math.min(1, (state.scroll or 0) / max))',
     '      local frac = 0'),
    ("the baseline cache never clears",
     '  mod.events:on("save.loaded", function() forgetScore() end)\n', ''),
    ("the baseline is reached through a metatable again",
     '    local blank = {}\n    for k, v in pairs(real) do blank[k] = v end',
     '    local blank = setmetatable({}, { __index = real })'),
]


def run_suite():
    done = subprocess.run(["luajit", SUITE], cwd=ENGINE,
                          capture_output=True, text=True)
    return done.returncode == 0, (done.stdout + done.stderr)


def main():
    original = MAIN.read_text()
    survived, applied = [], 0
    try:
        ok, out = run_suite()
        if not ok:
            print("the suite is already failing; fix that first\n" + out[-400:])
            return 1
        print("clean: " + out.strip().splitlines()[-1])

        for name, find, replace in MUTATIONS:
            if find not in original:
                print("  SKIP  %-52s (pattern gone -- update this list)" % name)
                continue
            applied += 1
            MAIN.write_text(original.replace(find, replace, 1))
            ok, _ = run_suite()
            if ok:
                survived.append(name)
                print("  LIVED %-52s <-- nothing caught this" % name)
            else:
                print("  died  %s" % name)
    finally:
        MAIN.write_text(original)

    print("\n%d applied, %d survived" % (applied, len(survived)))
    if survived:
        print("These rules are not actually tested:")
        for name in survived:
            print("  - " + name)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

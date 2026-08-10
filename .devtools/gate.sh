#!/usr/bin/env bash
# Everything that has to be green before a build goes near the handheld.
#
#     cd ../gen1recomp && bash mods/npc_bubbles/.devtools/gate.sh
#
# The last check is the one that earned its place: `pack` ships whatever it
# finds in the mod folder, and a helper script left in `tools/` went into a
# zip unnoticed.  Only the five files below belong to the mod -- anything
# else is somebody's scratch and stays out of the build.  Working files go
# in `.devtools/`, which pack skips.
set -u

MOD=npc_bubbles
SHIPPED=".luarc.json CHANGELOG.md README.md main.lua manifest.json"
fails=0

step() {
  printf '%-34s' "$1"
  shift
  if out=$("$@" 2>&1); then
    echo "ok    ${out##*$'\n'}"
  else
    echo "FAIL"
    echo "$out" | tail -20 | sed 's/^/    /'
    fails=$((fails + 1))
  fi
}

step "suite"        luajit "mods/$MOD/tests/${MOD}_test.lua"
step "validate"     python3 tools/modkit.py validate "$MOD" --strict
step "lint"         python3 tools/modkit.py lint "$MOD"
step "mutations"    python3 "mods/$MOD/.devtools/mutate.py"

step "what ships" bash -c '
  zip=$(mktemp -u /tmp/gate-XXXX.zip)
  python3 tools/modkit.py pack '"$MOD"' -o "$zip" >/dev/null || exit 1
  got=$(unzip -Z1 "$zip" | grep -v "^\.modkit/" | sort | tr "\n" " ")
  rm -f "$zip"
  want=$(printf "%s\n" '"$SHIPPED"' | tr " " "\n" | sort | tr "\n" " ")
  [ "$got" = "$want" ] || { echo "extra or missing files in the zip"
                            echo "  packed: $got"
                            echo "  wanted: $want"; exit 1; }
  echo "$(echo $got | wc -w) files, as expected"'

echo
if [ "$fails" -eq 0 ]; then
  echo "all green -- safe to pack"
else
  echo "$fails failed -- do not ship"
fi
exit "$fails"

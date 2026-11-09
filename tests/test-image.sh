#!/usr/bin/env bash
# Integration test against a REAL Valheim server: boots the image, lets it create a world, then
# starts it again from damaged copies of that world and checks what the guard did.
#   ./tests/test-image.sh valheim-server-flux:local [/path/to/cached/opt-valheim]
# The cache dir only saves the ~1 GB game download on repeat runs.
set -uo pipefail
IMAGE=${1:?image}
CACHE=${2:-}
WORK=$(mktemp -d)
fail=0
ok()  { echo "ok   - $*"; }
bad() { echo "FAIL - $*"; fail=1; }
# The container writes as root, so the volumes are removed from inside one.
cleanup() { rm -f "$WORK.log"; docker rm -f vhtest >/dev/null 2>&1; docker run --rm -v "$WORK:/w" alpine sh -c 'rm -rf /w/*' >/dev/null 2>&1; rmdir "$WORK" 2>/dev/null; }
trap cleanup EXIT

run() {  # run <configdir>
  docker rm -f vhtest >/dev/null 2>&1
  local opt=(); [ -n "$CACHE" ] && opt=(-v "$CACHE:/opt/valheim")
  docker run -d --name vhtest -v "$1:/config" "${opt[@]}" \
    -e SERVER_NAME=t -e WORLD_NAME=Fixture -e SERVER_PASS=secret123 -e SERVER_PUBLIC=0 \
    -e RESTART_CRON= -e BACKUPS=false -e UPDATE_CRON= "$IMAGE" >/dev/null
}
# Logs go to a file first: `docker logs | grep -q` under pipefail fails on SIGPIPE when grep stops early.
has() { docker logs vhtest > "$WORK.log" 2>&1; grep -Eq "$1" "$WORK.log"; }
wait_for() {  # wait_for <regex> <seconds>
  for _ in $(seq 1 "$2"); do has "$1" && return 0; sleep 1; done; return 1
}
newest_ok() { ls "$1"/worlds_local/Fixture/_main.*.ok 2>/dev/null | sed 's/.*_main\.\([0-9]*\)\.ok/\1/' | sort -n | tail -1; }

mkdir -p "$WORK/base"
run "$WORK/base"
wait_for 'Game server connected' 900 || { bad "base server never came up"; docker logs vhtest 2>&1 | tail -20; exit 1; }
# A server that has only just started does not write a save on the way out; give it a few minutes.
sleep 200
docker stop -t 90 vhtest >/dev/null
GEN=$(newest_ok "$WORK/base"); [ -n "$GEN" ] && ok "fixture world saved as generation $GEN" || { bad "no save"; exit 1; }

# Up means connected; a FRESH world is the one that prints "Generating locations" (a saved one loads its own).
up() { wait_for 'Game server connected' 300 && sleep 25; }
fresh() { has 'Generating locations'; }
scenario() { rm -rf "${WORK:?}/$1"; cp -a "$WORK/base" "$WORK/$1"; }

# 1. healthy world: untouched, loads as the same world
scenario healthy; run "$WORK/healthy"
up && ok "healthy world boots" || bad "healthy world did not boot"
has 'flux-guard' && bad "guard spoke on a healthy world" || ok "guard silent on a healthy world"
docker stop -t 90 vhtest >/dev/null
fresh && bad "a fresh world was generated" || ok "the saved world loaded, not a fresh one"

# 2. sync-conflict file next to a complete save
scenario conflict; touch "$WORK/conflict/worlds_local/Fixture/_main.$GEN.sync-conflict-20260930-165322-XUVBXFM.db2"
run "$WORK/conflict"
up && ok "world with a conflict file boots" || bad "conflict world did not boot"
compgen -G "$WORK/conflict/sync-conflicts/*sync-conflict*" >/dev/null && ok "conflict file quarantined" || bad "conflict file not quarantined"
docker stop -t 90 vhtest >/dev/null
fresh && bad "a fresh world was generated" || ok "the saved world loaded, not a fresh one"

# 3. a newer marker whose data never arrived
scenario mixed; N=$((GEN+1)); cp "$WORK/mixed/worlds_local/Fixture/_main.$GEN.ok" "$WORK/mixed/worlds_local/Fixture/_main.$N.ok"
run "$WORK/mixed"
up && ok "mixed generation boots" || bad "mixed generation did not boot"
has "load save _main.$GEN" && ok "guard fell back to generation $GEN" || bad "no fallback logged"
docker stop -t 90 vhtest >/dev/null
fresh && bad "a fresh world was generated" || ok "the saved world loaded, not a fresh one"

# 4. nothing complete: refuse, and leave the folder exactly as it was
scenario broken; rm "$WORK/broken/worlds_local/Fixture/_main.$GEN.db2"
before=$(cd "$WORK/broken/worlds_local" && find . -type f | sort | md5sum)
run "$WORK/broken"; wait_for 'refusing to start' 300 || true
has 'refusing to start' && ok "guard refused" || bad "guard did not refuse"
has 'Game server connected' && bad "server started on a broken world" || ok "server did not start"
after=$(cd "$WORK/broken/worlds_local" && find . -type f | sort | md5sum)
[ "$before" = "$after" ] && ok "broken world left untouched" || bad "broken world was modified"
docker rm -f vhtest >/dev/null 2>&1

[ "$fail" = 0 ] && echo "ALL PASSED" || { echo "FAILURES"; exit 1; }

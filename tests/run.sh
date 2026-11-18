#!/bin/bash

set -u -o pipefail

cd "$(dirname "$0")/.." || exit 2

PHASES=(lint build image up smoke lifecycle fail2ban down)
IMAGE=${IMAGE:-freepbx:test}
NAME=${NAME:-fpbxtest}
DB_IMAGE=${DB_IMAGE:-mariadb:11.8}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-900}
KEEP=${KEEP:-0}

source tests/lib/common.sh || exit 2
source tests/lib/lint.sh || exit 2
source tests/lib/build.sh || exit 2
source tests/lib/image.sh || exit 2
source tests/lib/up.sh || exit 2
source tests/lib/smoke.sh || exit 2
source tests/lib/lifecycle.sh || exit 2
source tests/lib/fail2ban.sh || exit 2
source tests/lib/down.sh || exit 2
# The last function of each library: one that loaded empty or cut short would end in a green summary.
for f in once "${PHASES[@]/#/phase_}"; do
  declare -F "$f" >/dev/null || { echo "tests/lib: $f is not defined" >&2; exit 2; }
done

usage() { echo "usage: $0 [${PHASES[*]}]   (no argument: all phases)" >&2; exit 2; }

declare -A WANT=()
for a in "$@"; do
  case $a in lint|build|image|up|smoke|lifecycle|fail2ban|down) WANT[$a]=1 ;; *) usage ;; esac
done

ALL=0
if (( $# == 0 )); then ALL=1; for p in "${PHASES[@]}"; do WANT[$p]=1; done; fi

[[ $BOOT_TIMEOUT =~ ^[0-9]+$ ]] || { echo "BOOT_TIMEOUT must be a number of seconds" >&2; exit 2; }

# Shared with the libraries. ENV: an environment may exist, for finish to save logs from and remove.
# C: the app container. SKIP: why the next phases are skipped. BANNED: the proxy may be banned.
FAILS=0 WARNS=0 ENV=0 BANNED=0 KA='' C='' SKIP=''

RUN=$(mktemp -d "${TMPDIR:-/tmp}/fpbx-test.XXXXXX") || exit 2
# tee -i: Ctrl+C must not cut the tail of run.log.
exec > >(tee -i "$RUN/run.log") 2>&1
TEE=$!
# fd 3: the traps run under the redirections of the interrupted command (e.g. build.log).
exec 3>&1

finish() {
  local rc=$? c
  exec >&3 2>&3
  trap '' INT
  if (( BANNED )) && c=$(cid app) && [[ -n $c ]]; then
    dk exec "$c" timeout 30 fail2ban-client unban --all >/dev/null 2>&1 && echo "proxy unbanned" \
      || echo "unban failed; run: sudo docker exec $NAME-app fail2ban-client unban --all"
  fi
  if (( ENV )); then
    (( FAILS || rc )) && save_log
    (( ALL )) && [[ $KEEP != 1 ]] && teardown && ENV=0
  fi
  [[ -n $KA ]] && kill "$KA" 2>/dev/null
  if (( ENV )); then
    echo "environment kept ($NAME-db, $NAME-app, $NAME-proxy); remove: tests/run.sh down"
  fi
  printf '\nSUMMARY: %d FAIL, %d warn\nrun dir: %s\n' "$FAILS" "$WARNS" "$RUN"
  (( rc == 0 && FAILS )) && rc=1
  # Give tee up to 1 s to print the last lines before the prompt returns.
  exec >&- 2>&- 3>&-
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$TEE" 2>/dev/null || break; sleep 0.1; done
  exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT

if [[ "${!WANT[*]}" != lint ]] && (( EUID )); then
  sudo -v || exit 2
  # One docker build can outlive sudo's timestamp; -n then fails instead of prompting.
  # s starts empty: $! would otherwise be the tee process substitution.
  ( s=''; trap '[[ -n $s ]] && kill "$s" 2>/dev/null; exit 0' TERM
    while kill -0 $$ 2>/dev/null; do sleep 60 & s=$!; wait "$s"; sudo -n -v; done ) >/dev/null 2>&1 3>&- &
  KA=$!
fi
for p in "${PHASES[@]}"; do
  [[ -n ${WANT[$p]-} ]] || continue
  # A full run skips "down" (R1) when the environment is kept or SKIP is set: finish keeps or removes it.
  [[ $p == down ]] && (( ALL )) && [[ $KEEP == 1 || -n $SKIP ]] && continue
  if [[ -n $SKIP && $p != lint && $p != down ]]; then sec "$p: skipped, $SKIP"; continue; fi
  # smoke, lifecycle and fail2ban set ENV once need_app finds the app.
  case $p in up|down) ENV=1 ;; esac
  sec "$p"
  "phase_$p"
done
exit 0

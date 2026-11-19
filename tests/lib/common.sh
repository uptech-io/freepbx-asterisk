# shellcheck shell=bash

# Lines that must never appear in an app log ("Error:" as the boot scripts' log() prints it).
BAD_LOG='Warning: Asterisk is not writing to the fail2ban log|Running FreePBX module upgrades'
BAD_LOG+='|^[0-9-]{10} [0-9:]{8} Error:|command not found|Traceback'
BAD_LOG+='|Unable to open Asterisk database|not expected'

ok()   { printf 'ok    %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
warn() { printf 'warn  %s\n' "$*"; WARNS=$((WARNS + 1)); }
ev()   { fold -s -w 96 | sed 's/^/    /'; }
sec()  { printf '\n## %s\n' "$*"; }
stamp() { date +%s.%N; }

# A value parsed from dk must not take its stderr (no 2>&1): a sudo warning would corrupt it.
dk() { if (( EUID )); then sudo -n docker "$@"; else docker "$@"; fi; }
cid() { dk container inspect -f '{{if .State.Running}}{{.Id}}{{end}}' "$NAME-$1" 2>/dev/null; }
ip_of() { dk inspect -f '{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}' "$1" 2>/dev/null | grep -m1 '^10\.5\.'; }
save_log() {
  local out
  [[ -n $C && ! -e $RUN/app-${C:0:12}.log ]] && dk logs "$C" >"$RUN/app-${C:0:12}.log" 2>&1
  out=$(dk logs "$NAME-db" 2>&1) && printf '%s\n' "$out" >"$RUN/db.log"
}
need_app() { C=$(cid app); [[ -n $C ]] || { fail "$NAME-app is not running"; return 1; }; ENV=1; }

# start_app <id>: create, connect, start, so that both networks exist when the entrypoint runs.
start_app() {
  local out
  # --ulimit nofile: the default of newer Docker engines; supervisord's minfds has to raise it for Asterisk (M23).
  out=$(dk create --name "$NAME-app" --pull never --network "$NAME-front" --cap-add NET_ADMIN --stop-timeout 90 \
        --ulimit nofile=1024:524288 -e DBHOST="$NAME-db" -e DBROOT_PASSWORD=root -e DBNAME=asterisk -e DBUSER=dev \
        -e DBPASSWORD=1234567890 -v "$NAME-data:/data" "$IMAGE" 2>&1) \
    && out=$(dk network connect "$NAME-back" "$NAME-app" 2>&1) && out=$(dk start "$NAME-app" 2>&1) \
    || { fail "$1 start of $NAME-app"; ev <<<"$out"; return 1; }
}

# gate <id>: waits for the app container's bootstrap to exit; sets C.
gate() {
  local id=$1 s st='' end=$((SECONDS + BOOT_TIMEOUT)) t0=$SECONDS
  C=$(dk container inspect -f '{{.Id}}' "$NAME-app" 2>/dev/null) || { fail "$id no container $NAME-app"; return 1; }
  while (( SECONDS < end )); do
    s=$(dk container inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$C" 2>/dev/null)
    if [[ $s != running* ]]; then
      fail "$id app container stopped before the boot finished ($s)"; dk logs --tail 30 "$C" 2>&1 | ev; return 1
    fi
    st=$(dk exec "$C" timeout 20 supervisorctl status bootstrap 2>&1)
    if grep -Eq '^bootstrap +EXITED' <<<"$st"; then ok "$id bootstrap EXITED after $((SECONDS - t0)) s"; return 0; fi
    sleep 5
  done
  fail "$id bootstrap not EXITED after $BOOT_TIMEOUT s"; ev <<<"last status: ${st:-none}"
  dk logs --tail 30 "$C" 2>&1 | ev
  return 1
}

teardown() {
  local x t out err=''
  for x in container:app container:g2 container:g3 container:g4 container:g5 container:proxy container:db \
           volume:data volume:dbdata network:front network:back network:ipvlan; do
    t=${x%%:*} x=$NAME-${x#*:}
    dk "$t" inspect "$x" >/dev/null 2>&1 || continue
    if [[ $t == container ]]; then out=$(dk rm -f -v "$x" 2>&1); else out=$(dk "$t" rm "$x" 2>&1); fi \
      || err+="$t $x: $out"$'\n'
  done
  if [[ -n $err ]]; then fail "T1 objects of $NAME not removed"; ev <<<"$err"; return 1; fi
  ok "T1 containers, volumes and networks of $NAME removed"
}

# run_fn <function> <docker args...>: runs the function inside a container ("bash -s" reads it from stdin
# with the helpers listed below), prints its lines and adds its tally; no tally is a FAIL.
run_fn() {
  local f=$1 last; shift
  # The call reads /dev/null so nothing in it can swallow the tally line still on stdin.
  # Streamed, so the lines already printed survive a Ctrl+C; the tally must be the last line.
  { declare -f ok fail warn ev daemon_pid ast_back "$f"
    printf 'FAILS=0 WARNS=0\n%s </dev/null\necho "__TALLY__ $FAILS $WARNS"\n' "$f"; } \
    | dk "$@" 2>&1 | tee "$RUN/fn.out" | grep --line-buffered -v '^__TALLY__ '
  last=$(tail -n 1 "$RUN/fn.out")
  if [[ $last =~ ^__TALLY__\ ([0-9]+)\ ([0-9]+)$ ]]; then
    FAILS=$((FAILS + BASH_REMATCH[1])) WARNS=$((WARNS + BASH_REMATCH[2]))
  else fail "$f ended without its tally (died or timed out)"; fi
}
in_app() { local f=$1; shift; run_fn "$f" exec -i "$@" "$C" timeout 600 bash -s; }

# Container side only (run_fn ships them).
daemon_pid() { pgrep -f '^/usr/local/asterisk/sbin/asterisk -f'; }

# ast_back <text> <old daemon pid> <seconds>: Asterisk RUNNING again under a new daemon.
ast_back() {
  local s pid='' n end=$((SECONDS + $3))
  until s=$(supervisorctl status asterisk 2>&1); [[ $s =~ ^asterisk\ +RUNNING ]] && pid=$(daemon_pid) && [[ $pid != "$2" ]]; do
    if (( SECONDS >= end )); then fail "$1: not RUNNING with a new daemon in $3 s"; ev <<<"$s"; return 1; fi
    sleep 1
  done
  s=$(timeout 60 asterisk -rx 'core waitfullybooted' 2>&1)
  n=$(pgrep -c -f '^/usr/local/asterisk/sbin/asterisk -f')
  if [[ $s == *'fully booted'* && $n == 1 ]]; then ok "$1 (pid ${2:--} -> $pid)"; return 0; fi
  fail "$1: daemons $n"; ev <<<"$s"; return 1
}

# in_order <text> <log> <fixed strings...>: each string appears after the previous one.
in_order() {
  local t=$1 log=$2 p m n=0; shift 2
  for p; do
    # One awk, no pipe: an early-exit grep kills its writer with SIGPIPE, a false FAIL under pipefail.
    m=$(P=$p awk -v n="$n" 'NR > n && index($0, ENVIRON["P"]) { print NR; exit }' <<<"$log")
    [[ -n $m ]] || { fail "$t"; ev <<<"missing after log line $n: $p"; return 1; }
    n=$m
  done
  ok "$t"
}

# absent <text> <log> <ERE>: callers first prove the log is the right, non-empty one.
absent() {
  local m; m=$(grep -E -- "$3" <<<"$2" | head -n 10)
  if [[ -z $m ]]; then ok "$1"; else fail "$1"; ev <<<"$m"; fi
}

# once <text> <log> <fixed strings...>: each string appears exactly once.
once() {
  local p n bad=''
  for p in "${@:3}"; do n=$(grep -cF -- "$p" <<<"$2"); [[ $n == 1 ]] || bad+="$n x '$p' "; done
  if [[ -z $bad ]]; then ok "$1"; else fail "$1"; ev <<<"$bad"; fi
}

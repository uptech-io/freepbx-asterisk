# shellcheck shell=bash

phase_down() {
  local t s rc code out log cur
  cur=$(cid app); [[ -n $cur ]] && C=$cur
  (( FAILS )) && save_log
  if [[ -z $cur ]]; then warn "R1 skipped: $NAME-app is not running"
  else
    t=$(stamp) s=$SECONDS
    # -t 100: a stop slower than the 90 s grace period the README asks for is timed and fails, not killed.
    out=$(dk stop -t 100 "$C" 2>&1); rc=$?; s=$((SECONDS - s))
    code=$(dk inspect -f '{{.State.ExitCode}}' "$C")
    if [[ $rc == 0 && $code == 0 ]] && (( s < 90 )); then ok "R1 docker stop -t 100: exit 0 in $s s"
    else fail "R1 docker stop -t 100: rc $rc, exit code $code, $s s"; ev <<<"$out"; fi
    log=$(dk logs --since "$t" "$C" 2>&1)
    in_order "R1 SIGTERM, then stopped in order" "$log" 'received SIGTERM indicating exit request' \
      'stopped: apache2' 'stopped: cron' 'stopped: asterisk' 'stopped: fail2ban' 'stopped: dbus' \
      && absent "R1 nothing killed with SIGKILL" "$log" 'SIGKILL'
  fi
  teardown && ENV=0
}

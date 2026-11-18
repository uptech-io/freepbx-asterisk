# shellcheck shell=bash

phase_up() {
  local out log end ids s t0
  teardown || { SKIP='up failed'; return; }
  # The image's firewall and Apache take the GUI only from 10.5.0.0/16.
  if ! out=$(dk network create -d bridge --subnet 10.5.0.0/16 "$NAME-front" 2>&1); then
    fail "N1 network $NAME-front on 10.5.0.0/16 not created"; ev <<<"$out"
    ids=$(dk network ls -q)
    [[ -n $ids ]] && dk network inspect -f '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' $ids 2>&1 | ev
    SKIP='up failed'; return
  fi
  ok "N1 network $NAME-front on 10.5.0.0/16"
  out=$(dk network create -d bridge --internal "$NAME-back" 2>&1) \
    || { fail "network $NAME-back not created"; ev <<<"$out"; SKIP='up failed'; return; }
  # Root only: the image must create the databases and the application user by itself.
  out=$(dk run -d --name "$NAME-db" --network "$NAME-back" -e MARIADB_ROOT_PASSWORD=root \
        -v "$NAME-dbdata:/var/lib/mysql" --health-cmd 'healthcheck.sh --connect --innodb_initialized' \
        --health-interval 3s --health-timeout 3s --health-retries 40 "$DB_IMAGE" 2>&1) \
    || { fail "start of $NAME-db"; ev <<<"$out"; SKIP='up failed'; return; }
  t0=$SECONDS end=$((SECONDS + 180))
  until s=$(dk container inspect -f '{{.State.Status}} {{.State.Health.Status}}' "$NAME-db" 2>/dev/null)
        [[ $s == 'running healthy' ]]; do
    if [[ $s != running* ]] || (( SECONDS >= end )); then
      fail "db not healthy after $((SECONDS - t0)) s ($s)"; dk logs --tail 30 "$NAME-db" 2>&1 | ev
      SKIP='up failed'; return
    fi
    sleep 5
  done
  ok "db healthy"
  out=$(dk run -d --name "$NAME-proxy" --pull never --network "$NAME-front" --init --no-healthcheck \
        --entrypoint sleep "$IMAGE" infinity 2>&1) \
    || { fail "start of $NAME-proxy"; ev <<<"$out"; SKIP='up failed'; return; }
  start_app G1 || { SKIP='up failed'; return; }
  gate "G1/B4" || { SKIP='up failed'; return; }
  log=$(dk logs "$C" 2>&1)
  if in_order "B1 first boot steps in order" "$log" 'Waiting for db to become available' 'db is now online' \
    'No installation detected' 'Loading nftables basic rules' 'Preparing services' \
    'Creating the databases and the application user' 'Fixing permissions' \
    "spawned: 'dbus'" "spawned: 'fail2ban'" "spawned: 'asterisk'" "spawned: 'cron'" "spawned: 'bootstrap'" \
    'Asterisk is now fully booted' 'You have successfully installed FreePBX' 'Skipping FreePBX module upgrades' \
    'Reloading FreePBX configuration' 'Adding the fail2ban log channel' 'Starting Apache through supervisord' \
    "spawned: 'apache2'" 'Bootstrap finished.' 'exited: bootstrap (exit status 0; expected)'; then
    once "B1 databases prepared and channel added once" "$log" 'Creating the databases and the application user' \
      'Adding the fail2ban log channel'
    absent "B2 boot log has no error lines" "$log" "$BAD_LOG"
  fi
  if dk exec "$C" sh -c 'test ! -e /data/.freepbx-install-pending && test -f /data/asterisk/etc/freepbx.conf && test -f /data/web/admin/config.php'; then
    ok "B3 install marker gone, freepbx.conf and config.php present"
  else
    fail "B3 install state"; dk exec "$C" ls -l /data/.freepbx-install-pending /data/asterisk/etc/freepbx.conf /data/web/admin/config.php 2>&1 | ev
  fi
}

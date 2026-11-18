# shellcheck shell=bash

R0_JOB='0 0 1 1 * /bin/true'
# G3 and G4 write the same hook file, so whatever an interrupted run left there is overwritten.
# 99: after any hook a failed run left behind, which G3's "flush ruleset" loaded first would break.
G_HOOK=/data/entrypoint-hooks.d/nftables.d/99-test.nft

# An empty volume over the installed database: the entrypoint must refuse before it writes anything.
g2_refuse() {
  local out
  # Same DBPASSWORD as the app: if the refusal failed, the GRANT would not change the password in use.
  out=$(dk run --rm --name "$NAME-g2" --pull never --network "$NAME-back" -e DBHOST="$NAME-db" -e DBROOT_PASSWORD=root \
        -e DBNAME=asterisk -e DBUSER=dev -e DBPASSWORD=1234567890 "$IMAGE" true 2>&1)
  if [[ $? != 0 ]] && grep -qF 'refusing to install over it' <<<"$out"; then ok "G2 empty volume over the installed database is refused"
  else fail "G2 empty volume over the installed database was not refused"; tail -n 5 <<<"$out" | ev; fi
}

# A .nft hook that fails to load, takes the base rules away or is not root's must stop the boot.
# Before R0: while the volume's Asterisk is the image's, the throwaway container changes nothing in it.
g3_bad_hooks() {
  local h=$G_HOOK c o r w out rc
  for c in 'root|add rule inet filter input tcp dport 4569 acept|failed to load' \
           'root|flush ruleset|without its drop policy' \
           'asterisk|add rule inet filter input tcp dport 4569 accept|is not owned by root'; do
    IFS='|' read -r o r w <<<"$c"
    dk exec "$C" sh -c "echo '$r' >$h && chown $o $h" || { fail "G3 could not write $h"; return; }
    out=$(dk run --rm --name "$NAME-g3" --pull never --network "$NAME-back" --cap-add NET_ADMIN \
          -e DBHOST="$NAME-db" -v "$NAME-data:/data" "$IMAGE" true 2>&1); rc=$?
    dk exec "$C" rm -f "$h"
    if [[ $rc != 0 ]] && grep -qF "$w" <<<"$out"; then ok "G3 hook of $o '$r' stops the boot"
    else fail "G3 hook of $o '$r' did not stop the boot (rc $rc)"; tail -n 5 <<<"$out" | ev; fi
  done
}

# A container on an ipvlan network, as in production: EXTRA_IPV4 must replace the interface's IPv4,
# EXTRA_IPV6 join its IPv6, both default routes go there and the hooks get the interface's name.
# Before R0, like G3. Without a parent interface, Docker keeps the network apart from the host's.
g4_ipvlan() {
  local net=$NAME-ipvlan out rc i
  # What an interrupted run left would make every later run fail here.
  dk rm -f "$NAME-g4" >/dev/null 2>&1; dk network rm "$net" >/dev/null 2>&1
  out=$(dk network create -d ipvlan --subnet 192.0.2.0/24 --ipv6 --subnet 2001:db8:5::/64 "$net" 2>&1) \
    || { fail "G4 ipvlan network $net not created"; ev <<<"$out"; return; }
  dk exec "$C" sh -c "echo 'add rule inet filter input iifname \$ipvlan_if tcp dport 4569 accept comment \"g4\"' >$G_HOOK && chown root $G_HOOK" \
    || { fail "G4 could not write $G_HOOK"; dk network rm "$net" >/dev/null 2>&1; return; }
  # On the front network too: Docker's default route goes through it, for the entrypoint to move.
  out=$(dk create --name "$NAME-g4" --pull never --network "$NAME-front" --cap-add NET_ADMIN -e DBHOST="$NAME-db" \
        -e EXTRA_IPV4=192.0.2.50/24 -e IPV4_GATEWAY=192.0.2.254 -e EXTRA_IPV6=2001:db8:5::50/64 \
        -e IPV6_GATEWAY=2001:db8:5::fe -v "$NAME-data:/data" "$IMAGE" \
        sh -c 'ip -o addr show; ip -4 route show default; ip -6 route show default; nft list chain inet filter input' 2>&1) \
    && out=$(dk network connect "$NAME-back" "$NAME-g4" 2>&1) && out=$(dk network connect "$net" "$NAME-g4" 2>&1) \
    && out=$(dk start -a "$NAME-g4" 2>&1); rc=$?
  dk exec "$C" rm -f "$G_HOOK"
  dk rm -f "$NAME-g4" >/dev/null 2>&1; dk network rm "$net" >/dev/null 2>&1
  i=$(sed -n "s/.*Adding extra IPv4 address '192\.0\.2\.50\/24' to interface '\(.*\)'\.\$/\1/p" <<<"$out")
  if [[ $rc != 0 || -z $i ]]; then
    fail "G4 container on the ipvlan network: rc $rc, interface in the boot log: ${i:-none}"; tail -n 15 <<<"$out" | ev; return
  fi
  if awk -v i="$i" '$2 == i && $3 == "inet" { n++; a = $4 } END { exit !(n == 1 && a == "192.0.2.50/24") }' <<<"$out" \
     && [[ $(grep -Ec '^default via [0-9.]+ ' <<<"$out") == 1 ]] && grep -Eq "^default via 192\.0\.2\.254 dev $i( |\$)" <<<"$out"; then
    ok "G4 $i: EXTRA_IPV4 is its only IPv4, IPv4 default route moved to IPV4_GATEWAY"
  else fail "G4 $i: IPv4 address or default route"; grep -E " $i +inet |^default via [0-9.]+ " <<<"$out" | ev; fi
  if awk -v i="$i" '$2 == i && $3 == "inet6" && $4 == "2001:db8:5::50/64" { f = 1 } END { exit !f }' <<<"$out" \
     && grep -Eq "^default via 2001:db8:5::fe dev $i( |\$)" <<<"$out"; then ok "G4 $i: EXTRA_IPV6 added, IPv6 default route via IPV6_GATEWAY"
  else fail "G4 $i: IPv6 address or default route"; grep -E " $i +inet6 |^default via [0-9a-f]*:" <<<"$out" | ev; fi
  grep -qF "iifname \"$i\" tcp dport 4569 accept comment \"g4\"" <<<"$out" && ok "G4 the .nft hook got the interface name ($i)" \
    || { fail "G4 the .nft hook did not get the interface name"; grep -F 4569 <<<"$out" | ev; }
}

# Functions passed to run_fn or in_app run inside a container: of the host, only run_fn's helpers exist there.

l1_kill() {
  local pid; pid=$(daemon_pid)
  [[ $pid =~ ^[0-9]+$ ]] || { fail "L1 no single Asterisk daemon to kill"; ev <<<"$pid"; return; }
  kill -9 "$pid"
  ast_back "L1 kill -9: Asterisk restarted" "$pid" 30
}

l2_stop() {
  local out s
  out=$(timeout 120 fwconsole stop 2>&1)
  # supervisord would respawn within a second; 10 s stays far from the health check's ~150 s.
  sleep 10
  s=$(supervisorctl status asterisk 2>&1)
  [[ $s =~ ^asterisk\ +EXITED ]] && ok "L2 fwconsole stop: asterisk stays EXITED" \
    || { fail "L2 asterisk 10 s after fwconsole stop"; ev <<<"$s"$'\n'"$out"; }
}

l3_start() {
  local out; out=$(timeout 120 fwconsole start 2>&1)
  ast_back "L3 fwconsole start: Asterisk up" "" 20 || ev <<<"$out"
}

l4_restart() {
  local out pid; pid=$(daemon_pid)
  out=$(timeout 180 fwconsole restart 2>&1)
  ast_back "L4 fwconsole restart: new Asterisk" "$pid" 30 || ev <<<"$out"
}

r0_prepare() {
  local conf=/etc/asterisk/logger_logfiles_custom.conf f2b=/data/asterisk/var/log/asterisk/fail2ban n out rc
  local h=/data/entrypoint-hooks.d
  # A jail drop-in in the volume: a reload applies it now and the next container reads it again (R4).
  # Before the jail log is removed: a reload without it fails.
  printf '[DEFAULT]\nignoreip = 127.0.0.1/8 ::1 203.0.113.250\n' >/data/fail2ban/jail.d/ignoreip.local
  out=$(timeout 30 fail2ban-client -t 2>&1 && timeout 30 fail2ban-client reload 2>&1); rc=$?
  out+=$'\n'$(timeout 30 fail2ban-client get asterisk ignoreip 2>&1)
  # rc too: on a kept environment the address is already listed, even if this reload is refused.
  (( rc == 0 )) && grep -q '^[|`]- 203\.0\.113\.250$' <<<"$out" && ok "R0 jail.d drop-in applied by a reload" \
    || { fail "R0 jail.d drop-in not applied (test/reload rc $rc)"; ev <<<"$out"; }
  sed -i '/^fail2ban =>/d' "$conf"; rm -f "$f2b"
  n=$(grep -c '^fail2ban' "$conf" 2>&1)
  [[ $n == 0 && ! -e $f2b ]] && ok "R0 channel line and jail log removed" || fail "R0 channel lines $n, jail log still present?"
  # A job as FreePBX schedules them: the next container must still have it (R4).
  { crontab -u asterisk -l 2>/dev/null | grep -vF "$R0_JOB"; echo "$R0_JOB"; } | crontab -u asterisk - \
    && ok "R0 test job added to the asterisk crontab" || fail "R0 could not add a job to the asterisk crontab"
  # An older Asterisk in the volume: the next container must bring the image's back (R4).
  # Through a rename: the running daemon keeps the old file open.
  cp -p /data/asterisk/sbin/asterisk /data/asterisk/sbin/asterisk.r0 && echo stale >>/data/asterisk/sbin/asterisk.r0 \
    && mv /data/asterisk/sbin/asterisk.r0 /data/asterisk/sbin/asterisk \
    && ok "R0 Asterisk binary in the volume made stale" || fail "R0 could not alter the Asterisk binary in the volume"
  # Boot hooks: the next container must apply root's two and skip the one owned by asterisk (R3, R4).
  rm -f /data/.r0-hook /data/.r0-hook-asterisk
  echo 'add rule inet filter input tcp dport 4569 accept comment "r0-hook"' >"$h/nftables.d/50-r0.nft" \
    && echo 'touch /data/.r0-hook' >"$h/scripts.d/50-r0.sh" \
    && echo 'touch /data/.r0-hook-asterisk' >"$h/scripts.d/60-r0.sh" \
    && chown asterisk:asterisk "$h/scripts.d/60-r0.sh" \
    && ok "R0 boot hooks written" || fail "R0 could not write the boot hooks"
  # Owners as an older image left them: the next boot must give the code and fail2ban back to root (R3, M16).
  chown -R asterisk:asterisk /data/asterisk/sbin /data/asterisk/usr /data/fail2ban \
    && chown asterisk:asterisk /data /data/asterisk \
    && ok "R0 code and fail2ban handed to asterisk" || fail "R0 could not change the owners in the volume"
}

r4_check() {
  local s n f2b=/data/asterisk/var/log/asterisk/fail2ban h=/data/entrypoint-hooks.d
  s=$(supervisorctl status fail2ban 2>&1)
  [[ $s =~ ^fail2ban\ +RUNNING ]] && ok "R4 fail2ban RUNNING" || { fail "R4 fail2ban not RUNNING"; ev <<<"$s"; }
  s=$(stat -c '%U:%G %a' "$f2b" 2>&1)
  [[ $s == 'asterisk:asterisk '* ]] && ok "R4 jail log recreated ($s)" || fail "R4 jail log: $s"
  n=$(grep -c '^fail2ban' /etc/asterisk/logger_logfiles_custom.conf 2>&1)
  [[ $n == 1 ]] && ok "R4 channel line re-added once" || fail "R4 channel lines: $n (want 1)"
  s=$(timeout 30 fail2ban-client get asterisk ignoreip 2>&1)
  grep -q '^[|`]- 203\.0\.113\.250$' <<<"$s" && ok "R4 ignore list of the volume's jail.d kept" \
    || { fail "R4 ignore list of the volume's jail.d lost"; ev <<<"$s"; }
  s=$(crontab -u asterisk -l 2>&1)
  grep -qxF "$R0_JOB" <<<"$s" && ok "R4 asterisk crontab kept in the volume" \
    || { fail "R4 asterisk crontab lost its job"; ev <<<"$s"; }
  s=$(nft list chain inet filter input 2>&1)
  grep -qF 'comment "r0-hook"' <<<"$s" && ok "R4 .nft hook applied" || { fail "R4 .nft hook not applied"; ev <<<"$s"; }
  [[ -f /data/.r0-hook ]] && ok "R4 root's .sh hook ran" || fail "R4 root's .sh hook did not run"
  [[ ! -e /data/.r0-hook-asterisk ]] && ok "R4 the .sh hook owned by asterisk did not run" \
    || fail "R4 a .sh hook owned by asterisk ran as root"
  rm -f "$h/nftables.d/50-r0.nft" "$h/scripts.d/50-r0.sh" "$h/scripts.d/60-r0.sh" /data/.r0-hook /data/.r0-hook-asterisk
}

phase_lifecycle() {
  local t log out new img
  need_app || return
  t=$(stamp); in_app l1_kill
  in_order "L1 log: killed, then respawned" "$(dk logs --since "$t" "$C" 2>&1)" \
    'exited: asterisk (terminated by SIGKILL; not expected)' "spawned: 'asterisk'"
  t=$(stamp); in_app l2_stop
  log=$(dk logs --since "$t" "$C" 2>&1)
  in_order "L2 log: requested exit" "$log" 'exited: asterisk (exit status 0; expected)' \
    && absent "L2 log: no respawn after the stop" "$log" "spawned: 'asterisk'"
  in_app l3_start
  in_app l4_restart
  g2_refuse
  g3_bad_hooks
  g4_ipvlan
  in_app r0_prepare -e "R0_JOB=$R0_JOB"
  (( FAILS )) && save_log
  out=$(dk kill "$C" 2>&1) || { fail "docker kill of the app container"; ev <<<"$out"; return; }
  # -f: the kill may return before the container has stopped.
  out=$(dk rm -f "$C" 2>&1) || { fail "docker rm of the app container"; ev <<<"$out"; return; }; C=''
  start_app R2 && gate "R2" || { SKIP='lifecycle failed'; return; }
  log=$(dk logs "$C" 2>&1)
  if in_order "R3 boot over the installed volume" "$log" 'Previous installation detected' \
    'Giving /data/fail2ban back to root' 'Updating the Asterisk binaries and modules' \
    'Applying nftables configuration: /data/entrypoint-hooks.d/nftables.d/50-r0.nft' \
    'Running script: /data/entrypoint-hooks.d/scripts.d/50-r0.sh' \
    'Warning: skipping /data/entrypoint-hooks.d/scripts.d/60-r0.sh' 'Fixing permissions' \
    'Skipping FreePBX module upgrades' 'Adding the fail2ban log channel' 'Bootstrap finished.'; then
    once "R3 channel added once" "$log" 'Adding the fail2ban log channel'
    absent "R3 no reinstall and no error lines" "$log" "No installation detected|Creating the databases|$BAD_LOG"
  fi
  in_app r4_check -e "R0_JOB=$R0_JOB"
  # The proxy runs the same image and never ran the entrypoint: its copy is the image's.
  new=$(dk exec "$C" sha256sum /data/asterisk/sbin/asterisk 2>/dev/null | cut -d' ' -f1)
  img=$(dk exec "$(cid proxy)" sha256sum /usr/local/asterisk/sbin/asterisk 2>/dev/null | cut -d' ' -f1)
  [[ -n $new && $new == "$img" ]] && ok "R4 the volume's Asterisk is the image's again" \
    || fail "R4 Asterisk in the volume (${new:0:12}) differs from the image's (${img:0:12})"
  sec "smoke on the new container (R5)"
  phase_smoke
}

# shellcheck shell=bash

# Functions passed to run_fn or in_app run inside a container: of the host, only run_fn's helpers exist there.

app_smoke() {
  local s p u m n out bad=0 f2b=/data/asterisk/var/log/asterisk/fail2ban
  out=$(ps -o args= -p 1 2>&1)
  [[ $out == *supervisord* ]] && ok "M1 PID 1 is supervisord" || fail "M1 PID 1 is: $out"
  s=$(supervisorctl status 2>&1)
  for p in asterisk apache2 dbus cron fail2ban; do grep -Eq "^$p +RUNNING" <<<"$s" || bad=1; done
  grep -Eq '^bootstrap +EXITED' <<<"$s" || bad=1
  if (( bad )); then fail "M2 supervisorctl status"; ev <<<"$s"; else ok "M2 five programs RUNNING, bootstrap EXITED"; fi
  out=$(timeout 60 asterisk -rx 'core waitfullybooted' 2>&1)
  [[ $out == *'fully booted'* ]] && ok "M3 Asterisk fully booted" || { fail "M3 core waitfullybooted"; ev <<<"$out"; }
  p=$(daemon_pid)
  [[ $p =~ ^[0-9]+$ ]] && ok "M4 one Asterisk daemon" || fail "M4 Asterisk daemons: $(wc -w <<<"$p")"
  out=$(ps -o user= -p "${p//$'\n'/,}" 2>&1)
  [[ ${out// /} == asterisk ]] && ok "M5 Asterisk runs as asterisk" || fail "M5 Asterisk user: $out"
  # Started without root, it keeps none of the container's capabilities (NET_ADMIN).
  out=$(awk '/^CapEff/ { print $2 }' "/proc/$p/status" 2>&1)
  [[ $out =~ ^0+$ ]] && ok "M5 Asterisk holds no capabilities" || fail "M5 Asterisk capabilities (CapEff): $out"

  out=$(timeout 30 asterisk -rx 'module show' 2>&1); bad=0
  for m in res_pjsip chan_pjsip res_odbc cdr_adaptive_odbc res_srtp format_mp3; do
    awk -v m="$m.so" '$1 == m && / Running / && !/ Not Running /' <<<"$out" | grep -q . \
      || { fail "M6 module not Running: $m"; grep -F "$m.so" <<<"$out" | ev; bad=1; }
  done
  (( bad )) || ok "M6 six key modules Running"
  # DB* are in the container's configuration, which "docker exec" gets whole: DBROOT_PASSWORD too (see M24).
  out=$(echo 'select 1' | timeout 30 isql -b MySQL-asteriskcdrdb "$DBUSER" "$DBPASSWORD" 2>&1) \
    && ok "M7 CDR ODBC connects (isql)" || { fail "M7 isql MySQL-asteriskcdrdb"; ev <<<"$out"; }
  out=$(timeout 30 mysql -h "$DBHOST" -u root -p"$DBROOT_PASSWORD" -N -e 'SHOW DATABASES' 2>&1)
  [[ $(grep -cxF -e "$DBNAME" -e asteriskcdrdb <<<"$out") == 2 ]] && ok "M8 databases $DBNAME and asteriskcdrdb exist" \
    || { fail "M8 databases $DBNAME and asteriskcdrdb"; ev <<<"$out"; }
  out=$(timeout 120 fwconsole ma list 2>&1)
  awk -F'|' '$2 ~ /^ *core *$/ && $4 ~ /^ *Enabled/' <<<"$out" | grep -q . && ok "M9 fwconsole: core Enabled" \
    || { fail "M9 fwconsole ma list"; tail -n 20 <<<"$out" | ev; }

  bad=0
  s=$(timeout 30 fail2ban-client ping 2>&1); [[ $s == *pong* ]] || bad=1
  out=$(timeout 30 fail2ban-client status asterisk 2>&1); s+=$'\n'$out
  grep -q 'File list:.*/usr/local/asterisk/var/log/asterisk/fail2ban' <<<"$out" || bad=1
  out=$(timeout 30 fail2ban-client get asterisk bantime.maxtime 2>&1); s+=$'\n'$out
  [[ $out == 604800 ]] || bad=1
  out=$(timeout 30 fail2ban-client get asterisk bantime.rndtime 2>&1); s+=$'\n'$out
  [[ $out == 3600 ]] || bad=1
  # The package's default: nothing in the image sets it, and the ban database lives in the volume.
  out=$(timeout 30 fail2ban-client get dbpurgeage 2>&1); s+=$'\n'$out
  [[ $out == *'- 86400seconds' ]] || bad=1
  out=$(timeout 30 fail2ban-client get asterisk ignoreip 2>&1); s+=$'\n'$out
  # Exact trunk and monitoring addresses may be listed too (whole private ranges: I11).
  grep -Eq '^[|`]- 127\.0\.0\.[01]/8$' <<<"$out" && grep -q '^[|`]- ::1$' <<<"$out" || bad=1
  if (( bad )); then fail "M10 fail2ban: ping, jail log, maxtime 604800, rndtime 3600, purge age 86400, ignoreip"; ev <<<"$s"
  else ok "M10 fail2ban: jail asterisk, maxtime 1w, rndtime 1h, purge age 1d, loopback ignored"; fi

  n=$(stat -c %s "$f2b" 2>/dev/null)
  timeout 30 asterisk -rx 'logger reload' >/dev/null 2>&1
  m=$(stat -c %s "$f2b" 2>/dev/null)
  # Owner only: "fwconsole start" resets the mode of every log file to 664 on each boot.
  s=$(stat -c '%U:%G %a' "$f2b" 2>&1)
  if (( ${m:-0} > ${n:-0} )) && [[ $s == 'asterisk:asterisk '* ]]; then ok "M11 Asterisk writes to the jail log ($s)"
  else fail "M11 jail log: size ${n:-?} -> ${m:-?} after logger reload, $s"; fi
  out=$(nft list chain inet filter input 2>&1)
  grep -q 'policy drop' <<<"$out" && ok "M12 nftables input policy drop" || { fail "M12 nftables input chain"; head -n 5 <<<"$out" | ev; }
  # The rule's text only: the test network has no IPv6 to carry an MLD query.
  s=$(grep -F 'ip6 hoplimit 1 accept' <<<"$out"); bad=0
  for m in mld-listener-query mld-listener-report 'mld-listener-(done|reduction)' mld2-listener-report; do
    grep -Eq "[ {]$m[ ,}]" <<<"$s" || bad=1
  done
  if (( bad )); then fail "M28 no rule accepts the four MLD types with hop limit 1"; ev <<<"${s:-none}"
  else ok "M28 MLD (ICMPv6 130-132 and 143) accepted with hop limit 1"; fi
  bad=0 s=''
  for u in '/admin/config.php 403' '/.well-known/acme-challenge/x 200|404' '/.freepbx-known/x 200|404'; do
    m=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1${u%% *}")
    s+="${u%% *} -> $m; "; [[ $m =~ ^(${u#* })$ ]] || bad=1
  done
  if (( bad )); then fail "M13 loopback HTTP"; ev <<<"$s"; else ok "M13 loopback: GUI 403, public paths open"; fi
  out=$(readlink /usr/sbin/safe_asterisk)
  [[ $out == /usr/local/bin/safe_asterisk ]] && ok "M14 safe_asterisk shim linked" || fail "M14 /usr/sbin/safe_asterisk -> $out"
  out=$(ps -o user= -C apache2 | LC_ALL=C sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')
  [[ $out =~ ^asterisk=[0-9]+\ root=1\ $ ]] && ok "M15 Apache master root, workers asterisk" || fail "M15 Apache users: $out"
  # Root runs sbin, loads usr/lib64, runs the hooks and reads jail.d: none of it may be asterisk's.
  out=$(stat -c '%U:%G %n' /data /data/asterisk /data/asterisk/sbin /data/asterisk/sbin/asterisk \
    /data/asterisk/usr/lib64 /data/entrypoint-hooks.d/nftables.d /data/entrypoint-hooks.d/scripts.d \
    /data/fail2ban/jail.d 2>&1)
  s=$(stat -c '%U:%G' /data/asterisk/var/lib/asterisk/astdb.sqlite3 2>&1)
  [[ $(grep -c '^root:root ' <<<"$out") == 8 && $s == asterisk:asterisk ]] \
    && ok "M16 code, hooks and jail.d owned by root, astdb by asterisk" || { fail "M16 owners"; ev <<<"$out"$'\n'"astdb $s"; }
  [[ -x /etc/cron.daily/logrotate ]] && ok "M17 daily logrotate in cron" || fail "M17 /etc/cron.daily/logrotate missing"
  n=$(grep -c '^fail2ban' /etc/asterisk/logger_logfiles_custom.conf 2>&1)
  [[ $n == 1 ]] && ok "M18 fail2ban log channel declared once" || fail "M18 fail2ban channel lines: $n"
  # Cron's job-output mail is off: the relay rejects its "From: root (Cron Daemon)".
  out=$(head -n 1 /etc/crontab; crontab -u asterisk -l 2>&1 | head -n 1)
  [[ $out == $'MAILTO=""\nMAILTO=""' ]] && ok "M19 cron mail off in /etc/crontab and for asterisk" \
    || { fail "M19 cron MAILTO"; ev <<<"$out"; }
  out=$(runuser -u asterisk -- env -i PATH=/usr/bin:/bin timeout 60 /usr/sbin/fwconsole --version 2>&1) \
    && ok "M20 fwconsole runs with cron's PATH" || { fail "M20 fwconsole with PATH=/usr/bin:/bin"; ev <<<"$out"; }
  [[ -d /data/fail2ban/jail.d && /etc/fail2ban/jail.d -ef /data/fail2ban/jail.d ]] && ok "M21 fail2ban reads jail.d from the volume" \
    || fail "M21 /etc/fail2ban/jail.d is not the volume's /data/fail2ban/jail.d"
  # The spool must stay cron's (a recursive chown of the volume would take it), with the asterisk table in it.
  out=$(stat -c '%U:%G %a' /data/cron/crontabs 2>&1)
  [[ /var/spool/cron/crontabs -ef /data/cron/crontabs && $out == 'root:crontab 1730' && -f /data/cron/crontabs/asterisk ]] \
    && ok "M22 cron spool is in the volume ($out)" || fail "M22 cron spool in the volume: $out"
  n=$(awk '/^Max open files/ { print $4 }' "/proc/$p/limits" 2>/dev/null)
  [[ $n =~ ^[0-9]+$ ]] && (( n >= 32768 )) && ok "M23 Asterisk may open $n files" \
    || fail "M23 Asterisk open-file limit: ${n:-?} (want >= 32768)"
  # Every service inherits supervisord's environment. Names only: the values are secrets.
  out=$(tr '\0' '\n' </proc/1/environ | grep -oE '^(DBROOT_PASSWORD|SMTP_PASSWORD)=' | sort -u)
  [[ -r /proc/1/environ && -z $out ]] && ok "M24 services run without the root and SMTP passwords" \
    || { fail "M24 passwords left in supervisord's environment"; ev <<<"${out:-/proc/1/environ not readable}"; }
  # Out of memory, the kernel must pick an Apache process before Asterisk (60-apache2.conf).
  n=0 out=''
  for u in $(pgrep -x apache2); do
    m=$(cat "/proc/$u/oom_score_adj" 2>/dev/null) || continue
    n=$((n + 1)); [[ $m == 500 ]] || out+="apache2 $u: $m; "
  done
  m=$(cat "/proc/$p/oom_score_adj" 2>&1)
  [[ $m =~ ^-?[0-9]+$ ]] && (( m < 500 )) || out+="asterisk: $m; "
  if (( n >= 2 )) && [[ -z $out ]]; then ok "M25 oom_score_adj: 500 on $n Apache processes, $m on Asterisk"
  else fail "M25 oom_score_adj (want 500 on Apache, less on Asterisk)"; ev <<<"${out:-$n Apache processes (want 2 or more)}"; fi
}

proxy_smoke() {
  local u want c h out
  for u in '/admin/config.php 200|302' '/admin/.htaccess 403' '/admin/modules/core/module.xml 403' \
           '/server-status 403|404'; do
    want=${u#* } u=${u%% *}
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$APP_IP$u")
    [[ $c =~ ^($want)$ ]] && ok "X1 $u -> $c" || fail "X1 $u -> $c (want $want)"
  done
  h=$(curl -sI --max-time 5 "http://$APP_IP/admin/config.php" | tr -d '\r')
  if grep -qix 'x-content-type-options: nosniff' <<<"$h" && grep -qix "content-security-policy: frame-ancestors 'self'" <<<"$h" \
     && grep -qix 'server: apache' <<<"$h" && ! grep -qi '^x-powered-by:' <<<"$h"; then ok "X2 security headers"
  else fail "X2 security headers"; ev <<<"$h"; fi
  # Without keep-alive the proxy cannot reuse a connection that Apache is closing (an occasional 502).
  out=$(curl -s -o /dev/null -o /dev/null -w '%{num_connects} %header{connection}\n' --max-time 5 \
        "http://$APP_IP/admin/config.php" "http://$APP_IP/admin/config.php")
  [[ ${out,,} == $'1 close\n1 close' ]] && ok "X6 no keep-alive: one connection per request, Connection: close" \
    || { fail "X6 keep-alive between the proxy and Apache (connections opened, Connection header)"; ev <<<"$out"; }
  # The X3 and X5 verdicts, and X4's log check, read the app log on the host.
  curl -s -o /dev/null --max-time 5 -H 'X-Forwarded-For: 203.0.113.7' "http://$APP_IP/admin/config.php"
  curl -s -o /dev/null --max-time 5 -H 'X-Forwarded-For: 127.0.0.1' "http://$APP_IP/admin/config.php?x5"
  head -c 12000000 /dev/zero >/tmp/x4.bin
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 -F file=@/tmp/x4.bin "http://$APP_IP/admin/ajax.php")
  rm -f /tmp/x4.bin
  [[ $c != 413 && $c != 000 ]] && ok "X4 12 MB upload answered $c" || fail "X4 12 MB upload answered $c"
}

proxy_sip() {
  local port r out='' i j
  # A connected UDP socket gets the ICMP port unreachable as an error on its next write:
  # "refused" = the firewall let the datagram in and nothing listens; "silent" = filtered.
  for port in 5061 19999; do
    r=error
    if exec 3<>"/dev/udp/$APP_IP/$port"; then
      r=silent; printf x >&3; sleep 0.5
      printf x >&3 2>/dev/null || r=refused
      exec 3>&-
    fi
    out+="$port $r "
  done
  [[ $out == '5061 silent 19999 refused ' ]] && ok "M26 UDP 5061 is filtered; UDP 19999 (RTP range, no listener) is refused" \
    || fail "M26 UDP probes: $out(want 5061 silent, 19999 refused)"
  # 20000 datagrams from one source in about 2 s, for M27. PJSIP discards 32 bytes or less unparsed.
  if exec 3<>"/dev/udp/$APP_IP/5060"; then
    for i in {1..200}; do for j in {1..100}; do printf '\r\n' >&3; done; sleep 0.005; done 2>/dev/null
    exec 3>&-
  fi
}

app_drops() {
  local out p=${PROXY_IP//./\\.}
  out=$(nft list set inet filter dropv4 2>&1)
  if grep -Eq "(^|[ {,])$p \. (udp|17) \. 5061 " <<<"$out" && ! grep -Eq "(^|[ {,])$p \. (udp|17) \. 19999 " <<<"$out"; then
    ok "M29 drop record holds the proxy's UDP 5061 probe and not the accepted 19999"
  else fail "M29 drop record (nft list set inet filter dropv4)"; ev <<<"$out"; fi
  out=$(nft list chain inet filter input 2>&1)
  [[ $(grep -v '^[[:space:]]*}' <<<"$out" | tail -n 1) == *dropv6* ]] && ok "M29 drop record is the last rule of inet filter input" \
    || { fail "M29 the last rule of inet filter input is not the drop record"; tail -n 4 <<<"$out" | ev; }
}

phase_smoke() {
  local p aip pip t log h n m out cap='s/.* counter packets \([0-9]*\) .*comment "V4 - SIP packet cap"$/\1/p'
  need_app || return
  in_app app_smoke
  p=$(cid proxy); aip=$(ip_of "$C"); pip=$(ip_of "$p")
  [[ -n $p && -n $aip && -n $pip ]] || { fail "proxy or front addresses not found (app ${aip:-?}, proxy ${pip:-?})"; return; }
  t=$(stamp)
  run_fn proxy_smoke exec -i -e "APP_IP=$aip" "$p" timeout 600 bash -s
  log=$(dk logs --since "$t" "$C" 2>&1)
  # Format "proxied" in apache2.conf: client from X-Forwarded-For, then the proxy's own address.
  # X3's line proves this is the right log, so X4's absence check means something.
  if awk -v p="$pip" '$1 == "203.0.113.7" && $2 == p { f = 1 } END { exit !f }' <<<"$log"; then
    ok "X3 access log: 203.0.113.7 via $pip"
    absent "X4 no 'exceeds the limit' in the app log" "$log" 'exceeds the limit'
    # FreePBX skips the login for a client at 127.0.0.1: the proxy's header must not make one.
    if grep -qF 'config.php?x5' <<<"$log"; then
      absent "X5 a loopback X-Forwarded-For is not taken as the client" "$log" '^127\.0\.0\.1 .*config\.php\?x5'
    else fail "X5 the request with a loopback X-Forwarded-For is not in the access log"; fi
  else fail "X3 no access log line '203.0.113.7 $pip'"; grep -F '203.0.113.7' <<<"$log" | head -n 3 | ev; fi
  n=$(dk exec "$C" nft list chain inet filter input 2>/dev/null | sed -n "$cap")
  run_fn proxy_sip exec -i -e "APP_IP=$aip" "$p" timeout 600 bash -s
  out=$(dk exec "$C" nft list chain inet filter input 2>&1); m=$(sed -n "$cap" <<<"$out")
  # Ahead of the accept of established flows: the cap must also hold what the "ct state new" limits never see.
  if [[ $n =~ ^[0-9]+$ && $m =~ ^[0-9]+$ ]] && (( m - n >= 5000 )) \
     && awk '/SIP packet cap/ { c = NR } !e && /established/ { e = NR } END { exit !(c && c < e) }' <<<"$out"; then
    ok "M27 SIP packet cap, ahead of the established accept, dropped $((m - n)) of 20000 datagrams from one source"
  else
    fail "M27 SIP packet cap: counter ${n:-?} -> ${m:-?} (want 5000 more), or not ahead of the established accept"
    grep -E 'SIP packet cap|established' <<<"$out" | ev
  fi
  in_app app_drops -e "PROXY_IP=$pip"
  # The first probe runs 30 s after the start; a failed early probe keeps "starting" 30 s more.
  for _ in 1 2 3 4 5 6 7 8; do h=$(dk inspect -f '{{.State.Health.Status}}' "$C"); [[ $h == starting ]] || break; sleep 5; done
  [[ $h == healthy ]] && ok "H1 container healthy" || fail "H1 container health: $h"
  log=$(dk logs "$C" 2>&1)
  if grep -qF 'Bootstrap finished.' <<<"$log"; then absent "H2 app log has no error lines" "$log" "$BAD_LOG"
  else fail "H2 app log has no 'Bootstrap finished.'"; tail -n 5 <<<"$log" | ev; fi
}

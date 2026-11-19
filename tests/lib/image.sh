# shellcheck shell=bash

# Functions passed to run_fn or in_app run inside a container: of the host, only run_fn's helpers exist there.

image_checks() {
  local ast=/usr/local/asterisk m e b f s out mods vals bad=0 nf=0 t ext j l n a p pid c w
  out=$("$ast/sbin/asterisk" -V 2>&1) && ok "I2 $out" || { fail "I2 asterisk -V"; ev <<<"$out"; }
  if grep -Eq '^runuser *= *asterisk' "$ast/etc/asterisk/asterisk.conf" \
     && grep -Eq '^rungroup *= *asterisk' "$ast/etc/asterisk/asterisk.conf" && id asterisk >/dev/null 2>&1; then
    ok "I2 runuser/rungroup asterisk, user exists"
  else fail "I2 runuser/rungroup/user asterisk"; fi

  for m in res_pjsip chan_pjsip res_pjsip_session res_pjsip_registrar res_pjsip_outbound_registration \
    res_pjsip_pubsub res_pjsip_transport_websocket res_http_websocket res_srtp res_crypto \
    res_odbc res_config_odbc cdr_adaptive_odbc cdr_odbc func_odbc res_curl func_curl res_musiconhold \
    res_agi res_timing_timerfd res_rtp_asterisk app_dial app_voicemail app_queue app_confbridge \
    app_playback app_record bridge_simple bridge_softmix pbx_config format_wav format_gsm format_sln \
    format_pcm format_mp3 codec_ulaw codec_alaw codec_gsm codec_resample; do
    [[ -f $ast/usr/lib64/asterisk/modules/$m.so ]] || { fail "I3 module missing: $m"; bad=1; }
  done
  (( bad )) || ok "I3 required Asterisk modules present"
  for m in res_fax_spandsp codec_opus res_stir_shaken; do
    [[ -f $ast/usr/lib64/asterisk/modules/$m.so ]] || warn "I3 optional module missing: $m"
  done

  ext=$(php -r 'echo ini_get("extension_dir");' 2>/dev/null)
  while IFS= read -r -d '' f; do
    nf=$((nf + 1))
    out=$(ldd "$f" 2>&1) || continue
    grep -q 'not found' <<<"$out" || continue
    if LD_LIBRARY_PATH=$ast/usr/lib64 ldd "$f" 2>&1 | grep -q 'not found'; then
      fail "I4 missing library for ${f##*/}"; grep 'not found' <<<"$out" | ev
    else warn "I4 resolves only with LD_LIBRARY_PATH: ${f##*/}"; fi
  done < <(find "$ast/sbin" "$ast/usr/lib64" "$ext" /usr/lib/apache2/modules /usr/lib/x86_64-linux-gnu/odbc \
             /usr/lib/aarch64-linux-gnu/odbc -type f \( -name '*.so' -o -name '*.so.*' -o -name asterisk \) \
             -print0 2>/dev/null)
  # Asterisk alone ships hundreds of modules: fewer files means the paths are wrong.
  (( nf >= 200 )) && ok "I4 ldd on $nf files" || fail "I4 ldd ran on only $nf files (want >= 200)"

  mods=$(php -m 2>&1); bad=0
  for e in mysqli pdo pdo_mysql xml dom SimpleXML intl gettext gd curl zip mbstring posix session openssl \
    json pcre ctype fileinfo; do
    grep -qix "$e" <<<"$mods" || { fail "I5 php extension missing: $e"; bad=1; }
  done
  (( bad )) || ok "I5 required php extensions"
  grep -qix sysvsem <<<"$mods" || warn "I5 php extension missing: sysvsem"
  for e in sockets ldap bcmath soap bz2 ssh2 redis; do
    grep -qix "$e" <<<"$mods" || warn "I5 recommended php extension missing: $e"
  done
  php -v 2>&1 | grep -qi ioncube && ok "I5 ionCube loaded" || fail "I5 ionCube not loaded"
  # cron gives jobs PATH=/usr/bin:/bin, and FreePBX hooks hardcode /usr/bin/php.
  out=$(readlink -f /usr/bin/php)
  [[ -x /usr/bin/php && $out == /usr/local/bin/php ]] && ok "I5 /usr/bin/php is the image's PHP" \
    || fail "I5 /usr/bin/php is missing or is not the image's PHP"
  vals=$(php -r 'foreach (["upload_max_filesize", "post_max_size", "memory_limit", "max_input_vars",
    "expose_php", "pcre.jit"] as $k) echo "$k=", ini_get($k), "\n";
    try { new PDO("sqlite::memory:"); echo "pdo_sqlite=1\n"; } catch (Throwable $e) { echo "pdo_sqlite=0\n"; }
    echo "END\n";' 2>&1)
  if ! grep -qx END <<<"$vals"; then fail "I5 php -r did not finish"; ev <<<"$vals"
  else
    bad=0
    for e in upload_max_filesize=64M post_max_size=72M memory_limit=512M max_input_vars=5000 expose_php=; do
      grep -qx "$e" <<<"$vals" || { fail "I5 php.ini: want $e"; bad=1; }
    done
    (( bad )) || ok "I5 php.ini limits and expose_php off"
    grep -qx 'pcre.jit=0' <<<"$vals" || warn "I5 pcre.jit enabled"
    grep -qx 'pdo_sqlite=1' <<<"$vals" || warn "I5 pdo_sqlite missing"
  fi

  bad=0
  for b in gpg killall unzip zip pgrep ps pkill mysql mariadb odbcinst isql sox lame mpg123 nft ip \
    fail2ban-client fail2ban-server cron dbus-daemon dbus-uuidgen node npm curl wget openssl apache2ctl \
    php asterisk sendmail file tar gzip logrotate supervisord supervisorctl; do
    command -v "$b" >/dev/null 2>&1 || [[ -x $ast/sbin/$b ]] || { fail "I6 binary missing: $b"; bad=1; }
  done
  (( bad )) || ok "I6 runtime binaries present"
  for b in ffmpeg sngrep ssh dbus-send rsync; do command -v "$b" >/dev/null 2>&1 || warn "I6 optional binary missing: $b"; done
  odbcinst -q -d 2>/dev/null | grep -q 'MariaDB Unicode' && ok "I6 ODBC driver MariaDB Unicode" \
    || fail "I6 ODBC driver MariaDB Unicode missing"
  bad=0
  for f in /etc/init.d/cron /usr/src/freepbx/install /usr/local/bin/docker-entrypoint \
    /usr/local/bin/docker-bootstrap /usr/local/bin/safe_asterisk; do
    [[ -x $f ]] || { fail "I6 not executable: $f"; bad=1; }
  done
  [[ -d /usr/share/zoneinfo/America ]] || { fail "I6 tzdata missing"; bad=1; }
  (( bad )) || ok "I6 cron init script, installer, entry scripts, tzdata"

  out=$(python3 -I - 2>&1 <<'PY'
import os, pwd, shutil, sys
from supervisor.options import ServerOptions
o = ServerOptions()
o.realize(['-c', '/etc/supervisor/supervisord.conf'])
want = {'dbus': 10, 'fail2ban': 20, 'asterisk': 30, 'cron': 40, 'bootstrap': 50, 'apache2': 60}
got = {g.name: g.process_configs[0] for g in o.process_group_configs}
bad = 0
for n, prio in want.items():
    p = got.get(n)
    if p is None or p.priority != prio:
        print('program %s: missing or wrong priority' % n); bad += 1; continue
    exe = p.command.split()[0]
    if not (shutil.which(exe) or os.access(exe, os.X_OK)):
        print('program %s: command not found: %s' % (n, exe)); bad += 1
if len(got) != len(want):
    print('programs: %s' % sorted(got)); bad += 1
if got.get('apache2') and got['apache2'].autostart:
    print('apache2 must not autostart (docker-bootstrap starts it)'); bad += 1
if got.get('asterisk') and got['asterisk'].uid != pwd.getpwnam('asterisk').pw_uid:
    print('asterisk must start as the asterisk user, not as root'); bad += 1
sys.exit(1 if bad else 0)
PY
  ) && ok "I7 supervisor config: 6 programs, priorities, commands, asterisk's user" || { fail "I7 supervisor config"; ev <<<"$out"; }

  out=$(apache2ctl -t 2>&1) && ok "I8 apache2ctl -t" || { fail "I8 apache2ctl -t"; ev <<<"$out"; }
  mods=$(apache2ctl -M 2>&1); bad=0
  for m in rewrite_module headers_module expires_module remoteip_module php_module; do
    grep -q "$m" <<<"$mods" || { fail "I8 apache module missing: $m"; bad=1; }
  done
  if grep -q status_module <<<"$mods" || [[ -e /etc/apache2/mods-enabled/status.load ]]; then
    fail "I8 mod_status enabled"; bad=1
  fi
  (( bad )) || ok "I8 apache modules, no mod_status"

  bad=0
  [[ $(stat -c %a /etc/logrotate.d/asterisk 2>&1) == 644 ]] || { fail "I9 logrotate.d/asterisk mode is not 644"; bad=1; }
  [[ -e /etc/logrotate.d/apache2 ]] && { fail "I9 logrotate.d/apache2 still exists"; bad=1; }
  out=$(logrotate -d /etc/logrotate.d/asterisk 2>&1) && ! grep -qi '^error' <<<"$out" \
    || { fail "I9 logrotate -d"; ev <<<"$out"; bad=1; }
  (( bad )) || ok "I9 logrotate config"

  # The ruleset is checked against this host's kernel, hence the version in the line.
  out=$(nft -c --define "proxy_subnet=$PROXY_SUBNET" -f /etc/nftables.nft 2>&1) && ok "I10 nft -c (kernel $(uname -r))" \
    || { fail "I10 nft -c (kernel $(uname -r))"; ev <<<"$out"; }

  # The jail needs its log file; this container is thrown away.
  mkdir -p "$ast/var/log/asterisk" && touch "$ast/var/log/asterisk/fail2ban"
  out=$(fail2ban-client -t 2>&1) && ok "I11 fail2ban-client -t" || { fail "I11 fail2ban-client -t"; tail -n 5 <<<"$out" | ev; }
  # Per-instance jail settings live in the volume (the link dangles here: no volume).
  out=$(readlink /etc/fail2ban/jail.d)
  [[ $out == /data/fail2ban/jail.d ]] && ok "I11 jail.d links into the volume" || fail "I11 /etc/fail2ban/jail.d -> ${out:-not a link}"
  out=$(grep -E '^ignoreip *=' /etc/fail2ban/jail.local)
  if [[ -z $out ]] || grep -Eq '(=|[ ,])(10\.0\.0\.0/8|172\.16\.0\.0/12|192\.168\.0\.0/16|100\.64\.0\.0/10)([ ,]|$)' <<<"$out"; then
    fail "I11 ignoreip missing or exempts a whole private range"; ev <<<"$out"
  else ok "I11 ignoreip exempts no private range"; fi
  for s in '[2026-01-01 10:00:00] SECURITY[123] res_security_log.c: SecurityEvent="InvalidPassword",EventTV="2026-01-01T10:00:00.000-0300",Severity="Error",Service="PJSIP",EventVersion="1",AccountID="100",SessionID="x",LocalAddress="IPV4/UDP/10.0.0.1/5060",RemoteAddress="IPV4/UDP/192.0.2.9/5060"' \
           '[2026-01-01 10:00:00] WARNING[123][C-00000001] Ext. s: "Rejecting unknown SIP connection from 192.0.2.9"'; do
    out=$(fail2ban-regex "$s" /etc/fail2ban/filter.d/asterisk.conf 2>&1)
    t=$(grep -o 'SecurityEvent="[A-Za-z]*"\|Rejecting unknown SIP connection' <<<"$s")
    if ! grep -q '^Lines: ' <<<"$out"; then fail "I11 fail2ban-regex gave no summary"; tail -n 5 <<<"$out" | ev
    elif grep -Eq '^Lines: .*\b1 matched\b' <<<"$out"; then ok "I11 filter matches $t"
    else warn "I11 filter does not match $t"; fi
  done
  # The image has no iptables: a jail added in jail.d must inherit the nftables action, on TCP and UDP.
  mkdir -p /data/fail2ban/jail.d
  printf '[i11probe]\nenabled = true\nfilter = asterisk\nlogpath = %s\n' "$ast/var/log/asterisk/fail2ban" >/data/fail2ban/jail.d/i11probe.local
  out=$(fail2ban-client -d 2>&1)
  rm -f /data/fail2ban/jail.d/i11probe.local
  bad=0
  for j in 'i11probe nftables tcp,udp' 'asterisk nftables-tcp tcp' 'asterisk nftables-udp udp'; do
    read -r n a p <<<"$j"
    l=$(grep -F "['multi-set', '$n', 'action', '$a', " <<<"$out")
    grep -qxF "['set', '$n', 'addaction', '$a']" <<<"$out" && grep -qF "['protocol', '$p']" <<<"$l" \
      && grep -qF "['type', 'allports']" <<<"$l" && grep -qF "['blocktype', 'drop']" <<<"$l" && continue
    fail "I11 jail $n: want action $a with nftables allports, drop, protocol $p"; bad=1
    { grep -F "['set', '$n', 'addaction'" <<<"$out"; grep -oE "\['(type|blocktype|protocol)', '[^']*'\]" <<<"$l"; } | ev
  done
  (( bad )) || ok "I11 jail asterisk and a jail from jail.d ban with nftables: all ports, drop, TCP and UDP"

  t=$(du -sm /tmp 2>/dev/null | cut -f1)
  (( ${t:-0} < 50 )) && ok "I12 /tmp holds ${t} MB" || warn "I12 /tmp holds ${t} MB"
  [[ -f /etc/odbcinst.ini ]] && ok "I12 /etc/odbcinst.ini present" || fail "I12 /etc/odbcinst.ini missing"
  [[ -L /etc/localtime ]] && ok "I12 timezone $(cat /etc/timezone 2>/dev/null)" || warn "I12 /etc/localtime is not a link"
  # FreePBX's scheduled jobs live in the volume (the link dangles here: no volume).
  out=$(readlink /var/spool/cron/crontabs)
  [[ $out == /data/cron/crontabs ]] && ok "I12 cron spool links into the volume" || fail "I12 /var/spool/cron/crontabs -> ${out:-not a link}"

  # A real Apache with loopback as the proxy network. No FreePBX here: a request that is let in gets 404.
  printf '<?php sleep(30);\n' >/var/www/html/i14.php
  PROXY_SUBNET=127.0.0.0/8 apache2-foreground >>/tmp/apache.log 2>&1 &
  pid=$!
  for _ in {1..20}; do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 -H 'X-Forwarded-For: 203.0.113.9' http://127.0.0.1/i13)
    [[ $c == 000 ]] || break; sleep 1
  done
  [[ $c == 404 ]] && ok "I13 PROXY_SUBNET opens the GUI to its range (127.0.0.1 gets 404, not 403)" \
    || { fail "I13 127.0.0.1 with PROXY_SUBNET=127.0.0.0/8 got $c (want 404)"; tail -n 5 /tmp/apache.log | ev; }
  # Twelve requests that hold a worker for 30 s each: prefork must stop at MaxRequestWorkers and say so.
  for _ in {1..12}; do curl -s -o /dev/null --max-time 60 http://127.0.0.1/i14.php & done
  m=0 w=0
  for _ in {1..25}; do
    c=$(pgrep -c -P "$pid" -x apache2); (( c > m )) && m=$c
    grep -q AH00161 /tmp/apache.log && (( ++w >= 3 )) && break
    sleep 1
  done
  grep -q AH00161 /tmp/apache.log && (( m == 10 )) && ok "I14 12 slow requests: 10 Apache workers, then AH00161" \
    || { fail "I14 12 slow requests: up to $m Apache workers (want 10 and AH00161)"; tail -n 5 /tmp/apache.log | ev; }
  # Read only now: Apache writes the access log line after it answers.
  grep -q '^203\.0\.113\.9 127\.0\.0\.1 .*"GET /i13 ' /tmp/apache.log && ok "I13 X-Forwarded-For is taken from PROXY_SUBNET" \
    || { fail "I13 no access log line '203.0.113.9 127.0.0.1 ... /i13'"; grep -F /i13 /tmp/apache.log | head -n 3 | ev; }
  # Apache is left to die with the container: on SIGTERM it signals its process group, this shell included.
}

phase_image() {
  run_fn image_checks run -i --rm --pull never --cap-add NET_ADMIN --entrypoint timeout "$IMAGE" 600 bash -s
}

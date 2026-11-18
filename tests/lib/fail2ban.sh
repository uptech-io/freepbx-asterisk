# shellcheck shell=bash

F2B_LOG=/data/asterisk/var/log/asterisk/fail2ban

# Functions passed to run_fn or in_app run inside a container: of the host, only run_fn's helpers exist there.

l5_rotate() {
  local d=/data/asterisk/var/log/asterisk out s n
  out=$(timeout 120 logrotate -f /etc/logrotate.d/asterisk 2>&1)
  if [[ $? == 0 && -f $d/full.1 && -f $d/full ]]; then ok "L5 logrotate -f: full.1 and a new full"
  else fail "L5 logrotate -f"; { echo "$out"; ls -l "$d"; } | ev; fi
  out=$(timeout 30 asterisk -rx 'logger show channels' 2>&1)
  grep -q ' Enabled ' <<<"$out" && ! grep -q ' Disabled ' <<<"$out" && ok "L5 log channels Enabled" \
    || { fail "L5 logger show channels"; ev <<<"$out"; }
  s=$(stat -c %s "$d/fail2ban" 2>/dev/null)
  timeout 30 asterisk -rx 'logger reload' >/dev/null 2>&1
  n=$(stat -c %s "$d/fail2ban" 2>/dev/null)
  (( ${n:-0} > ${s:-0} )) && ok "L5 Asterisk writes to the new jail log" || fail "L5 jail log: ${s:-?} -> ${n:-?} bytes"
  out=$(timeout 30 fail2ban-client status asterisk 2>&1) && ok "L5 jail asterisk active" \
    || { fail "L5 fail2ban-client status asterisk"; ev <<<"$out"; }
}

f2b_burst() {
  local i id msg sent=0
  for i in $(seq 20); do
    id="$(date +%s)-$$-$i"
    printf -v msg 'REGISTER sip:%s SIP/2.0\r\nVia: SIP/2.0/UDP %s:5060;rport;branch=z9hG4bK-f2b-%s\r\nMax-Forwards: 70\r\nFrom: <sip:f2bprobe@%s>;tag=f2b%s\r\nTo: <sip:f2bprobe@%s>\r\nCall-ID: f2b-%s@%s\r\nCSeq: 1 REGISTER\r\nContact: <sip:f2bprobe@%s:5060>\r\nExpires: 60\r\nContent-Length: 0\r\n\r\n' \
      "$APP_IP" "$PROXY_IP" "$id" "$APP_IP" "$id" "$APP_IP" "$id" "$PROXY_IP" "$PROXY_IP"
    # bash's printf sends one datagram per line; head writes the message in one datagram.
    head -c -1 <<<"$msg" >"/dev/udp/$APP_IP/5060" && sent=$((sent + 1))
  done
  (( sent == 20 )) && ok "F3 20 REGISTERs sent from the proxy" || fail "F3 only $sent of 20 REGISTERs sent"
}

f2b_verdict() {
  local s t n end=$((SECONDS + 20)) f2b=/data/asterisk/var/log/asterisk/fail2ban
  # fail2ban lists the ban before its actions create the nft table and set: wait for both.
  until s=$(fail2ban-client status asterisk 2>&1); t=$(nft list table inet f2b-table 2>&1)
        grep 'Banned IP list:' <<<"$s" | grep -qwF "$PROXY_IP" && grep -qwF "$PROXY_IP" <<<"$t"; do
    (( SECONDS < end )) || break
    sleep 1
  done
  if grep 'Banned IP list:' <<<"$s" | grep -qwF "$PROXY_IP"; then ok "F4 proxy $PROXY_IP banned"
  else fail "F4 proxy $PROXY_IP not banned within 20 s"; { echo "$s"; tail -n 5 "$f2b"; } | ev; fi
  grep -qwF "$PROXY_IP" <<<"$t" && ok "F5 nft f2b-table holds the proxy" || { fail "F5 nft f2b-table"; ev <<<"$t"; }
  n=$(tail -c +$((SIZE + 1)) "$f2b" | grep -cE 'SecurityEvent="(FailedACL|InvalidAccountID|ChallengeResponseFailed|InvalidPassword)"')
  (( n >= 10 )) && ok "F5 $n failed-auth events logged" || fail "F5 only $n failed-auth events logged (want >= 10)"
}

phase_fail2ban() {
  local p aip pip size out code lcode
  need_app || return
  in_app l5_rotate
  p=$(cid proxy); aip=$(ip_of "$C"); pip=$(ip_of "$p")
  [[ -n $p && -n $aip && -n $pip ]] || { fail "proxy or front addresses not found (app ${aip:-?}, proxy ${pip:-?})"; return; }
  out=$(dk exec "$C" timeout 30 asterisk -rx 'pjsip show transports' 2>&1)
  grep -Eq '^ *Transport: +[^ <]+ +udp .*:5060$' <<<"$out" && ok "F1 PJSIP UDP transport on 5060" || { fail "F1 no PJSIP UDP transport on 5060"; ev <<<"$out"; }
  size=$(dk exec "$C" stat -c %s "$F2B_LOG")
  [[ $size =~ ^[0-9]+$ ]] || { fail "F2 size of the jail log"; ev <<<"$size"; return; }
  out=$(dk exec "$C" timeout 30 fail2ban-client unban --all 2>&1) || { fail "F2 fail2ban-client unban --all"; ev <<<"$out"; return; }
  BANNED=1
  run_fn f2b_burst exec -i -e "APP_IP=$aip" -e "PROXY_IP=$pip" "$p" timeout 600 bash -s
  in_app f2b_verdict -e "PROXY_IP=$pip" -e "SIZE=$size"
  # Loopback must answer at the same time, or "000" could mean a dead Apache.
  code=$(dk exec "$p" curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$aip/admin/config.php")
  lcode=$(dk exec "$C" curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1/admin/config.php)
  [[ $code == 000 && $lcode == 403 ]] && ok "F6 banned proxy gets no answer, loopback gets 403" \
    || fail "F6 proxy got HTTP $code (want 000), loopback $lcode (want 403)"
  out=$(dk exec "$C" timeout 30 fail2ban-client unban --all 2>&1) && BANNED=0 || { fail "F7 unban --all"; ev <<<"$out"; }
  code=$(dk exec "$p" curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$aip/admin/config.php")
  [[ $code =~ ^(200|302)$ ]] && ok "F7 unbanned proxy reaches the GUI ($code)" || fail "F7 unbanned proxy got HTTP $code"
}
